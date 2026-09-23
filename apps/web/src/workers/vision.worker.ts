/* OWNER: vision agent. Runs every heavy vision job off the main thread: selected-player tracking, the shared roster
   pass, the clip camera pass, field detection/snapping and marking detection. Frames come from `@/media/frame-source`
   (WebCodecs); the Rust kernels load once and the MediaPipe models load lazily on first use. */
import type { CompositionClip } from "@/domain/records";
import type { PlayerMotion } from "@/domain/tracking";
import { openFrameSource, type FrameSource } from "@/media/frame-source";
import { loadVisionKernels, visionKernels } from "@/wasm/camelot-vision";
import { trackCameraMotion, type CameraFrameInput } from "@/features/analysis/tracking/camera-registration";
import { loadVisionModels, visionCapabilities } from "@/features/analysis/tracking/detector";
import { framePixels, type FramePixels } from "@/features/analysis/tracking/frame-pixels";
import { runRosterTracking } from "@/features/analysis/tracking/roster";
import { runBackwardTracking, runSelectedTracking } from "@/features/analysis/tracking/selected-tracker";
import { detectFieldLines, proposeReference } from "@/features/analysis/field/line-detection";
import { detectFieldProposals, findReferenceFrame } from "@/features/analysis/field/region-detection";
import { MarkingEvidence, qualityGrade, reprojectLines, snapCalibration } from "@/features/analysis/field/registration";
import { serveJobs } from "./host";

const TRACKING_EDGE = 1280;
const CAMERA_EDGE = 640;
const FIELD_EDGE = 1920;

const kernelsReady = loadVisionKernels();
const canvas = new OffscreenCanvas(2, 2);

async function withSource<T>(fileKey: string, work: (source: FrameSource) => Promise<T>): Promise<T> {
  const source = await openFrameSource(fileKey);
  try { return await work(source); } finally { source.close(); }
}

/** Decoded frames as RGBA at most `edge` pixels wide, closing every VideoFrame after conversion. */
async function* pixelFrames(source: FrameSource, start: number, end: number, edge: number, signal: AbortSignal): AsyncGenerator<FramePixels> {
  for await (const { time, frame } of source.frames(start, end, undefined, signal)) {
    try { yield await framePixels(frame, time, edge, canvas); } finally { frame.close(); }
  }
}

async function frameAt(source: FrameSource, time: number, edge: number): Promise<FramePixels | null> {
  const frame = await source.frameAt(time);
  if (!frame) return null;
  try { return await framePixels(frame, time, edge, canvas); } finally { frame.close(); }
}

/** Backward tracking decodes half-second chunks and replays them newest first. */
async function* reversedFrames(source: FrameSource, start: number, end: number, edge: number, signal: AbortSignal): AsyncGenerator<FramePixels> {
  const chunk = 0.5;
  let chunkEnd = start;
  while (chunkEnd > end + 0.0005) {
    const chunkStart = Math.max(end, chunkEnd - chunk);
    const frames: FramePixels[] = [];
    for await (const { time, frame } of source.frames(chunkStart, chunkEnd, undefined, signal)) {
      try { if (time < start - 0.0005) frames.push(await framePixels(frame, time, edge, canvas)); } finally { frame.close(); }
    }
    for (let i = frames.length - 1; i >= 0; i--) yield frames[i]!;
    chunkEnd = chunkStart;
  }
}

