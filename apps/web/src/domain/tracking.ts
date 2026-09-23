/* Port of the persisted tracking types from PlayerTrackingIdentity.swift, SelectedPlayerTracking.swift,
   AnnotationCameraMotion.swift, AnalysisTrackingLibrary.swift, PlayerTrajectory.swift, PlayerRoster.swift and
   PlayerAppearanceGallery.swift. Plain JSON data only; field names match the Swift `Codable` keys.
   Algorithms live in src/features/analysis/tracking/ (pure helpers) and src/workers/vision.worker.ts. */
import type { Rect } from "./geometry";
import type { UUID } from "./ids";
import type { AnnotationColor } from "./annotation";

/** Swift `ClosedRange<Double>` encodes as `[lowerBound, upperBound]`. */
export type TimeRange = [lowerBound: number, upperBound: number];

export interface PlayerMotionSample { time: number; box: Rect }

/** Compact torso colour histogram (15 hue/neutral bins, 25 chroma bins or 15 brightness bins). */
export interface PlayerJerseySignature { bins: number[] }

/** Identity anchor plus adaptive examples; confirmed once it holds two or more. */
export interface PlayerJerseyProfile { examples: PlayerJerseySignature[] }

/** Shirt-number reads; a number counts after repeated agreeing reads. */
export interface PlayerNumberVotes { counts: Record<string, number> }

/** Several learned body embeddings (rounded to three decimals) with their sample times. */
export interface PlayerAppearanceGallery { prints: number[][]; times: number[] }

/** Whole-clip memory of one player: kit, shorts, tones, number and embedding gallery. */
export interface PlayerIdentityMemory {
  jersey: PlayerJerseyProfile;
  shorts: PlayerJerseyProfile;
  number: PlayerNumberVotes;
  /** Mean torso colour `[r, g, b]` (0…1) of the first clear observation; swatch only. */
  kitColor?: number[];
  head?: PlayerJerseyProfile;
  legs?: PlayerJerseyProfile;
  chroma?: PlayerJerseyProfile;
  gallery?: PlayerAppearanceGallery;
}

/** Confirmed tracking samples in source seconds, boxes as fractions of the display frame. */
export interface PlayerMotion {
  samples: PlayerMotionSample[];
  /** Terminal loss time; positions at or after it are unknown. */
  lostAt?: number;
  /** Recorded intervals where the player was hidden; raw samples never span them. */
  gaps?: TimeRange[];
  recoveryCount?: number;
  /** Undefined enables the default gentle stabilisation (0.65); 0 turns it off. */
  smoothing?: number;
  trackID?: UUID;
  /** A drawing's bind pose, independent of the shared track's first sample. */
  referenceBox?: Rect;
  jerseyProfile?: PlayerJerseyProfile;
  /** Explicit picks: protected boundaries when repairing an earlier section. */
  correctionTimes?: number[];
  /** Display-only bridged positions inside gaps and briefly after a loss. */
  inferred?: PlayerMotionSample[];
  /** Times of hand placements inside missing intervals. */
  anchors?: number[];
  /** Longest missing interval an effect keeps following (seconds); undefined is the legacy 0.4 s bridge. */
  gapBridging?: number;
  /** Appearance memory of the last pass; source tracks only, drawings' copies drop it. */
  identity?: PlayerIdentityMemory;
}

export const DEFAULT_GAP_BRIDGING = 2;
export const MAXIMUM_RECOVERY_SECONDS = 2.5;

/** Row-major 3×3 projective transform in normalized top-left display coordinates. */
export interface CameraTransform { values: number[] }
export const IDENTITY_CAMERA_TRANSFORM: CameraTransform = { values: [1, 0, 0, 0, 1, 0, 0, 0, 1] };

export interface CameraMotionSample { time: number; transform: CameraTransform }

/** Camera compensation over a source-time range; not a metric camera pose. */
export interface AnnotationCameraMotion {
  samples: CameraMotionSample[];
  lostAt?: number;
  trackID?: UUID;
  /** When set, transforms are expressed relative to the pose at this time. */
  referenceTime?: number;
}

export interface PlayerTrajectoryStyle {
  pastSeconds: number;
  futureSeconds: number;
  futureColor: AnnotationColor;
}
export const DEFAULT_TRAJECTORY_STYLE: PlayerTrajectoryStyle = { pastSeconds: 3, futureSeconds: 3, futureColor: { red: 0.2, green: 0.8, blue: 1 } };

export interface AnalysisTrackingLibraryPlayer {
  id: UUID;
  name: string;
  motion: PlayerMotion;
  /** Undefined for tracks made by older passes. */
  identity?: PlayerIdentityMemory;
}

/** Clip-owned source-time tracks that survive deleting an effect. */
export interface AnalysisTrackingLibrary {
  players: AnalysisTrackingLibraryPlayer[];
  cameras: AnnotationCameraMotion[];
  /** Only this clip-wide camera track is offered for new camera-following effects. */
  sharedCameraID?: UUID;
}
export const emptyTrackingLibrary = (): AnalysisTrackingLibrary => ({ players: [], cameras: [] });
