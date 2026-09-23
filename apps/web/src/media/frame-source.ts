import { VideoSampleSink, type Input, type InputVideoTrack } from "mediabunny";
import type { Recording } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import { openInput } from "./probe";

/* OWNER: media agent. Port of FieldFrameSource.swift: one demuxer + one decoder per source for a
   whole session. DOM-free so vision/export workers can use it. Requires WebCodecs (VideoFrame);
   there is no <video> fallback here because a VideoFrame cannot be produced without WebCodecs.

   Ownership: every VideoFrame handed out is owned by the caller and MUST be closed with
   `frame.close()` once drawn/analysed, otherwise the decoder stalls after a few frames. */

export interface FrameSource {
  duration: number;
  /** Display size after container rotation. */
  width: number;
  height: number;
  frameRate: number;
  /** The frame displayed at `time` (the last frame whose timestamp <= time). Caller closes it. */
  frameAt(time: number): Promise<VideoFrame | null>;
  /** Sequential frames in [start, end]. With `fps`, samples on a fixed grid; otherwise every decoded frame. Caller closes each frame. */
  frames(start: number, end: number, fps?: number, signal?: AbortSignal): AsyncIterable<{ time: number; frame: VideoFrame }>;
  close(): void;
}

const LOOK_AHEAD = 2;

export async function openFrameSource(source: Pick<Recording, "localPath"> | string): Promise<FrameSource> {
  if (typeof VideoFrame === "undefined") throw new Error("WebCodecs is unavailable; frame decoding needs VideoFrame support.");
  const key = typeof source === "string" ? source : source.localPath;
  if (!key) throw new Error("The recording has no local file.");
  const file = await (await mediaStore()).read("Recordings", key);
  if (!file) throw new Error(`Missing media file ${key}.`);
  return frameSourceFromBlob(file);
}

export async function frameSourceFromBlob(file: Blob): Promise<FrameSource> {
  const input = openInput(file);
  const track = await input.getPrimaryVideoTrack();
  if (!track) { input.dispose(); throw new Error("The file has no video track."); }
  if (!(await track.canDecode())) { input.dispose(); throw new Error(`This browser cannot decode ${track.codec ?? "the video codec"}.`); }
  return new MediabunnyFrameSource(input, track, await input.computeDuration([track]), await track.getDisplayWidth(), await track.getDisplayHeight(), await frameRateOf(track));
}

async function frameRateOf(track: InputVideoTrack): Promise<number> {
  try { const stats = await track.computePacketStats(120); return stats.averagePacketRate > 0 ? stats.averagePacketRate : 30; } catch { return 30; }
}

class MediabunnyFrameSource implements FrameSource {
  private sink: VideoSampleSink;
  private closed = false;

  constructor(private input: Input, track: InputVideoTrack, public duration: number, public width: number, public height: number, public frameRate: number) {
    this.sink = new VideoSampleSink(track);
  }

  async frameAt(time: number): Promise<VideoFrame | null> {
    this.assertOpen();
    const sample = await this.sink.getSample(Math.max(0, Math.min(time, this.duration)));
    if (!sample) return null;
    try { return sample.toVideoFrame(); } finally { sample.close(); }
  }

  async *frames(start: number, end: number, fps?: number, signal?: AbortSignal): AsyncIterable<{ time: number; frame: VideoFrame }> {
    this.assertOpen();
    const from = Math.max(0, start), to = Math.min(this.duration, end);
    const samples = fps && fps > 0 ? this.sink.samplesAtTimestamps(grid(from, to, fps)) : this.sink.samples(from, to);
    // Small look-ahead: keep LOOK_AHEAD decode promises pending while the consumer works on the current frame.
    const pending: ReturnType<typeof samples.next>[] = [];
    const pull = () => { pending.push(samples.next()); };
    for (let i = 0; i < LOOK_AHEAD; i++) pull();
    try {
      while (pending.length) {
        const result = await pending.shift()!;
        if (result.done) break;
        pull();
        const sample = result.value;
        if (!sample) continue;
        if (signal?.aborted || this.closed) { sample.close(); break; }
        const time = sample.timestamp;
        const frame = sample.toVideoFrame();
        sample.close();
        yield { time, frame };
      }
    } finally {
      await samples.return(undefined);
      for (const p of pending) p.then((r) => { if (!r.done) r.value?.close(); }, () => {});
    }
  }

  close() { if (this.closed) return; this.closed = true; this.input.dispose(); }

  private assertOpen() { if (this.closed) throw new Error("FrameSource is closed."); }
}

function* grid(start: number, end: number, fps: number): Generator<number> {
  const step = 1 / fps;
  for (let i = 0, t = start; t <= end + 1e-6; i++, t = start + i * step) yield Math.min(t, end);
}
