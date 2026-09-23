import type { Recording } from "@/domain";
import { newId, now } from "@/domain";
import { mediaStore, type MediaFolder, type MediaStore } from "@/storage/media-store";
import { recordings as recordingRepository } from "@/storage/repository";
import { publishChange } from "@/storage/live";
import { fileExtension, localTimezone, mimeTypeForKey } from "./import";
import { probeVideo, type VideoProbe } from "./probe";
import { clearJournal, readJournals, type CaptureJournal } from "./recovery-journal";

/* OWNER: media agent. Ports RecordingLibrary.reconcile and RecordingRecovery.recover. Both take
   their stores as parameters so tests run against in-memory fakes; the defaults hit IndexedDB/OPFS. */

export interface RecordingStore {
  all(): Promise<Recording[]>;
  save(recording: Recording): Promise<Recording>;
}

export interface LibraryDeps {
  store: MediaStore;
  recordings: RecordingStore;
  now?: () => number;
  probe?: (file: Blob) => Promise<VideoProbe>;
}

export interface ReconcileResult {
  /** Recording IDs whose file was missing; their `localPath` is now "". */
  missing: string[];
  /** Orphan files deleted from Recordings. */
  deletedOrphans: string[];
  /** Abandoned `.partial.` exports deleted. */
  deletedPartialExports: string[];
  /** Bytes used per folder after cleanup. */
  usage: Record<MediaFolder, number>;
}

const PLAYABLE = new Set(["mp4", "mov", "m4v", "webm", "mkv"]);
/** Files younger than this are left alone: an import may have written the bytes but not the row yet. */
const ORPHAN_GRACE_MS = 10 * 60 * 1000;
const FOLDERS: MediaFolder[] = ["Recordings", "Exports", "Thumbnails", "Recovery"];

async function defaultDeps(): Promise<LibraryDeps> {
  return { store: await mediaStore(), recordings: { all: recordingRepository.all, save: recordingRepository.save } };
}

export async function reconcileLibrary(deps?: LibraryDeps): Promise<ReconcileResult> {
  const { store, recordings, now: clock = Date.now } = deps ?? (await defaultDeps());
  const files = new Set(await store.list("Recordings"));
  const all = await recordings.all();
  const missing: string[] = [];
  for (const recording of all) {
    if (!recording.localPath) continue;
    if (files.has(recording.localPath)) continue;
    missing.push(recording.id);
    await recordings.save({ ...recording, localPath: "" });
  }

  const known = new Set(all.map((r) => r.localPath).filter(Boolean));
  const deletedOrphans: string[] = [];
  for (const key of files) {
    if (known.has(key) || !PLAYABLE.has(key.split(".").pop()?.toLowerCase() ?? "")) continue;
    const file = await store.read("Recordings", key);
    if (file && clock() - file.lastModified < ORPHAN_GRACE_MS) continue;
    await store.delete("Recordings", key);
    deletedOrphans.push(key);
  }

  const deletedPartialExports: string[] = [];
  for (const key of await store.list("Exports")) {
    if (!key.includes(".partial.")) continue;
    await store.delete("Exports", key);
    deletedPartialExports.push(key);
  }

  const usage = {} as Record<MediaFolder, number>;
  for (const folder of FOLDERS) usage[folder] = await store.size(folder).catch(() => 0);
  if (missing.length || deletedOrphans.length) publishChange("media");
  return { missing, deletedOrphans, deletedPartialExports, usage };
}

export async function storageUsage(store?: MediaStore): Promise<Record<MediaFolder, number>> {
  const s = store ?? (await mediaStore());
  const usage = {} as Record<MediaFolder, number>;
  for (const folder of FOLDERS) usage[folder] = await s.size(folder).catch(() => 0);
  return usage;
}

/** Promotes journalled captures left in "Recovery" by a crash into Recordings. Returns the new rows. */
export async function recoverRecordings(deps?: LibraryDeps): Promise<Recording[]> {
  const resolved = deps ?? (await defaultDeps());
  const { store, recordings } = resolved;
  const probe = resolved.probe ?? probeVideo;
  const journals = await readJournals(store);
  if (!journals.length) return [];
  const existing = await recordings.all();
  const recovered: Recording[] = [];
  for (const journal of journals) {
    if (existing.some((r) => r.id === journal.recordingID)) { await clearJournal(journal.recordingID, store); continue; }
    if (journal.mode === "rolling" && !journal.promoted) { await discard(store, journal); continue; }
    const key = `${journal.recordingID}.${fileExtension({ name: journal.mediaKey })}`;
    let file = await store.read("Recovery", journal.mediaKey);
    let location: MediaFolder = "Recovery";
    if (!file || file.size === 0) { file = await store.read("Recordings", key); location = "Recordings"; }
    if (!file || file.size === 0) { await discard(store, journal); continue; }
    let info: VideoProbe;
    try { info = await probe(file); } catch { info = { duration: 0, width: 0, height: 0, rotation: 0, mimeType: "", codec: null, frameRate: null, hasAudio: false }; }
    if (!(info.duration > 0.05) || info.width === 0) { await store.delete(location, location === "Recovery" ? journal.mediaKey : key); await clearJournal(journal.recordingID, store); continue; }
    if (location === "Recovery") {
      if (!(await store.exists("Recordings", key))) await store.write("Recordings", key, file);
      await store.delete("Recovery", journal.mediaKey);
    }
    const recording: Recording = {
      id: journal.recordingID, projectID: journal.projectID, localPath: key, name: "", createdAt: now(),
      duration: info.duration, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
      segmentIndex: existing.filter((r) => r.projectID === journal.projectID).length, endedReason: "crash",
      recordedAt: journal.startedAt, ...localTimezone(), timezoneIdentifier: journal.timezone || localTimezone().timezoneIdentifier,
      width: info.width, height: info.height, mimeType: info.mimeType || mimeTypeForKey(key),
      serverVersion: null, needsSync: true, mutationID: newId(),
    };
    const saved = await recordings.save(recording);
    existing.push(saved);
    recovered.push(saved);
    await clearJournal(journal.recordingID, store);
  }
  if (recovered.length) publishChange("media");
  return recovered;
}

async function discard(store: MediaStore, journal: CaptureJournal) {
  await store.delete("Recovery", journal.mediaKey);
  await clearJournal(journal.recordingID, store);
}
