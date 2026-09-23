import {
  ALL_FORMATS, AppendOnlyStreamTarget, AudioSample, AudioSampleSink, AudioSampleSource, BlobSource, CanvasSource, Input,
  Mp4OutputFormat, Output, StreamTarget, WebMOutputFormat, getFirstEncodableAudioCodec, getFirstEncodableVideoCodec,
  type AudioCodec, type InputAudioTrack, type OutputFormat, type StreamTargetChunk, type Target, type VideoCodec,
} from "mediabunny";
import type { CompositionClip, Recording, VideoComposition } from "@/domain/records";
import { clipPlaybackDuration, compositionDuration } from "@/domain/records";
import { mediaStore, type MediaStore } from "@/storage/media-store";
import { openFrameSource, type FrameSource } from "@/media/frame-source";
import { drawAnnotations } from "@/features/analysis/render/draw";
import { clampFrameRate, displayFrame, frameCount, frameTime, locateInClip, outputSize, type ResolutionPreset } from "./preview-parity";

/* Port of CompositionRenderer (CompositionPlayerView.swift) + EditorSequencePreview + AnalysisVideoCompositor.
   Runs inside the export worker: decodes each clip through the shared FrameSource, retimes frames onto a constant
   output fps (rate → drop/duplicate, freezeDuration → hold), crops to the composition aspect, draws the clip's
   annotations with the same renderer the analysis workspace uses, and muxes with mediabunny straight into the
   media store ("Exports" folder) so multi-GB files never sit in memory.

   Audio: clips at rate 1 pass their source audio through (resampled to 48 kHz stereo). Other rates use a
   varispeed resample (pitch follows speed, like AVFoundation's scaleTimeRange on the iOS export); held frames
   and silent sources contribute silence so the track stays aligned with the picture. */

export type FpsChoice = "source" | 24 | 30 | 60;

export interface ExportSettings {
  resolution: ResolutionPreset;
  fps: FpsChoice;
}

export const DEFAULT_EXPORT_SETTINGS: ExportSettings = { resolution: "source", fps: "source" };

export interface ExportRequest {
  composition: Pick<VideoComposition, "id" | "name" | "clips" | "aspectRatio">;
  /** Every recording referenced by the clips (main thread resolves them from the repository). */
  recordings: Recording[];
  settings: ExportSettings;
  /** `renderRevision(composition)`; stored in the sidecar so unchanged manifests skip re-rendering. */
  revision: string;
}

/** Sidecar written next to the file once a render completes; the file alone is never trusted. */
export interface ExportArtifact {
  key: string;
  mimeType: string;
  bytes: number;
  width: number;
  height: number;
  fps: number;
  duration: number;
  videoCodec: VideoCodec;
  audioCodec: AudioCodec | null;
  revision: string;
  settings: ExportSettings;
  createdAt: string;
}

export interface ExportProgress { fraction: number; stage: string }

export interface RenderContext { signal: AbortSignal; progress(p: ExportProgress): void }

export const exportSidecarKey = (compositionID: string) => `${compositionID}.export.json`;

export class UnsupportedExportError extends Error {
  constructor(message: string) { super(message); this.name = "UnsupportedExportError"; }
}

const AUDIO_SAMPLE_RATE = 48_000;
const AUDIO_CHANNELS = 2;
const SILENCE_FRAMES = 1024;
const PROGRESS_INTERVAL_MS = 200;

/** Returns the cached artifact when the sidecar matches the revision and settings and the file is present. */
export async function cachedExport(store: MediaStore, compositionID: string, revision: string, settings: ExportSettings): Promise<ExportArtifact | null> {
  const sidecar = await store.read("Exports", exportSidecarKey(compositionID));
  if (!sidecar) return null;
  try {
    const artifact = JSON.parse(await sidecar.text()) as ExportArtifact;
    if (artifact.revision !== revision || artifact.settings.resolution !== settings.resolution || artifact.settings.fps !== settings.fps) return null;
    const file = await store.read("Exports", artifact.key);
    return file && file.size > 0 ? { ...artifact, bytes: file.size } : null;
  } catch { return null; }
}

