import type { Recording } from "@/domain";
import type { MediaFolder, MediaStore } from "@/storage/media-store";
import type { RecordingStore } from "./library";

/* In-memory doubles for media tests. */

export function fakeMediaStore(): MediaStore & { files: Map<string, File> } {
  const files = new Map<string, File>();
  const path = (folder: MediaFolder, key: string) => `${folder}/${key}`;
  const store: MediaStore & { files: Map<string, File> } = {
    files,
    async write(folder, key, data) {
      const blob = data instanceof Blob ? data : await new Response(data).blob();
      files.set(path(folder, key), new File([blob], key, { type: blob.type, lastModified: Date.now() }));
    },
    async createWritable(folder, key) {
      const chunks: Uint8Array[] = [];
      return new WritableStream<Uint8Array>({ write(c) { chunks.push(c); }, close: async () => { await store.write(folder, key, new Blob(chunks as BlobPart[])); } });
    },
    async read(folder, key) { return files.get(path(folder, key)) ?? null; },
    async url(folder, key) { return files.has(path(folder, key)) ? `blob:${folder}/${key}` : null; },
    async exists(folder, key) { return files.has(path(folder, key)); },
    async delete(folder, key) { files.delete(path(folder, key)); },
    async list(folder) { return Array.from(files.keys()).filter((k) => k.startsWith(`${folder}/`)).map((k) => k.slice(folder.length + 1)); },
    async size(folder) { let n = 0; for (const [k, f] of files) if (k.startsWith(`${folder}/`)) n += f.size; return n; },
  };
  return store;
}

export function fakeRecordingStore(initial: Recording[] = []): RecordingStore & { rows: Map<string, Recording> } {
  const rows = new Map(initial.map((r) => [r.id, r]));
  return { rows, all: async () => Array.from(rows.values()), save: async (r) => { rows.set(r.id, r); return r; } };
}

export function fakeRecording(overrides: Partial<Recording> = {}): Recording {
  return {
    id: "A", projectID: "P", localPath: "A.mp4", name: "Clip", createdAt: "2026-01-01T00:00:00.000Z", duration: 10,
    uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, segmentIndex: 0, endedReason: "user",
    recordedAt: "2026-01-01T00:00:00.000Z", timezoneIdentifier: "UTC", utcOffsetSeconds: 0,
    serverVersion: null, needsSync: false, mutationID: "M", ...overrides,
  };
}

/** A File whose `lastModified` is set explicitly (fakeMediaStore.write stamps "now"). */
export function fileAt(folderKey: string, bytes: number, lastModified: number, store: ReturnType<typeof fakeMediaStore>) {
  const [folder, key] = folderKey.split("/") as [MediaFolder, string];
  store.files.set(`${folder}/${key}`, new File([new Uint8Array(bytes)], key, { lastModified }));
}
