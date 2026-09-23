/* Port of the persisted field types from GroundCalibration.swift, GroundLandmark.swift, GroundFieldOverlay.swift,
   GroundLineAlignment.swift, GroundCircleReference.swift and AnalysisFieldGuide.swift. Plain JSON data only;
   field names match the Swift `Codable` keys. Geometry lives in src/features/analysis/field/. */
import type { Point } from "./geometry";
import type { AnnotationCameraMotion } from "./tracking";

export type GroundCalibrationMode = "localScale" | "plane";

/** Common full-size football pitch references (IFAB Law 1). Dimensions stay editable in the sheet. */
export type GroundLandmark = "custom" | "penaltyArea" | "goalArea" | "centreCircle" | "goalWidth" | "halfPitch" | "fullPitch";
export const GROUND_LANDMARKS: readonly GroundLandmark[] = ["custom", "penaltyArea", "goalArea", "centreCircle", "goalWidth", "halfPitch", "fullPitch"];

export interface GroundLandmarkInfo {
  title: string;
  mode: GroundCalibrationMode;
  pointCount: number;
  /** Side 1–2 in the sheet (parallel to the goal line). */
  defaultLengthMeters: number;
  /** Side 2–3 in the sheet (depth away from the goal line). */
  defaultWidthMeters: number;
  isApproximate: boolean;
  guidance: string;
}

const landmarkInfo = (title: string, mode: GroundCalibrationMode, defaultLengthMeters: number, defaultWidthMeters: number, guidance: string): GroundLandmarkInfo =>
  ({ title, mode, pointCount: mode === "plane" ? 4 : 2, defaultLengthMeters, defaultWidthMeters, isApproximate: mode === "localScale", guidance });

export const GROUND_LANDMARK_INFO: Record<GroundLandmark, GroundLandmarkInfo> = {
  custom: landmarkInfo("Custom", "localScale", 0, 0, "Choose two points for a known distance, or four corners of a real ground rectangle."),
  penaltyArea: landmarkInfo("Penalty area", "plane", 7.32 + 2 * 16.5, 16.5, "Points 1–2: the two corners on the goal line (40.32 m). Continue clockwise to corners 3–4 out on the field (16.5 m deep). Full-size football defaults; edit for your pitch."),
  goalArea: landmarkInfo("Goal area", "plane", 7.32 + 2 * 5.5, 5.5, "Points 1–2: the two corners on the goal line (18.32 m). Continue clockwise to corners 3–4 out on the field (5.5 m deep). Full-size football defaults; edit for your pitch."),
  centreCircle: landmarkInfo("Centre circle", "plane", 2 * 9.15, 18.3, "Match both halfway-line intersections and the two ends of the perpendicular diameter. Do not use the ellipse's screen-space extremes."),
  goalWidth: landmarkInfo("Goal width", "localScale", 7.32, 0, "Two inside edges of the goalposts on the ground. Approximate local scale; this does not model the vertical goal face."),
  halfPitch: landmarkInfo("Half pitch", "plane", 68, 52.5, "Match the two goal-line corners and the two halfway-line corners."),
  fullPitch: landmarkInfo("Whole pitch", "plane", 68, 105, "Match the four outside pitch corners. Confirm the pitch dimensions."),
};

/** The semantic reference survives reopening, separately from metric corner data. */
export interface GroundFieldReference {
  landmark: GroundLandmark;
  pitchLength: number;
  pitchWidth: number;
}
export const groundFieldReference = (landmark: GroundLandmark, pitchLength = 105, pitchWidth = 68): GroundFieldReference => ({ landmark, pitchLength, pitchWidth });

/** Named pitch lines are constraints, not guessed corner correspondences. */
export type GroundPitchLine =
  | "farTouch" | "nearTouch" | "halfway" | "leftGoal" | "rightGoal"
  | "leftBoxFront" | "leftBoxFar" | "leftBoxNear" | "rightBoxFront" | "rightBoxFar" | "rightBoxNear"
  | "leftSmallFront" | "leftSmallFar" | "leftSmallNear" | "rightSmallFront" | "rightSmallFar" | "rightSmallNear";
