import type { Recording } from "@/domain";
import { newId, now } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import { recordings } from "@/storage/repository";
import { publishChange } from "@/storage/live";
import { probeVideo } from "./probe";

/* OWNER: media agent. Port of VideoImporter.swift: the bytes stream into the media store under
   Recordings/`${id}.${ext}` (never through memory or the sync API), then a Recording row is saved. */

const EXTENSION_BY_MIME: Record<string, string> = { "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm", "video/x-matroska": "mkv", "video/x-m4v": "m4v" };
const MIME_BY_EXTENSION: Record<string, string> = { mp4: "video/mp4", m4v: "video/x-m4v", mov: "video/quicktime", webm: "video/webm", mkv: "video/x-matroska" };

export function fileExtension(file: { name?: string; type?: string }): string {
  const fromName = file.name?.match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase();
  return fromName ?? EXTENSION_BY_MIME[file.type?.split(";")[0] ?? ""] ?? "mp4";
}

export const mimeTypeForKey = (key: string) => MIME_BY_EXTENSION[key.split(".").pop()?.toLowerCase() ?? ""] ?? "video/mp4";

export function localTimezone(): { timezoneIdentifier: string; utcOffsetSeconds: number } {
  let timezoneIdentifier = "UTC";
  try { timezoneIdentifier = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; } catch { /* keep UTC */ }
  return { timezoneIdentifier, utcOffsetSeconds: -new Date().getTimezoneOffset() * 60 };
}

/** Streams `source` into `key` while reporting bytes written as a fraction of `total`. */
export function progressStream(source: ReadableStream<Uint8Array>, total: number, onProgress?: (fraction: number) => void): ReadableStream<Uint8Array> {
  if (!onProgress) return source;
  let written = 0;
  return source.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) { written += chunk.byteLength; onProgress(total > 0 ? Math.min(1, written / total) : 0); controller.enqueue(chunk); },
  }));
}

export async function importRecording(projectID: string, file: File, onProgress?: (fraction: number) => void): Promise<Recording> {
  const probe = await probeVideo(file);
  const id = newId();
  const key = `${id}.${fileExtension(file)}`;
  const store = await mediaStore();
  await store.write("Recordings", key, progressStream(file.stream(), file.size, onProgress));
  onProgress?.(1);
  const siblings = await recordings.forProject(projectID);
  const recordedAt = new Date(file.lastModified || Date.now()).toISOString();
  const name = file.name.replace(/\.[a-z0-9]{2,5}$/i, "").trim() || "Imported video";
  const recording: Recording = {
    id, projectID, localPath: key, name, createdAt: now(), duration: probe.duration,
    uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
    segmentIndex: siblings.length, endedReason: "import", recordedAt, ...localTimezone(),
    width: probe.width, height: probe.height, mimeType: probe.mimeType || file.type || mimeTypeForKey(key),
    serverVersion: null, needsSync: true, mutationID: newId(),
  };
  const saved = await recordings.save(recording);
  publishChange("media");
  return saved;
}

/** Removes the video bytes and every persisted thumbnail for a recording. Does not touch the metadata row. */
export async function deleteRecordingFiles(recording: Pick<Recording, "id" | "localPath">): Promise<void> {
  const store = await mediaStore();
  if (recording.localPath) await store.delete("Recordings", recording.localPath);
  const prefix = `${recording.id}-`;
  for (const key of await store.list("Thumbnails")) if (key.startsWith(prefix)) await store.delete("Thumbnails", key);
  publishChange("media");
}

/** Object URL for `<video src>`. Callers must `URL.revokeObjectURL` it when the element unmounts. */
export async function recordingURL(recording: Pick<Recording, "localPath">): Promise<string | null> {
  if (!recording.localPath) return null;
  return (await mediaStore()).url("Recordings", recording.localPath);
}

export async function recordingFile(recording: Pick<Recording, "localPath">): Promise<File | null> {
  if (!recording.localPath) return null;
  return (await mediaStore()).read("Recordings", recording.localPath);
}