serveJobs({
  async "vision.capabilities"() {
    await kernelsReady;
    return { ...visionCapabilities(), wasm: visionKernels() != null };
  },

  async "vision.trackPlayer"(input, { signal, progress }) {
    await kernelsReady;
    const models = await loadVisionModels();
    return withSource(input.fileKey, async (source) => {
      const report = (fraction: number) => progress({ fraction, time: input.start + (input.end - input.start) * fraction });
      const options = { seed: input.seed, start: input.start, end: input.end, prior: input.prior ?? null, models, signal, progress: report };
      if (input.direction === "backward") return runBackwardTracking(reversedFrames(source, input.start, input.end, TRACKING_EDGE, signal), options);
      const end = Math.min(source.duration, input.end);
      return runSelectedTracking(pixelFrames(source, input.start, end, TRACKING_EDGE, signal), { ...options, end, allowRecovery: input.allowRecovery ?? true });
    });
  },

  async "vision.trackRoster"(input, { signal, progress }) {
    await kernelsReady;
    const models = await loadVisionModels();
    if (!models.detectorAvailable) throw new Error("Player detection is unavailable in this browser, so Track all cannot run.");
    return withSource(input.fileKey, async (source) => {
      const end = Math.min(source.duration, input.end);
      const result = await runRosterTracking(pixelFrames(source, input.start, end, TRACKING_EDGE, signal), {
        start: input.start, end, priors: input.priors, camera: input.camera ?? null, models, signal,
        progress: (fraction) => progress({ fraction, time: input.start + (end - input.start) * fraction }),
      });
      return { ...result, detectorAvailable: models.detectorAvailable };
    });
  },

  async "vision.cameraMotion"(input, { signal, progress }) {
    await kernelsReady;
    return withSource(input.fileKey, async (source) => {
      const end = Math.min(source.duration, input.end);
      const frameDuration = source.frameRate > 0 ? 1 / source.frameRate : 1 / 30;
      const frames = (async function* (): AsyncGenerator<CameraFrameInput> {
        let pending: { pixels: FramePixels; time: number } | null = null;
        for await (const { time, frame } of source.frames(input.start, end, undefined, signal)) {
          let pixels: FramePixels;
          try { pixels = await framePixels(frame, time, CAMERA_EDGE, canvas); } finally { frame.close(); }
          if (pending) yield { pixels: pending.pixels, time: pending.time, duration: time - pending.time, isLast: false };
          pending = { pixels, time };
        }
        if (pending) yield { pixels: pending.pixels, time: pending.time, duration: frameDuration, isLast: true };
      })();
      return trackCameraMotion(frames, input.start, end, frameDuration, (fraction) => progress({ fraction }), signal);
    });
  },

  async "vision.detectField"(input, { signal, progress }) {
    await kernelsReady;
    return withSource(input.fileKey, async (source) => {
      progress({ stage: "detecting" });
      const frame = await frameAt(source, input.time, FIELD_EDGE);
      if (!frame) throw new Error("Could not decode this frame.");
      const proposals = detectFieldProposals(frame, input.pitchLength, input.pitchWidth, source.width, source.height);
      const first = proposals[0];
      if (first?.registration && qualityGrade(first.registration.quality) !== "poor") return { time: input.time, proposals, imageWidth: source.width, imageHeight: source.height };
      if (input.searchRange && input.searchRange[1] > input.searchRange[0]) {
        progress({ stage: "searching" });
        const found = await findReferenceFrame((time) => frameAt(source, time, FIELD_EDGE), input.searchRange, input.time, input.pitchLength, input.pitchWidth, source.width, source.height, signal);
        if (found) return { time: found.time, proposals: [found.proposal], imageWidth: source.width, imageHeight: source.height };
      }
      return { time: input.time, proposals, imageWidth: source.width, imageHeight: source.height };
    });
  },

  async "vision.snapField"(input) {
    await kernelsReady;
    return withSource(input.fileKey, async (source) => {
      const frame = await frameAt(source, input.time, FIELD_EDGE);
      const evidence = frame ? MarkingEvidence.fromFrame(frame, source.width, source.height) : null;
      if (!evidence) throw new Error("Could not read this frame's markings.");
      const result = snapCalibration(input.calibration, evidence);
      if (!result) return { result: null, lines: null };
      const lines = input.lines?.length ? reprojectLines(input.lines, result.calibration, input.pitchLength, input.pitchWidth) : null;
      return { result, lines };
    });
  },

  async "vision.detectLines"(input) {
    await kernelsReady;
    return withSource(input.fileKey, async (source) => {
      const frame = await frameAt(source, input.time, FIELD_EDGE);
      if (!frame) throw new Error("Could not decode this frame.");
      const segments = detectFieldLines(frame);
      return { intersections: proposeReference(segments).intersections, segments: segments.map((s) => ({ start: s.start, end: s.end })) };
    });
  },
});

export type { CompositionClip, PlayerMotion };
