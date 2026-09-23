import { useEffect, useState } from "react";
import type { Recording } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import { recordings } from "@/storage/repository";
import { WorkerClient } from "@/workers/client";
import { detectMediaCapabilities } from "./capabilities";
import { LRUCache } from "./lru";
import { thumbnailBucketMs, thumbnailKey } from "./thumbnail-keys";

/* OWNER: media agent. Port of VideoThumbnailService: coalesced requests, one decode at a time,
   a bounded in-memory cache and JPEGs persisted in the media store so strips survive reloads.
   Decoding happens in media.worker.ts; when WebCodecs is missing (or the codec is not decodable
   there) frames are captured from a <video> element on the main thread instead. */

export interface ThumbnailEntry { url: string; bitmap: ImageBitmap | null; bytes: number }

const MAX_ENTRIES = 400;
const MAX_BYTES = 64 * 1024 * 1024;
const BATCH_SIZE = 8;
/** Seconds within which an already-cached neighbour is shown while the exact frame decodes. */
const NEAREST_TOLERANCE = 3;

const cache = new LRUCache<ThumbnailEntry>({
  maxCount: MAX_ENTRIES,
  maxCost: MAX_BYTES,
  cost: (e) => e.bytes,
  onEvict: (_key, e) => { URL.revokeObjectURL(e.url); e.bitmap?.close(); },
});
const inFlight = new Map<string, Promise<ThumbnailEntry | null>>();
const fileKeys = new Map<string, string>();

interface Pending { recordingID: string; fileKey: string; time: number; height: number; resolve: (e: ThumbnailEntry | null) => void }
const queue: Pending[] = [];
let draining = false;
let worker: WorkerClient | null = null;

function mediaWorker(): WorkerClient {
  worker ??= new WorkerClient(new Worker(new URL("../workers/media.worker.ts", import.meta.url), { type: "module" }));
  return worker;
}

async function resolveFileKey(recordingID: string, fileKey?: string): Promise<string | null> {
  if (fileKey) { fileKeys.set(recordingID, fileKey); return fileKey; }
  const known = fileKeys.get(recordingID);
  if (known) return known;
  const recording = await recordings.get(recordingID);
  if (!recording?.localPath) return null;
  fileKeys.set(recordingID, recording.localPath);
  return recording.localPath;
}

/** Exact cached entry, or the nearest cached neighbour within `tolerance` seconds. */
export function peekThumbnail(recordingID: string, time: number, height: number, tolerance = NEAREST_TOLERANCE): ThumbnailEntry | null {
  const exact = cache.peek(thumbnailKey(recordingID, time, height));
  if (exact) return exact;
  const prefix = `${recordingID}-`, suffix = `-${Math.round(height)}.jpg`, target = thumbnailBucketMs(time);
  let best: { distance: number; key: string } | null = null;
  for (const key of cache.keys()) {
    if (!key.startsWith(prefix) || !key.endsWith(suffix)) continue;
    const ms = Number(key.slice(prefix.length, key.length - suffix.length));
    const distance = Math.abs(ms - target);
    if (distance <= tolerance * 1000 && (!best || distance < best.distance)) best = { distance, key };
  }
  return best ? cache.peek(best.key) ?? null : null;
}

async function entryFromBlob(jpeg: Blob | null): Promise<ThumbnailEntry | null> {
  if (!jpeg || jpeg.size === 0) return null;
  let bitmap: ImageBitmap | null = null;
  try { bitmap = typeof createImageBitmap === "function" ? await createImageBitmap(jpeg) : null; } catch { bitmap = null; }
  return { url: URL.createObjectURL(jpeg), bitmap, bytes: bitmap ? bitmap.width * bitmap.height * 4 : jpeg.size * 8 };
}

function enqueue(recordingID: string, fileKey: string, time: number, height: number): Promise<ThumbnailEntry | null> {
  const key = thumbnailKey(recordingID, time, height);
  const existing = inFlight.get(key);
  if (existing) return existing;
  const promise = new Promise<ThumbnailEntry | null>((resolve) => { queue.push({ recordingID, fileKey, time, height, resolve }); });
  inFlight.set(key, promise);
  promise.finally(() => inFlight.delete(key));
  void drain();
  return promise;
}

async function drain() {
  if (draining) return;
  draining = true;
  try {
    while (queue.length) {
      const head = queue[0]!;
      const batch = queue.filter((item) => item.recordingID === head.recordingID && item.height === head.height).slice(0, BATCH_SIZE);
      for (const item of batch) queue.splice(queue.indexOf(item), 1);
      const times = Array.from(new Set(batch.map((b) => b.time)));
      let blobs: Map<number, Blob | null>;
      try { blobs = await decodeBatch(head.recordingID, head.fileKey, times, head.height); }
      catch { blobs = new Map(times.map((t) => [t, null])); }
      for (const item of batch) {
        const key = thumbnailKey(item.recordingID, item.time, item.height);
        const entry = cache.peek(key) ?? (await entryFromBlob(blobs.get(item.time) ?? null));
        if (entry && !cache.has(key)) cache.set(key, entry);
        item.resolve(entry);
      }
    }
  } finally { draining = false; }
}

