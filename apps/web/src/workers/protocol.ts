import type { ExportArtifact, ExportProgress, ExportRequest } from "@/features/export/render";
import type { Point, Rect } from "@/domain/geometry";
import type { GroundCalibration, GroundLineObservation } from "@/domain/ground";
import type { AnnotationCameraMotion, PlayerMotion, TimeRange } from "@/domain/tracking";
import type { RosterEntry, RosterPrior } from "@/features/analysis/tracking/roster";
import type { FieldProposal } from "@/features/analysis/field/region-detection";
import type { SnapResult } from "@/features/analysis/field/registration";
import type { VisionCapabilities } from "@/features/analysis/tracking/detector";

export interface TrackPlayerInput {
  fileKey: string;
  /** Box the user drew, fractions of the display frame. */
  seed: Rect;
  start: number;
  end: number;
  /** "backward" follows the player from `start` down to `end` (end < start). */
  direction?: "forward" | "backward";
  allowRecovery?: boolean;
  /** Saved track being repaired or extended; identity memory and correction boundaries come from it. */
  prior?: PlayerMotion | null;
}
export interface TrackRosterInput { fileKey: string; start: number; end: number; priors: RosterPrior[]; camera?: AnnotationCameraMotion | null }
export interface TrackRosterOutput { entries: RosterEntry[]; detectionFrames: number; elapsed: number; detectorAvailable: boolean }
export interface CameraMotionInput { fileKey: string; start: number; end: number }
export interface DetectFieldInput {
  fileKey: string;
  time: number;
  pitchLength: number;
  pitchWidth: number;
  /** When set, a clip-wide search for a clearer frame runs if the chosen frame does not snap well. */
  searchRange?: TimeRange | null;
}
export interface DetectFieldOutput { time: number; proposals: FieldProposal[]; imageWidth: number; imageHeight: number }
export interface SnapFieldInput {
  fileKey: string;
  time: number;
  calibration: GroundCalibration;
  /** Traced lines to reproject onto the snapped template (lines method). */
  lines?: GroundLineObservation[] | null;
  pitchLength: number;
  pitchWidth: number;
}
export interface SnapFieldOutput { result: SnapResult | null; lines: GroundLineObservation[] | null }

/* Typed request/response protocol for Web Workers. Heavy work (decoding, tracking, field
   detection, export encoding) runs off the main thread; WASM (crates/camelot-vision) is loaded
   inside the worker. Add a new job by extending `WorkerJobs` — the client and worker stay typed. */

export interface WorkerJobs {
  /* OWNER: vision agent. Frames are decoded inside the worker from `fileKey` (media store "Recordings").
     Coordinates are fractions of the display frame; times are source seconds. */
  "vision.trackPlayer": { input: TrackPlayerInput; output: PlayerMotion; progress: { fraction: number; time: number } };
  "vision.trackRoster": { input: TrackRosterInput; output: TrackRosterOutput; progress: { fraction: number; time: number } };
  "vision.cameraMotion": { input: CameraMotionInput; output: AnnotationCameraMotion; progress: { fraction: number } };
  "vision.detectField": { input: DetectFieldInput; output: DetectFieldOutput; progress: { stage: "detecting" | "searching" | "snapping" } };
  "vision.snapField": { input: SnapFieldInput; output: SnapFieldOutput; progress: never };
  "vision.detectLines": { input: { fileKey: string; time: number }; output: { intersections: Point[]; segments: { start: Point; end: Point }[] }; progress: never };
  "vision.capabilities": { input: Record<string, never>; output: VisionCapabilities & { wasm: boolean }; progress: never };
  /* OWNER: export agent */
  "export.render": { input: ExportRequest; output: ExportArtifact; progress: ExportProgress };
  /* OWNER: storage/media agent. `jpeg` is null when a frame could not be decoded. Thumbnails are also
     persisted in the media store ("Thumbnails" folder, `${recordingID}-${ms}-${height}.jpg`). */
  "media.thumbnails": {
    input: { recordingID: string; fileKey: string; times: number[]; height: number };
    output: { time: number; jpeg: Blob | null }[];
    progress: { done: number; total: number };
  };
  "media.probe": {
    input: { fileKey: string };
    output: { duration: number; width: number; height: number; rotation: number; mimeType: string; codec: string | null; frameRate: number | null; hasAudio: boolean };
    progress: never;
  };
}

export type JobName = keyof WorkerJobs;

export type WorkerRequest<K extends JobName = JobName> = { id: number; job: K; input: WorkerJobs[K]["input"] } | { id: number; cancel: true };

export type WorkerResponse<K extends JobName = JobName> =
  | { id: number; kind: "progress"; progress: WorkerJobs[K]["progress"] }
  | { id: number; kind: "result"; output: WorkerJobs[K]["output"] }
  | { id: number; kind: "error"; message: string };