export async function renderComposition(request: ExportRequest, context: RenderContext): Promise<ExportArtifact> {
  const { composition, settings } = request;
  const clips = composition.clips.filter((clip) => clip.freezeDuration != null || clip.endSeconds > clip.startSeconds);
  if (clips.length === 0) throw new Error("The composition has no clips to render.");
  if (typeof OffscreenCanvas === "undefined" || typeof VideoFrame === "undefined") throw new UnsupportedExportError("This browser cannot render video in the background (OffscreenCanvas/WebCodecs missing).");

  const store = await mediaStore();
  const cached = await cachedExport(store, composition.id, request.revision, settings);
  if (cached) { context.progress({ fraction: 1, stage: "Already rendered" }); return cached; }

  context.progress({ fraction: 0, stage: "Preparing" });
  const sources = new Map<string, ClipSource>();
  let output: Output | null = null;
  let outputKey: string | null = null;
  const throwIfAborted = () => { if (context.signal.aborted) throw new DOMException("Export cancelled", "AbortError"); };

  try {
    for (const clip of clips) {
      if (sources.has(clip.recordingID)) continue;
      const recording = request.recordings.find((r) => r.id === clip.recordingID);
      if (!recording?.localPath) throw new Error(`Recording ${clip.recordingID} has no local media file.`);
      sources.set(clip.recordingID, await openClipSource(store, recording));
      throwIfAborted();
    }
    const first = sources.get(clips[0]!.recordingID)!;
    const size = outputSize({ width: first.frames.width, height: first.frames.height }, composition.aspectRatio, settings.resolution);
    const fps = settings.fps === "source" ? clampFrameRate(Math.max(...[...sources.values()].map((s) => s.frames.frameRate || 30))) : settings.fps;
    const duration = compositionDuration(clips);
    const totalFrames = frameCount(duration, fps);

    const videoCodec = await pickVideoCodec(size.width, size.height, fps);
    const container = videoCodec === "avc" ? "mp4" : "webm";
    const needsAudio = clips.some((clip) => clip.freezeDuration == null && sources.get(clip.recordingID)?.audio);
    const audioCodec = needsAudio ? await pickAudioCodec(container) : null;

    outputKey = `${composition.id}.${container}`;
    await store.delete("Exports", exportSidecarKey(composition.id));
    const { target, randomAccess } = await openTarget(store, outputKey);
    const format: OutputFormat = container === "mp4"
      ? new Mp4OutputFormat({ fastStart: randomAccess ? false : "fragmented" })
      : new WebMOutputFormat({ appendOnly: !randomAccess });
    output = new Output({ format, target });

    const canvas = new OffscreenCanvas(size.width, size.height);
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) throw new Error("Could not create a drawing context for the export.");
    const video = new CanvasSource(canvas, { codec: videoCodec, bitrate: videoBitrate(size.width, size.height, fps), keyFrameInterval: 2 });
    output.addVideoTrack(video, { frameRate: fps });
    const audio = audioCodec ? new AudioSampleSource({ codec: audioCodec, bitrate: 160_000, transform: { sampleRate: AUDIO_SAMPLE_RATE, numberOfChannels: AUDIO_CHANNELS } }) : null;
    if (audio) output.addAudioTrack(audio);
    await output.start();

    let frameIndex = 0;
    let clipStart = 0;
    let lastReport = 0;
    for (let clipIndex = 0; clipIndex < clips.length; clipIndex++) {
      const clip = clips[clipIndex]!;
      const source = sources.get(clip.recordingID)!;
      const clipEnd = clipStart + clipPlaybackDuration(clip);
      const lastFrame = clipIndex === clips.length - 1 ? totalFrames : Math.min(totalFrames, Math.round(clipEnd * fps));
      const frame = displayFrame({ width: source.frames.width, height: source.frames.height }, size, composition.aspectRatio);
      const stage = clips.length > 1 ? `Rendering clip ${clipIndex + 1} of ${clips.length}` : "Rendering";
      const picker = clip.freezeDuration == null ? sequentialFrames(source.frames, clip, context.signal) : heldFrame(source.frames, clip);
      const audioFeed = audio ? clipAudio(source, clip, clipStart, clipEnd) : null;
      let pendingAudio = audioFeed ? await audioFeed.next() : null;
      try {
        for (; frameIndex < lastFrame; frameIndex++) {
          throwIfAborted();
          const time = frameTime(frameIndex, fps);
          const location = locateInClip(clip, clipStart, time);
          const image = await picker.frameFor(location.sourceTime);
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, size.width, size.height);
          if (image) ctx.drawImage(image, frame.x, frame.y, frame.width, frame.height);
          if (clip.annotations.length > 0) {
            ctx.save();
            ctx.translate(frame.x, frame.y);
            drawAnnotations(ctx, clip.annotations, location.annotationTime, { width: frame.width, height: frame.height }, { ground: clip.groundCalibration ?? null, bounds: { x: -frame.x, y: -frame.y, width: size.width, height: size.height } });
            ctx.restore();
          }
          await video.add(time, 1 / fps);
          // Keep audio within a second of the picture so the muxer interleaves instead of buffering a whole clip.
          while (audio && audioFeed && pendingAudio && !pendingAudio.done && pendingAudio.value.timestamp < time + 1) {
            const sample = pendingAudio.value;
            await audio.add(sample);
            sample.close();
            pendingAudio = await audioFeed.next();
          }
          const nowMs = Date.now();
          if (nowMs - lastReport > PROGRESS_INTERVAL_MS) { lastReport = nowMs; context.progress({ fraction: 0.02 + 0.93 * (frameIndex / Math.max(1, totalFrames)), stage }); }
        }
        while (audio && audioFeed && pendingAudio && !pendingAudio.done) { const sample = pendingAudio.value; await audio.add(sample); sample.close(); pendingAudio = await audioFeed.next(); }
      } finally {
        picker.close();
        if (pendingAudio && !pendingAudio.done) pendingAudio.value.close();
        await audioFeed?.return(undefined);
      }
      clipStart = clipEnd;
    }

    context.progress({ fraction: 0.96, stage: "Finishing" });
    await output.finalize();
    output = null;
    const file = await store.read("Exports", outputKey);
    const artifact: ExportArtifact = {
      key: outputKey, mimeType: format.mimeType, bytes: file?.size ?? 0, width: size.width, height: size.height, fps, duration,
      videoCodec, audioCodec, revision: request.revision, settings, createdAt: new Date().toISOString(),
    };
    await store.write("Exports", exportSidecarKey(composition.id), new Blob([JSON.stringify(artifact)], { type: "application/json" }));
    context.progress({ fraction: 1, stage: "Done" });
    return artifact;
  } catch (error) {
    if (output) await output.cancel().catch(() => {});
    if (outputKey) await store.delete("Exports", outputKey).catch(() => {});
    throw error;
  } finally {
    for (const source of sources.values()) source.close();
  }
}

