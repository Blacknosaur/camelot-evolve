import { mediaStore, type MediaStore } from "@/storage/media-store";

/* OWNER: media agent. Port of CaptureJournal (RecordingRecovery.swift). The camera writes a
   journal into the "Recovery" folder before capture starts and streams the media next to it;
   `recoverRecordings` (library.ts) promotes what a crash left behind on the next launch. */

export interface CaptureJournal {
  recordingID: string;
  projectID: string;
  /** ISO-8601 wall-clock start. */
  startedAt: string;
  /** IANA identifier, e.g. "Europe/Madrid". */
  timezone: string;
  /** "normal" | "rolling" — unpromoted rolling clips are discarded on recovery. */
  mode: string;
  /** Key of the media file inside the "Recovery" folder, e.g. `${recordingID}.mp4`. */
  mediaKey: string;
  /** Rolling clips are only kept when an event tap promoted them. */
  promoted?: boolean;
}

export const journalKey = (recordingID: string) => `${recordingID}.json`;

export function parseJournal(text: string): CaptureJournal | null {
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!value || typeof value !== "object") return null;
  const v = value as Record<string, unknown>;
  const str = (k: string) => (typeof v[k] === "string" ? (v[k] as string) : null);
  const recordingID = str("recordingID"), projectID = str("projectID"), startedAt = str("startedAt"), mediaKey = str("mediaKey");
  if (!recordingID || !projectID || !startedAt || !mediaKey) return null;
  return { recordingID, projectID, startedAt, mediaKey, timezone: str("timezone") ?? "UTC", mode: str("mode") ?? "normal", promoted: v.promoted === true };
}

export async function writeJournal(journal: CaptureJournal, store?: MediaStore): Promise<void> {
  const s = store ?? (await mediaStore());
  await s.write("Recovery", journalKey(journal.recordingID), new Blob([JSON.stringify(journal)], { type: "application/json" }));
}

export async function readJournals(store?: MediaStore): Promise<CaptureJournal[]> {
  const s = store ?? (await mediaStore());
  const journals: CaptureJournal[] = [];
  for (const key of await s.list("Recovery")) {
    if (!key.endsWith(".json")) continue;
    const file = await s.read("Recovery", key);
    const journal = file ? parseJournal(await readText(file)) : null;
    if (journal) journals.push(journal);
  }
  return journals;
}

/** `Blob.text()` is missing in jsdom; FileReader covers tests and very old engines. */
function readText(blob: Blob): Promise<string> {
  if (typeof blob.text === "function") return blob.text();
  return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(String(reader.result)); reader.onerror = () => reject(reader.error); reader.readAsText(blob); });
}

export async function clearJournal(recordingID: string, store?: MediaStore): Promise<void> {
  const s = store ?? (await mediaStore());
  await s.delete("Recovery", journalKey(recordingID));
}
