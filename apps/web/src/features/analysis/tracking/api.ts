/* Main-thread entry points for the vision worker. Every call returns a `TrackingJob<T>`: a Promise of the worker
   output that also exposes `cancel()`. Passing `options.signal` (an AbortSignal) cancels the same way; either path
   rejects the promise with an AbortError. The clip's recording supplies the media file; pass `fileKey` explicitly
   when the recording is not in the repository yet. */
import type { Point, Rect } from "@/domain/geometry";
import type { GroundCalibration, GroundLineObservation } from "@/domain/ground";
import type { CompositionClip } from "@/domain/records";
import type { AnnotationCameraMotion, PlayerMotion, TimeRange } from "@/domain/tracking";
import { recordings } from "@/storage/repository";
import { WorkerClient, type JobHandle } from "@/workers/client";
import type { DetectFieldOutput, SnapFieldOutput, TrackRosterOutput, WorkerJobs } from "@/workers/protocol";
import { cameraTrackingRange, mergeRoster, sharedCamera } from "./library";
import type { RosterPrior } from "./roster";

export type TrackingJob<T> = Promise<T> & { cancel(): void };
export type ProgressHandler = (fraction: number, time?: number) => void;

export interface JobOptions {
  /** Aborting cancels the worker job; the promise rejects with an AbortError. */
  signal?: AbortSignal;
  /** Media-store key of the recording, when it should not be looked up in the repository. */
  fileKey?: string;
}

let client: WorkerClient | null = null;
function worker(): WorkerClient {
  client ??= new WorkerClient(new Worker(new URL("../../../workers/vision.worker.ts", import.meta.url), { type: "module" }));
  return client;
}

/** Resolves the media-store key of the clip's recording. */
export async function clipFileKey(clip: Pick<CompositionClip, "recordingID">, fileKey?: string): Promise<string> {
  if (fileKey) return fileKey;
  const recording = await recordings.get(clip.recordingID);
  if (!recording?.localPath) throw new Error("The recording's video file is not available on this device.");
  return recording.localPath;
}

const abortError = () => new DOMException("Cancelled", "AbortError");

function job<K extends keyof WorkerJobs>(name: K, input: () => Promise<WorkerJobs[K]["input"]>, onProgress?: (p: WorkerJobs[K]["progress"]) => void, signal?: AbortSignal): TrackingJob<WorkerJobs[K]["output"]> {
  let handle: JobHandle<K> | null = null, cancelled = false;
  const cancel = () => { cancelled = true; handle?.cancel(); };
  signal?.addEventListener("abort", cancel, { once: true });
  const promise = (async () => {
    if (signal?.aborted || cancelled) throw abortError();
    const resolved = await input();
    if (signal?.aborted || cancelled) throw abortError();
    handle = worker().run(name, resolved, onProgress);
    try { return await handle.result; } finally { signal?.removeEventListener("abort", cancel); }
  })();
  return Object.assign(promise, { cancel });
}

function mapJob<T, U>(inner: TrackingJob<T>, map: (value: T) => U): TrackingJob<U> {
  return Object.assign(inner.then(map), { cancel: inner.cancel });
}

export interface TrackSelectedOptions extends JobOptions { end?: number; allowRecovery?: boolean; prior?: PlayerMotion | null }

/** Follows the player inside `box` from `time` to the clip end (or `options.end`). */
export function trackSelectedPlayer(clip: CompositionClip, box: Rect, time: number, onProgress?: ProgressHandler, options: TrackSelectedOptions = {}): TrackingJob<PlayerMotion> {
  return job("vision.trackPlayer", async () => ({
    fileKey: await clipFileKey(clip, options.fileKey), seed: box, start: time, end: options.end ?? clip.endSeconds, direction: "forward",
    allowRecovery: options.allowRecovery ?? true, prior: options.prior ?? null,
  }), (p) => onProgress?.(p.fraction, p.time), options.signal);
}

/** Follows the player backwards from `time` down to `end` (default: the clip start) and returns the earlier section. */
export function trackPlayerBackward(clip: CompositionClip, box: Rect, time: number, onProgress?: ProgressHandler, options: TrackSelectedOptions = {}): TrackingJob<PlayerMotion> {
  return job("vision.trackPlayer", async () => ({
    fileKey: await clipFileKey(clip, options.fileKey), seed: box, start: time, end: options.end ?? clip.startSeconds, direction: "backward", prior: options.prior ?? null,
  }), (p) => onProgress?.(p.fraction, p.time), options.signal);
}