/* ---------- sources ---------- */

interface ClipSource {
  frames: FrameSource;
  /** Audio track of the same file, when present and decodable. */
  audio: InputAudioTrack | null;
  close(): void;
}

async function openClipSource(store: MediaStore, recording: Recording): Promise<ClipSource> {
  const frames = await openFrameSource(recording);
  const file = await store.read("Recordings", recording.localPath);
  let input: Input | null = null;
  let audio: InputAudioTrack | null = null;
  if (file) {
    input = new Input({ source: new BlobSource(file), formats: ALL_FORMATS });
    try {
      const track = await input.getPrimaryAudioTrack();
      audio = track && (await track.canDecode()) ? track : null;
    } catch { audio = null; }
  }
  return { frames, audio, close: () => { frames.close(); input?.dispose(); } };
}

/* ---------- video frame selection ---------- */

interface FramePicker {
  /** The frame displayed at `sourceTime`: the latest decoded frame at or before it (drop/duplicate for rate changes). */
  frameFor(sourceTime: number): Promise<VideoFrame | null>;
  close(): void;
}

function sequentialFrames(source: FrameSource, clip: CompositionClip, signal: AbortSignal): FramePicker {
  const iterator = source.frames(clip.startSeconds, clip.endSeconds, undefined, signal)[Symbol.asyncIterator]();
  let current: { time: number; frame: VideoFrame } | null = null;
  let peeked: IteratorResult<{ time: number; frame: VideoFrame }> | null = null;
  let done = false;
  return {
    async frameFor(sourceTime) {
      while (!done) {
        peeked ??= await iterator.next();
        if (peeked.done) { done = true; break; }
        if (peeked.value.time > sourceTime + 1e-6) break;
        current?.frame.close();
        current = peeked.value;
        peeked = null;
      }
      if (!current) {
        // The decoder's first sample can land after a mid-GOP start; fall back to a direct seek once.
        const frame = await source.frameAt(sourceTime);
        if (frame) current = { time: sourceTime, frame };
      }
      return current?.frame ?? null;
    },
    close() {
      current?.frame.close();
      if (peeked && !peeked.done) peeked.value.frame.close();
      void iterator.return?.();
    },
  };
}

function heldFrame(source: FrameSource, clip: CompositionClip): FramePicker {
  let frame: Promise<VideoFrame | null> | null = null;
  return {
    frameFor: () => (frame ??= source.frameAt(clip.startSeconds)),
    close() { void frame?.then((f) => f?.close()); },
  };
}

/* ---------- audio ---------- */

