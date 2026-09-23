/* OWNER: storage agent. Large binary storage for recordings, exports and thumbnails.
   Prefers the Origin Private File System (streamed writes, no memory copies);
   falls back to IndexedDB blobs where OPFS is unavailable (older Safari, private windows).
   Keys are plain filenames such as `${recordingID}.mp4`, mirroring the iOS Documents/Recordings layout. */

export type MediaFolder = "Recordings" | "Exports" | "Thumbnails" | "Recovery";

export interface MediaStore {
  /** Streams a blob or a ReadableStream into the store, replacing any existing file. */
  write(folder: MediaFolder, key: string, data: Blob | ReadableStream<Uint8Array>): Promise<void>;
  /** Opens a writable handle for incremental capture writes (used by the camera recovery journal). */
  createWritable(folder: MediaFolder, key: string): Promise<WritableStream<Uint8Array>>;
  read(folder: MediaFolder, key: string): Promise<File | null>;
  /** Object URL for <video src>. Callers revoke it when done. */
  url(folder: MediaFolder, key: string): Promise<string | null>;
  exists(folder: MediaFolder, key: string): Promise<boolean>;
  delete(folder: MediaFolder, key: string): Promise<void>;
  list(folder: MediaFolder): Promise<string[]>;
  size(folder: MediaFolder): Promise<number>;
}

let instance: Promise<MediaStore> | null = null;

export function mediaStore(): Promise<MediaStore> {
  instance ??= (async () => {
    // Safari (< 26) exposes OPFS but not `createWritable`; streamed writes would throw, so use IndexedDB there.
    const hasOPFS = typeof navigator !== "undefined" && "getDirectory" in (navigator.storage ?? {});
    const canWrite = typeof FileSystemFileHandle !== "undefined" && "createWritable" in FileSystemFileHandle.prototype;
    if (hasOPFS && canWrite) {
      try { return await opfsStore(); } catch { /* fall through */ }
    }
    return indexedDBStore();
  })();
  return instance;
}

async function opfsStore(): Promise<MediaStore> {
  const root = await navigator.storage.getDirectory();
  const dir = (folder: MediaFolder) => root.getDirectoryHandle(folder, { create: true });
  const file = async (folder: MediaFolder, key: string, create = false) => (await dir(folder)).getFileHandle(key, { create });
  type Iterable = FileSystemDirectoryHandle & { keys(): AsyncIterableIterator<string>; values(): AsyncIterableIterator<FileSystemHandle> };
  const store: MediaStore = {
    async write(folder, key, data) {
      const handle = await file(folder, key, true);
      const writable = await handle.createWritable();
      if (data instanceof Blob) await data.stream().pipeTo(writable);
      else await data.pipeTo(writable);
    },
    async createWritable(folder, key) { return (await file(folder, key, true)).createWritable(); },
    async read(folder, key) { try { return await (await file(folder, key)).getFile(); } catch { return null; } },
    async url(folder, key) { const f = await store.read(folder, key); return f ? URL.createObjectURL(f) : null; },
    async exists(folder, key) { try { await file(folder, key); return true; } catch { return false; } },
    async delete(folder, key) { try { await (await dir(folder)).removeEntry(key); } catch { /* already gone */ } },
    async list(folder) { const names: string[] = []; for await (const name of ((await dir(folder)) as Iterable).keys()) names.push(name); return names; },
    async size(folder) { let total = 0; for await (const handle of ((await dir(folder)) as Iterable).values()) if (handle.kind === "file") total += (await (handle as FileSystemFileHandle).getFile()).size; return total; },
  };
  return store;
}

async function indexedDBStore(): Promise<MediaStore> {
  const { openDB } = await import("idb");
  const db = await openDB("camelot-media", 1, { upgrade(d) { d.createObjectStore("files"); } });
  const path = (folder: MediaFolder, key: string) => `${folder}/${key}`;
  const store: MediaStore = {
    async write(folder, key, data) {
      const blob = data instanceof Blob ? data : await new Response(data).blob();
      await db.put("files", blob, path(folder, key));
    },
    async createWritable(folder, key) {
      const chunks: Uint8Array[] = [];
      return new WritableStream<Uint8Array>({ write(chunk) { chunks.push(chunk); }, close: async () => { await store.write(folder, key, new Blob(chunks as BlobPart[])); } });
    },
    async read(folder, key) { const blob = (await db.get("files", path(folder, key))) as Blob | undefined; return blob ? new File([blob], key, { type: blob.type }) : null; },
    async url(folder, key) { const f = await store.read(folder, key); return f ? URL.createObjectURL(f) : null; },
    async exists(folder, key) { return (await db.getKey("files", path(folder, key))) !== undefined; },
    async delete(folder, key) { await db.delete("files", path(folder, key)); },
    async list(folder) { const keys = (await db.getAllKeys("files")) as string[]; return keys.filter((k) => k.startsWith(`${folder}/`)).map((k) => k.slice(folder.length + 1)); },
    async size(folder) { let total = 0; for (const key of await store.list(folder)) total += ((await db.get("files", path(folder, key))) as Blob).size; return total; },
  };
  return store;
}