async function decodeBatch(recordingID: string, fileKey: string, times: number[], height: number): Promise<Map<number, Blob | null>> {
  if (detectMediaCapabilities().webCodecs) {
    try {
      const output = await mediaWorker().run("media.thumbnails", { recordingID, fileKey, times, height }).result;
      const map = new Map(output.map((o) => [o.time, o.jpeg]));
      if (Array.from(map.values()).some((b) => b !== null) || typeof document === "undefined") return map;
    } catch (error) {
      if (typeof document === "undefined") throw error;
    }
  }
  return captureWithVideoElement(recordingID, fileKey, times, height);
}

/** Main-thread fallback: seek a <video> and copy frames through a canvas. Slow but codec-agnostic. */
async function captureWithVideoElement(recordingID: string, fileKey: string, times: number[], height: number): Promise<Map<number, Blob | null>> {
  const store = await mediaStore();
  const results = new Map<number, Blob | null>();
  const url = await store.url("Recordings", fileKey);
  if (!url) return new Map(times.map((t) => [t, null]));
  const video = document.createElement("video");
  video.muted = true; video.preload = "auto"; video.playsInline = true;
  try {
    await new Promise<void>((resolve, reject) => { video.onloadeddata = () => resolve(); video.onerror = () => reject(new Error("Video failed to load.")); video.src = url; });
    const scale = height / Math.max(1, video.videoHeight);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(video.videoWidth * scale)); canvas.height = Math.round(height);
    const context = canvas.getContext("2d")!;
    for (const time of times.slice().sort((a, b) => a - b)) {
      const cached = await store.read("Thumbnails", thumbnailKey(recordingID, time, height));
      if (cached && cached.size > 0) { results.set(time, cached); continue; }
      await new Promise<void>((resolve) => { video.onseeked = () => resolve(); video.currentTime = Math.max(0, Math.min(time, Number.isFinite(video.duration) ? video.duration - 1 / 30 : time)); });
      context.drawImage(video, 0, 0, canvas.width, canvas.height);
      const jpeg = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.78));
      if (jpeg) store.write("Thumbnails", thumbnailKey(recordingID, time, height), jpeg).catch(() => {});
      results.set(time, jpeg);
    }
  } catch {
    for (const time of times) if (!results.has(time)) results.set(time, null);
  } finally {
    video.removeAttribute("src"); video.load(); URL.revokeObjectURL(url);
  }
  return results;
}

async function requestEntry(recordingID: string, time: number, height: number, fileKey?: string): Promise<ThumbnailEntry | null> {
  const exact = cache.get(thumbnailKey(recordingID, time, height));
  if (exact) return exact;
  const key = await resolveFileKey(recordingID, fileKey);
  if (!key) return null;
  return enqueue(recordingID, key, Math.max(0, time), height);
}

/** Decoded thumbnail for `<canvas>` consumers. The bitmap is owned by the cache; do not close it. */
export async function requestThumbnail(recordingID: string, timeSeconds: number, height: number, fileKey?: string): Promise<ImageBitmap | null> {
  return (await requestEntry(recordingID, timeSeconds, height, fileKey))?.bitmap ?? null;
}

/** Object URL for `<img>` consumers. Owned by the cache; do not revoke it. */
export async function requestThumbnailURL(recordingID: string, timeSeconds: number, height: number, fileKey?: string): Promise<string | null> {
  return (await requestEntry(recordingID, timeSeconds, height, fileKey))?.url ?? null;
}

/** Timeline strips: resolves each time as it lands (cached ones synchronously first), in batches of one decode job. */
export async function thumbnailStrip(recordingID: string, times: number[], height: number, onEach: (time: number, url: string | null, bitmap: ImageBitmap | null) => void, fileKey?: string): Promise<void> {
  const key = await resolveFileKey(recordingID, fileKey);
  if (!key) { for (const t of times) onEach(t, null, null); return; }
  const missing: number[] = [];
  for (const time of times) {
    const hit = cache.get(thumbnailKey(recordingID, time, height));
    if (hit) onEach(time, hit.url, hit.bitmap); else missing.push(time);
  }
  await Promise.all(missing.map((time) => enqueue(recordingID, key, Math.max(0, time), height).then((entry) => onEach(time, entry?.url ?? null, entry?.bitmap ?? null))));
}

/** Drops queued work for a recording (e.g. when the editor closes) without touching cached images. */
export function cancelThumbnails(recordingID: string) {
  for (let i = queue.length - 1; i >= 0; i--) if (queue[i]?.recordingID === recordingID) queue.splice(i, 1).forEach((item) => item.resolve(null));
}

export function clearThumbnailCache() { cache.clear(); fileKeys.clear(); }

/** Returns an object URL for `<img src>`, keeping the previous/nearest image while the exact frame decodes (no flicker during pinch/scrub). */
export function useThumbnail(recording: Recording | undefined, timeSeconds: number, height = 120): string | null {
  const id = recording?.id, fileKey = recording?.localPath, bucket = thumbnailBucketMs(timeSeconds);
  const [url, setUrl] = useState<string | null>(() => (id ? peekThumbnail(id, timeSeconds, height)?.url ?? null : null));
  useEffect(() => {
    if (!id || !fileKey) { setUrl(null); return; }
    const peeked = peekThumbnail(id, timeSeconds, height);
    if (peeked) setUrl(peeked.url);
    let cancelled = false;
    requestEntry(id, timeSeconds, height, fileKey).then((entry) => { if (!cancelled && entry) setUrl(entry.url); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, fileKey, bucket, height]);
  return url;
}