/** Audio for one clip on the output timeline: source audio at rate 1, varispeed otherwise, silence for held frames. */
async function* clipAudio(source: ClipSource, clip: CompositionClip, clipStart: number, clipEnd: number): AsyncGenerator<AudioSample> {
  if (clip.freezeDuration != null || !source.audio) { yield* silence(clipStart, clipEnd); return; }
  const rate = Math.max(0.25, Math.min(4, clip.rate));
  const sink = new AudioSampleSink(source.audio);
  let cursor = clipStart;
  for await (const sample of sink.samples(clip.startSeconds, clip.endSeconds)) {
    const sampleEnd = sample.timestamp + sample.duration;
    const from = Math.max(0, Math.round((clip.startSeconds - sample.timestamp) * sample.sampleRate));
    const to = sample.numberOfFrames - Math.max(0, Math.round((sampleEnd - clip.endSeconds) * sample.sampleRate));
    if (to <= from) { sample.close(); continue; }
    const trimmed = from === 0 && to === sample.numberOfFrames ? sample : sample.trim(from, to);
    if (trimmed !== sample) sample.close();
    const retimed = rate === 1 ? trimmed : varispeed(trimmed, rate);
    if (retimed !== trimmed) trimmed.close();
    const timestamp = clipStart + (Math.max(clip.startSeconds, sample.timestamp) - clip.startSeconds) / rate;
    retimed.setTimestamp(Math.max(cursor, timestamp));
    cursor = retimed.timestamp + retimed.duration;
    yield retimed;
  }
  if (cursor < clipEnd - 0.005) yield* silence(cursor, clipEnd);
}

function* silence(from: number, to: number): Generator<AudioSample> {
  const total = Math.round((to - from) * AUDIO_SAMPLE_RATE);
  for (let offset = 0; offset < total; offset += SILENCE_FRAMES) {
    const frames = Math.min(SILENCE_FRAMES, total - offset);
    yield new AudioSample({ data: new Float32Array(frames * AUDIO_CHANNELS), format: "f32", numberOfChannels: AUDIO_CHANNELS, sampleRate: AUDIO_SAMPLE_RATE, timestamp: from + offset / AUDIO_SAMPLE_RATE });
  }
}

/** Speed change by linear-interpolation resampling at the original sample rate: duration /= rate, pitch *= rate. */
function varispeed(sample: AudioSample, rate: number): AudioSample {
  const channels = sample.numberOfChannels;
  const input = new Float32Array(sample.allocationSize({ planeIndex: 0, format: "f32" }) / 4);
  sample.copyTo(input, { planeIndex: 0, format: "f32" });
  const inFrames = sample.numberOfFrames;
  const outFrames = Math.max(1, Math.floor(inFrames / rate));
  const output = new Float32Array(outFrames * channels);
  for (let i = 0; i < outFrames; i++) {
    const position = i * rate;
    const index = Math.min(inFrames - 1, Math.floor(position));
    const next = Math.min(inFrames - 1, index + 1);
    const t = position - index;
    for (let c = 0; c < channels; c++) output[i * channels + c] = (input[index * channels + c] ?? 0) * (1 - t) + (input[next * channels + c] ?? 0) * t;
  }
  return new AudioSample({ data: output, format: "f32", numberOfChannels: channels, sampleRate: sample.sampleRate, timestamp: sample.timestamp });
}

/* ---------- encoding & output ---------- */

async function pickVideoCodec(width: number, height: number, frameRate: number): Promise<VideoCodec> {
  const bitrate = videoBitrate(width, height, frameRate);
  const codec = (await getFirstEncodableVideoCodec(["avc"], { width, height, bitrate, frameRate })) ?? (await getFirstEncodableVideoCodec(["vp9"], { width, height, bitrate, frameRate }));
  if (!codec) throw new UnsupportedExportError(`This browser cannot encode ${width}×${height} video (H.264 and VP9 are both unavailable).`);
  return codec;
}

async function pickAudioCodec(container: "mp4" | "webm"): Promise<AudioCodec | null> {
  const candidates: AudioCodec[] = container === "mp4" ? ["aac", "opus"] : ["opus"];
  return getFirstEncodableAudioCodec(candidates, { numberOfChannels: AUDIO_CHANNELS, sampleRate: AUDIO_SAMPLE_RATE, bitrate: 160_000 });
}

/** ≈0.12 bits per pixel per frame (7.5 Mbps at 1080p30, 15 Mbps at 1080p60), capped at 50 Mbps. */
export function videoBitrate(width: number, height: number, fps: number): number {
  return Math.min(50_000_000, Math.max(1_000_000, Math.round(width * height * fps * 0.12)));
}

/** OPFS streams accept positioned writes, so a regular MP4/WebM can be written with the index patched in place.
 *  Other stores only append, which needs fragmented MP4 / append-only WebM. */
async function openTarget(store: MediaStore, key: string): Promise<{ target: Target; randomAccess: boolean }> {
  const writable = await store.createWritable("Exports", key);
  const fileStream = typeof FileSystemWritableFileStream !== "undefined" && writable instanceof FileSystemWritableFileStream ? writable : null;
  if (!fileStream) return { target: new AppendOnlyStreamTarget(writable), randomAccess: false };
  const positioned = new WritableStream<StreamTargetChunk>({
    write: (chunk) => fileStream.write({ type: "write", position: chunk.position, data: chunk.data }),
    close: () => fileStream.close(),
    abort: (reason) => fileStream.abort(reason),
  });
  return { target: new StreamTarget(positioned, { chunked: true }), randomAccess: true };
}
