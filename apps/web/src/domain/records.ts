import type { ISODate, UUID } from "./ids";
import type { AnalysisAnnotation } from "./annotation";
import type { AnalysisTrackingLibrary } from "./tracking";
import type { GroundCalibration } from "./ground";

/* Port of clients/ios/Camelot/Models.swift. Sync bookkeeping fields (serverVersion,
   needsSync, mutationID) are kept so the future sync engine can reuse the iOS contract. */

export interface SyncMeta {
  serverVersion: number | null;
  needsSync: boolean;
  mutationID: UUID;
}

export interface Project extends SyncMeta {
  id: UUID;
  name: string;
  opponent: string;
  scheduledAt: ISODate;
  createdAt: ISODate;
}

export interface MatchEvent extends SyncMeta {
  id: UUID;
  projectID: UUID;
  kind: string;
  note: string;
  occurredAt: ISODate;
  recordingID: UUID | null;
  /** Seconds into the recording where the event happened. */
  offsetSeconds: number;
  preRollSeconds: number;
  postRollSeconds: number;
  /** 6-digit hex without '#', or "" for the kind default. */
  colorHex: string;
  /** Preceding rolling-buffer segments that hold this event's pre-roll. */
  contextRecordingIDs: UUID[];
  pendingDeletion: boolean;
}

export type UploadState = "local" | "uploading" | "uploaded" | "failed";
export type RecordingEndedReason = "user" | "interruption" | "background" | "crash" | "import" | "rolling";

export interface Recording extends SyncMeta {
  id: UUID;
  projectID: UUID;
  /** Key of the video blob in the media store. Empty when the file is missing. */
  localPath: string;
  name: string;
  createdAt: ISODate;
  duration: number;
  uploadState: UploadState;
  uploadedBytes: number;
  shareURL: string | null;
  pendingDeletion: boolean;
  segmentIndex: number;
  endedReason: RecordingEndedReason;
  recordedAt: ISODate;
  timezoneIdentifier: string;
  utcOffsetSeconds: number;
  /** Web-only: pixel size and MIME type discovered at import/capture time. */
  width?: number;
  height?: number;
  mimeType?: string;
}

export type CompositionKind = "full" | "goals" | "custom" | "clip" | "event";
export type AspectRatio = "original" | "16:9" | "9:16" | "1:1" | "4:5";

export interface VideoComposition extends SyncMeta {
  id: UUID;
  projectID: UUID;
  name: string;
  kind: CompositionKind | string;
  createdAt: ISODate;
  clips: CompositionClip[];
  aspectRatio: AspectRatio | string;
  uploadState: UploadState;
  uploadedBytes: number;
  shareURL: string | null;
  pendingDeletion: boolean;
}

/** Edits are manifests: an ordered list of immutable recording IDs and time ranges. */
export interface CompositionClip {
  id: UUID;
  recordingID: UUID;
  startSeconds: number;
  endSeconds: number;
  rate: number;
  annotations: AnalysisAnnotation[];
  /** When set the clip holds its start frame for this many seconds (freeze frame). */
  freezeDuration?: number;
  trackingLibrary?: AnalysisTrackingLibrary;
  groundCalibration?: GroundCalibration;
}

export const clampRate = (rate: number) => Math.max(0.25, Math.min(4, rate));
export const clipPlaybackDuration = (clip: CompositionClip) => clip.freezeDuration ?? Math.max(0, clip.endSeconds - clip.startSeconds) / clampRate(clip.rate);
export const clipAnnotationRate = (clip: CompositionClip) => (clip.freezeDuration == null ? clampRate(clip.rate) : 1);
export const clipAnnotationEnd = (clip: CompositionClip) => clip.startSeconds + clipPlaybackDuration(clip) * clipAnnotationRate(clip);
export const compositionDuration = (clips: readonly CompositionClip[]) => clips.reduce((total, clip) => total + clipPlaybackDuration(clip), 0);

/** Stable hash of the render-affecting manifest, used to name exports and skip re-renders. */
export async function renderRevision(composition: Pick<VideoComposition, "clips" | "aspectRatio">): Promise<string> {
  const manifest = JSON.stringify(composition.clips, Object.keys(flattenKeys(composition.clips)).sort()) + composition.aspectRatio;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(manifest));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function flattenKeys(value: unknown, keys: Record<string, true> = {}): Record<string, true> {
  if (Array.isArray(value)) value.forEach((v) => flattenKeys(v, keys));
  else if (value && typeof value === "object") for (const [k, v] of Object.entries(value)) { keys[k] = true; flattenKeys(v, keys); }
  return keys;
}
