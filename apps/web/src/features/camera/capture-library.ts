import type { Recording, RecordingEndedReason } from "@/domain";
import { newId } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import * as repository from "@/storage/repository";
import { clearJournal, writeJournal, type CaptureJournal } from "@/media/recovery-journal";
import { detectMediaCapabilities } from "@/media/capabilities";

/* Capture-side persistence: incremental Recovery writes while recording (port of the fragmented
   QuickTime file + journal in RecordingRecovery.swift), then a move into "Recordings" on completion. */

/** MediaRecorder MIME type to capture with: mp4 (AVC first for portability) when the browser can, else webm. */
export function preferredRecorderMimeType(): string {
  const types = detectMediaCapabilities().mediaRecorderMimeTypes;
  return types.find((t) => t.startsWith("video/mp4") && t.includes("avc1")) ?? types.find((t) => t.startsWith("video/mp4")) ?? types[0] ?? "";
}

export const extensionFor = (mimeType: string) => (mimeType.startsWith("video/mp4") ? "mp4" : "webm");

export const currentTimezone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

/** Streams MediaRecorder chunks into the Recovery folder as they arrive, so a crash keeps
 *  everything written so far. Falls back to memory when the store has no streaming writer. */
export class SegmentSink {
  private writer: WritableStreamDefaultWriter<Uint8Array> | null = null;
  private memory: Blob[] = [];
  private queue: Promise<void> = Promise.resolve();
  bytes = 0;

  private constructor(readonly key: string, private readonly type: string) {}

  static async open(key: string, type: string): Promise<SegmentSink> {
    const sink = new SegmentSink(key, type);
    try { sink.writer = (await (await mediaStore()).createWritable("Recovery", key)).getWriter(); } catch { sink.writer = null; }
    return sink;
  }

  append(chunk: Blob): void {
    if (chunk.size === 0) return;
    this.bytes += chunk.size;
    if (!this.writer) { this.memory.push(chunk); return; }
    const writer = this.writer;
    this.queue = this.queue.then(async () => { writer.write(new Uint8Array(await chunk.arrayBuffer())).catch(() => undefined); }).catch(() => undefined);
  }

  /** Flushes pending writes and closes the file. Safe to call once. */
  async close(): Promise<void> {
    await this.queue;
    if (this.writer) { try { await this.writer.close(); } catch { /* already closed */ } this.writer = null; return; }
    if (this.memory.length) { await (await mediaStore()).write("Recovery", this.key, new Blob(this.memory, { type: this.type })); this.memory = []; }
  }
}

export interface CompletedSegment {
  id: string;
  projectID: string;
  /** Key in the Recovery folder. */
  mediaKey: string;
  ext: string;
  mimeType: string;
  duration: number;
  reason: RecordingEndedReason;
  startedAt: string;
  timezone: string;
  width: number | null;
  height: number | null;
}

export async function beginJournal(journal: CaptureJournal): Promise<void> {
  await writeJournal(journal);
}

/** Moves a finished file into the library and records it. Returns the saved recording. */
export async function persistSegment(segment: CompletedSegment): Promise<Recording> {
  const store = await mediaStore();
  const file = await store.read("Recovery", segment.mediaKey);
  if (!file || file.size === 0) { await discardSegment(segment.id, segment.mediaKey); throw new Error("The recording file is empty."); }
  const localPath = `${segment.id}.${segment.ext}`;
  await store.write("Recordings", localPath, file);
  await store.delete("Recovery", segment.mediaKey);
  const existing = await repository.recordings.forProject(segment.projectID);
  const recording: Recording = {
    id: segment.id,
    projectID: segment.projectID,
    localPath,
    name: "",
    createdAt: new Date().toISOString(),
    duration: segment.duration,
    uploadState: "local",
    uploadedBytes: 0,
    shareURL: null,
    pendingDeletion: false,
    segmentIndex: existing.length,
    endedReason: segment.reason,
    recordedAt: segment.startedAt,
    timezoneIdentifier: segment.timezone,
    utcOffsetSeconds: -new Date(segment.startedAt).getTimezoneOffset() * 60,
    mimeType: segment.mimeType,
    ...(segment.width && segment.height ? { width: segment.width, height: segment.height } : {}),
    serverVersion: null,
    needsSync: true,
    mutationID: newId(),
  };
  await repository.recordings.save(recording);
  await clearJournal(segment.id);
  return recording;
}

/** Deletes an unpromoted rolling segment (file and journal). */
export async function discardSegment(id: string, mediaKey: string): Promise<void> {
  const store = await mediaStore();
  await store.delete("Recovery", mediaKey);
  await clearJournal(id);
}

/** Roughly 500 MB free, judged by the storage estimate; `true` when the browser hides it. */
export async function hasRecordingCapacity(floorBytes: number): Promise<boolean> {
  try {
    const estimate = await navigator.storage?.estimate?.();
    if (!estimate?.quota) return true;
    return estimate.quota - (estimate.usage ?? 0) >= floorBytes;
  } catch { return true; }
}
