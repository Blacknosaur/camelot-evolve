import { CanvasSink, type Input, type InputVideoTrack } from "mediabunny";
import { mediaStore } from "@/storage/media-store";
import { openInput, probeVideo } from "@/media/probe";
import { thumbnailKey } from "@/media/thumbnail-keys";
import { serveJobs } from "./host";

/* OWNER: media agent. Decodes thumbnails and probes files off the main thread. Keeps a few open
   demuxers per file so consecutive strip requests reuse the decoder (VideoThumbnail.swift kept 12
   AVAssetImageGenerators for the same reason). */

interface OpenSource { input: Input; track: InputVideoTrack; sinks: Map<number, CanvasSink>; lastUsed: number }

const MAX_OPEN_SOURCES = 4;
const JPEG_QUALITY = 0.78;
const sources = new Map<string, OpenSource>();
let chain: Promise<unknown> = Promise.resolve();

/** Decoders are not thread-safe per file; run thumbnail jobs one after another. */
function sequential<T>(work: () => Promise<T>): Promise<T> {
  const next = chain.then(work, work);
  chain = next.catch(() => {});
  return next;
}

async function readFile(fileKey: string): Promise<File> {
  const file = await (await mediaStore()).read("Recordings", fileKey);
  if (!file) throw new Error(`Missing media file ${fileKey}.`);
  return file;
}

async function source(fileKey: string): Promise<OpenSource> {
  const existing = sources.get(fileKey);
  if (existing) { existing.lastUsed = Date.now(); return existing; }
  const input = openInput(await readFile(fileKey));
  const track = await input.getPrimaryVideoTrack();
  if (!track) { input.dispose(); throw new Error("The file has no video track."); }
  const opened: OpenSource = { input, track, sinks: new Map(), lastUsed: Date.now() };
  sources.set(fileKey, opened);
  if (sources.size > MAX_OPEN_SOURCES) {
    const oldest = Array.from(sources.entries()).sort((a, b) => a[1].lastUsed - b[1].lastUsed)[0];
    if (oldest) { oldest[1].input.dispose(); sources.delete(oldest[0]); }
  }
  return opened;
}

function sinkFor(open: OpenSource, height: number): CanvasSink {
  let sink = open.sinks.get(height);
  if (!sink) { sink = new CanvasSink(open.track, { height, poolSize: 2 }); open.sinks.set(height, sink); }
  return sink;
}

serveJobs({
  "media.probe": async ({ fileKey }) => probeVideo(await readFile(fileKey)),

  "media.thumbnails": ({ recordingID, fileKey, times, height }, { signal, progress }) => sequential(async () => {
    const store = await mediaStore();
    const results = new Map<number, Blob | null>();
    const missing: number[] = [];
    for (const time of times) {
      const cached = await store.read("Thumbnails", thumbnailKey(recordingID, time, height));
      if (cached && cached.size > 0) results.set(time, cached); else missing.push(time);
    }
    progress({ done: results.size, total: times.length });
    if (missing.length && !signal.aborted) {
      if (typeof VideoDecoder === "undefined") throw new Error("WebCodecs is unavailable in this worker.");
      const open = await source(fileKey);
      const sink = sinkFor(open, height);
      const sorted = Array.from(new Set(missing)).sort((a, b) => a - b);
      let index = 0;
      for await (const wrapped of sink.canvasesAtTimestamps(sorted)) {
        const time = sorted[index++];
        if (time === undefined || signal.aborted) break;
        let jpeg: Blob | null = null;
        if (wrapped) {
          const canvas = wrapped.canvas as OffscreenCanvas;
          jpeg = await canvas.convertToBlob({ type: "image/jpeg", quality: JPEG_QUALITY });
          store.write("Thumbnails", thumbnailKey(recordingID, time, height), jpeg).catch(() => {});
        }
        results.set(time, jpeg);
        progress({ done: results.size, total: times.length });
      }
    }
    return times.map((time) => ({ time, jpeg: results.get(time) ?? null }));
  }),
});