export const GROUND_PITCH_LINES: readonly GroundPitchLine[] = [
  "farTouch", "nearTouch", "halfway", "leftGoal", "rightGoal",
  "leftBoxFront", "leftBoxFar", "leftBoxNear", "rightBoxFront", "rightBoxFar", "rightBoxNear",
  "leftSmallFront", "leftSmallFar", "leftSmallNear", "rightSmallFront", "rightSmallFar", "rightSmallNear",
];
export const GROUND_PITCH_LINE_TITLES: Record<GroundPitchLine, string> = {
  farTouch: "Far touchline", nearTouch: "Near touchline", halfway: "Halfway line", leftGoal: "Left goal line", rightGoal: "Right goal line",
  leftBoxFront: "Left penalty area · front", leftBoxFar: "Left penalty area · far side", leftBoxNear: "Left penalty area · near side",
  rightBoxFront: "Right penalty area · front", rightBoxFar: "Right penalty area · far side", rightBoxNear: "Right penalty area · near side",
  leftSmallFront: "Left goal area · front", leftSmallFar: "Left goal area · far side", leftSmallNear: "Left goal area · near side",
  rightSmallFront: "Right goal area · front", rightSmallFar: "Right goal area · far side", rightSmallNear: "Right goal area · near side",
};
/** Lines running across the pitch (constant world Y); the others run along it (constant world X). */
export const pitchLineIsAcross = (line: GroundPitchLine) =>
  (["halfway", "leftGoal", "rightGoal", "leftBoxFront", "rightBoxFront", "leftSmallFront", "rightSmallFront"] as GroundPitchLine[]).includes(line);
/** Normalized pitch coordinate of the line for a pitch of `length` × `width` metres. */
export function pitchLineCoordinate(line: GroundPitchLine, length: number, width: number): number {
  switch (line) {
    case "farTouch": case "leftGoal": return 0;
    case "nearTouch": case "rightGoal": return 1;
    case "halfway": return 0.5;
    case "leftBoxFront": return 16.5 / length;
    case "rightBoxFront": return 1 - 16.5 / length;
    case "leftSmallFront": return 5.5 / length;
    case "rightSmallFront": return 1 - 5.5 / length;
    case "leftBoxFar": case "rightBoxFar": return (width - 40.32) / (2 * width);
    case "leftBoxNear": case "rightBoxNear": return (width + 40.32) / (2 * width);
    case "leftSmallFar": case "rightSmallFar": return (width - 18.32) / (2 * width);
    case "leftSmallNear": case "rightSmallNear": return (width + 18.32) / (2 * width);
  }
}

export interface GroundLineObservation { kind: GroundPitchLine; points: Point[] }

/** An observed conic (symmetric 3×3, row major), the corrected centre spot and the halfway direction. */
export interface GroundCircleReference {
  conic: number[];
  center: Point;
  halfway: Point[];
  outlineErrorPixels: number;
  farTouchline?: Point[];
}

/** A small metric model for the image plane. Points are normalized top-left image coordinates. */
export interface GroundCalibration {
  mode: GroundCalibrationMode;
  points: Point[];
  lengthMeters: number;
  widthMeters: number;
  referenceTime: number;
  imageAspectRatio: number;
  fixedCamera: boolean;
  cameraMotion?: AnnotationCameraMotion;
  fieldReference?: GroundFieldReference;
  lineReferences?: GroundLineObservation[];
  circleReference?: GroundCircleReference;
}

/** Mirrors the Swift decoder defaults so old records decode safely. */
export function normalizeGroundCalibration(raw: Partial<GroundCalibration> | null | undefined): GroundCalibration {
  return {
    mode: raw?.mode ?? "localScale",
    points: raw?.points ?? [],
    lengthMeters: raw?.lengthMeters ?? 0,
    widthMeters: raw?.widthMeters ?? 0,
    referenceTime: raw?.referenceTime ?? 0,
    imageAspectRatio: raw?.imageAspectRatio ?? 1,
    fixedCamera: raw?.fixedCamera ?? false,
    cameraMotion: raw?.cameraMotion,
    fieldReference: raw?.fieldReference,
    lineReferences: raw?.lineReferences,
    circleReference: raw?.circleReference,
  };
}

export type AnalysisFieldRegion = "penaltyArea" | "halfPitch" | "fullPitch";
export const ANALYSIS_FIELD_REGIONS: readonly AnalysisFieldRegion[] = ["penaltyArea", "halfPitch", "fullPitch"];
export const ANALYSIS_FIELD_REGION_TITLES: Record<AnalysisFieldRegion, string> = { penaltyArea: "Penalty area", halfPitch: "Half pitch", fullPitch: "Whole pitch" };
export type AnalysisFieldGoalSide = "left" | "right";

/** The four handles describe the visible reference, not necessarily the pitch perimeter. */
export interface AnalysisFieldLayout { region: AnalysisFieldRegion; goalSide: AnalysisFieldGoalSide }
export const DEFAULT_FIELD_LAYOUT: AnalysisFieldLayout = { region: "penaltyArea", goalSide: "right" };
/** Undefined on an old annotation means the original whole-pitch guide. */
export const LEGACY_FIELD_LAYOUT: AnalysisFieldLayout = { region: "fullPitch", goalSide: "right" };