/** Re-tracks a saved player from `time` inside its own track; splice the result with `continuing(saved, result, time)`. */
export function repairTrack(clip: CompositionClip, saved: PlayerMotion, box: Rect, time: number, onProgress?: ProgressHandler, options: Omit<TrackSelectedOptions, "prior"> = {}): TrackingJob<PlayerMotion> {
  return trackSelectedPlayer(clip, box, time, onProgress, { ...options, prior: saved });
}

export interface TrackRosterOptions extends JobOptions { start?: number; end?: number; camera?: AnnotationCameraMotion | null }
export interface RosterOutcome { clip: CompositionClip; tracked: number; added: number; raw: TrackRosterOutput }

/** One shared pass over the clip for every saved player plus newly discovered bodies, merged into the clip's library. */
export function trackRoster(clip: CompositionClip, onProgress?: ProgressHandler, options: TrackRosterOptions = {}): TrackingJob<RosterOutcome> {
  const library = clip.trackingLibrary;
  const priors: RosterPrior[] = (library?.players ?? []).map((p) => ({ id: p.id, motion: p.motion, memory: p.identity ?? null }));
  const inner = job("vision.trackRoster", async () => ({
    fileKey: await clipFileKey(clip, options.fileKey), start: options.start ?? clip.startSeconds, end: options.end ?? clip.endSeconds, priors,
    camera: options.camera === undefined ? sharedCamera(library) : options.camera,
  }), (p) => onProgress?.(p.fraction, p.time), options.signal);
  return mapJob(inner, (raw) => ({ ...mergeRoster(clip, raw.entries), raw }));
}

/** The clip camera pass over `range` (default: `cameraTrackingRange(clip)`). Store it with `storeSharedCameraTrack`. */
export function trackCamera(clip: CompositionClip, range?: TimeRange | { start: number; end: number } | null, onProgress?: ProgressHandler, options: JobOptions = {}): TrackingJob<AnnotationCameraMotion> {
  const [start, end] = range == null ? cameraTrackingRange(clip) : Array.isArray(range) ? range : [range.start, range.end];
  return job("vision.cameraMotion", async () => ({ fileKey: await clipFileKey(clip, options.fileKey), start, end }), (p) => onProgress?.(p.fraction), options.signal);
}

export type DetectFieldStage = "detecting" | "searching" | "snapping";

/** Field proposals on a frame, optionally searching the clip for a clearer frame. */
export function detectField(clip: CompositionClip, time: number, pitchLength: number, pitchWidth: number, searchRange?: TimeRange | null, onStage?: (stage: DetectFieldStage) => void, options: JobOptions = {}): TrackingJob<DetectFieldOutput> {
  return job("vision.detectField", async () => ({ fileKey: await clipFileKey(clip, options.fileKey), time, pitchLength, pitchWidth, searchRange: searchRange ?? null }), (p) => onStage?.(p.stage), options.signal);
}

/** Snaps a plane calibration to the painted markings of the frame at `time`. */
export function snapField(clip: CompositionClip, time: number, calibration: GroundCalibration, pitchLength: number, pitchWidth: number, lines?: GroundLineObservation[] | null, options: JobOptions = {}): TrackingJob<SnapFieldOutput> {
  return job("vision.snapField", async () => ({ fileKey: await clipFileKey(clip, options.fileKey), time, calibration, lines: lines ?? null, pitchLength, pitchWidth }), undefined, options.signal);
}

/** Possible marking intersections on a frame (cyan dots in the field sheet). */
export function detectLineIntersections(clip: CompositionClip, time: number, options: JobOptions = {}): TrackingJob<{ intersections: Point[]; segments: { start: Point; end: Point }[] }> {
  return job("vision.detectLines", async () => ({ fileKey: await clipFileKey(clip, options.fileKey), time }), undefined, options.signal);
}

export function visionWorkerCapabilities(): TrackingJob<WorkerJobs["vision.capabilities"]["output"]> {
  return job("vision.capabilities", async () => ({}));
}
