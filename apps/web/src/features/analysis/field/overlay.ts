/* Shared field template geometry: port of GroundFieldOverlay.swift and AnalysisFieldPreviewGeometry
   (AnalysisFieldPreview.swift). World X runs across the pitch; Y runs away from the chosen goal line. */
import type { Point, Rect } from "@/domain/geometry";
import type { GroundCalibration, GroundFieldReference, GroundLandmark } from "@/domain/ground";
import { GROUND_LANDMARK_INFO } from "@/domain/ground";
import { cameraMatrix, cameraPoint, mat3Apply, mat3Inverse, mat3Multiply } from "../tracking/geometry";
import { calibrationIsValid, fieldProjection, frozenCalibration } from "./projection";

export const RECTANGLE: readonly Point[] = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];

export function referenceAnchors(landmark: GroundLandmark): Point[] {
  return landmark === "centreCircle" ? [{ x: 0.5, y: 0 }, { x: 1, y: 0.5 }, { x: 0.5, y: 1 }, { x: 0, y: 0.5 }] : RECTANGLE.slice();
}

/** Starting handle positions for a landmark. */
export function seedAnchors(landmark: GroundLandmark, goalOnRight = true): Point[] {
  const quad: Point[] = [{ x: 0.65, y: 0.34 }, { x: 0.88, y: 0.67 }, { x: 0.3, y: 0.9 }, { x: 0.2, y: 0.46 }];
  const transform = fieldProjection(quad)!;
  const plane = GROUND_LANDMARK_INFO[landmark].mode === "plane";
  const anchors = plane ? referenceAnchors(landmark) : [{ x: 0.3, y: 0.55 }, { x: 0.7, y: 0.55 }];
  return anchors.map((a) => { const point = plane ? cameraPoint(transform, a)! : a; return goalOnRight ? point : { x: 1 - point.x, y: point.y }; });
}

/** Plane corners implied by the editing anchors (identity except for the centre circle). Empty when degenerate. */
export function calibrationCorners(anchors: readonly Point[], landmark: GroundLandmark): Point[] {
  if (landmark !== "centreCircle") return anchors.slice();
  const target = fieldProjection(anchors), source = fieldProjection(referenceAnchors(landmark));
  if (!target || !source) return [];
  const inverse = mat3Inverse(cameraMatrix(source));
  if (!inverse) return [];
  const matrix = mat3Multiply(cameraMatrix(target), inverse);
  const center = mat3Apply(matrix, [0.5, 0.5, 1]);
  const corners: Point[] = [];
  for (const point of RECTANGLE) {
    const p = mat3Apply(matrix, [point.x, point.y, 1]);
    if (!(p[2] * center[2] > 0) || !(Math.abs(p[2]) > 0.00001)) return [];
    corners.push({ x: p[0] / p[2], y: p[1] / p[2] });
  }
  return corners.length === 4 && fieldProjection(corners) ? corners : [];
}

/** Editing anchors of a saved calibration (the circle's four extremes for the centre circle). */
export function editingAnchors(calibration: GroundCalibration, landmark: GroundLandmark): Point[] {
  const projection = landmark === "centreCircle" ? fieldProjection(calibration.points) : null;
  if (!projection) return calibration.points.slice();
  return referenceAnchors(landmark).flatMap((a) => { const p = cameraPoint(projection, a); return p ? [p] : []; });
}

export function handleNames(landmark: GroundLandmark, count: number): string[] {
  switch (landmark) {
    case "centreCircle": return ["Circle · goal side", "Halfway · near side", "Circle · opposite side", "Halfway · far side"];
    case "penaltyArea": case "goalArea": return ["Goal line · far corner", "Goal line · near corner", "Box · near corner", "Box · far corner"];
    case "halfPitch": return ["Goal line · far corner", "Goal line · near corner", "Halfway · near corner", "Halfway · far corner"];
    case "fullPitch": return ["Goal line · far corner", "Goal line · near corner", "Opposite goal · near", "Opposite goal · far"];
    case "goalWidth": return ["First post · ground", "Second post · ground"];
    case "custom": return Array.from({ length: count }, (_, i) => `Reference point ${i + 1}`);
  }
}

/** Ground paths in metres relative to the calibrated reference rectangle. */
export function worldLines(reference: GroundFieldReference, length: number, depth: number): Point[][] {
  if (!(length > 0) || !(depth > 0) || !Number.isFinite(length) || !Number.isFinite(depth)) return [];
  if (!Number.isFinite(reference.pitchLength) || !Number.isFinite(reference.pitchWidth) || !(reference.pitchLength > 33) || !(reference.pitchWidth > 40.32)) return [];
  const landmark = reference.landmark;
  if (GROUND_LANDMARK_INFO[landmark].mode !== "plane" || landmark === "custom") return [];
  const pitchWidth = landmark === "halfPitch" || landmark === "fullPitch" ? length : reference.pitchWidth;
  const pitchLength = landmark === "fullPitch" ? depth : landmark === "halfPitch" ? depth * 2 : reference.pitchLength;
  const centerX = length / 2;
  const goalY = landmark === "centreCircle" ? depth / 2 - pitchLength / 2 : 0;
  const left = centerX - pitchWidth / 2, right = centerX + pitchWidth / 2;
  const lines: Point[][] = [];
  const box = (x: number, y: number, w: number, h: number) => lines.push([{ x, y }, { x: x + w, y }, { x: x + w, y: y + h }, { x, y: y + h }, { x, y }]);
  box(left, goalY, pitchWidth, pitchLength);
  lines.push([{ x: left, y: goalY + pitchLength / 2 }, { x: right, y: goalY + pitchLength / 2 }]);
  const radius = landmark === "centreCircle" ? length / 2 : 9.15;
  lines.push(Array.from({ length: 65 }, (_, i) => { const a = (i / 64) * 2 * Math.PI; return { x: centerX + Math.cos(a) * radius, y: goalY + pitchLength / 2 + Math.sin(a) * radius }; }));
  for (const side of [0, 1]) {
    const y = goalY + side * pitchLength, sign = side === 0 ? 1 : -1;
    const penaltyWidth = landmark === "penaltyArea" ? length : 40.32, penaltyDepth = landmark === "penaltyArea" ? depth : 16.5;
    const goalWidth = landmark === "goalArea" ? length : 18.32, goalDepth = landmark === "goalArea" ? depth : 5.5;
    box(centerX - penaltyWidth / 2, y, penaltyWidth, sign * penaltyDepth);
    box(centerX - goalWidth / 2, y, goalWidth, sign * goalDepth);
    lines.push([{ x: centerX - 3.66, y }, { x: centerX + 3.66, y }]);
    const spotY = y + sign * 11;
    lines.push([{ x: centerX - 0.15, y: spotY }, { x: centerX + 0.15, y: spotY }]);
    const angle = Math.acos(Math.min(1, Math.max(-1, (penaltyDepth - 11) / 9.15)));
    lines.push(Array.from({ length: 33 }, (_, i) => { const a = -angle + (i / 32) * angle * 2; return { x: centerX + Math.sin(a) * 9.15, y: spotY + sign * Math.cos(a) * 9.15 }; }));
  }
  return lines;
}

const mapToFrame = (frame: Rect) => (p: Point): Point => ({ x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height });

/** Projected field markings as polylines in `frame` pixel coordinates; long lines are sampled so a horizon-crossing end still shows its visible part. */
export function overlayPolylines(calibration: GroundCalibration, frame: Rect): Point[][] {
  const reference = calibration.fieldReference, projection = fieldProjection(calibration.points);
  if (!calibrationIsValid(calibration) || calibration.mode !== "plane" || !reference || !projection) return [];
  const matrix = cameraMatrix(projection), center = mat3Apply(matrix, [0.5, 0.5, 1]);
  const result: Point[][] = [];
  for (const polyline of worldLines(reference, calibration.lengthMeters, calibration.widthMeters)) {
    const line: Point[] = [];
    for (let i = 0; i + 1 < polyline.length; i++) {
      const a = polyline[i]!, b = polyline[i + 1]!;
      const steps = Math.max(1, Math.floor(Math.hypot(b.x - a.x, b.y - a.y) / 2));
      for (let step = 0; step < steps; step++) { const t = step / steps; line.push({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }); }
    }
    const last = polyline[polyline.length - 1];
    if (last) line.push(last);
    let current: Point[] = [];
    const flush = () => { if (current.length > 1) result.push(current); current = []; };
    for (const point of line) {
      const p = mat3Apply(matrix, [point.x / calibration.lengthMeters, point.y / calibration.widthMeters, 1]);
      if (!Number.isFinite(p[2]) || !(p[2] * center[2] > 0) || !(Math.abs(p[2]) > 0.0001)) { flush(); continue; }
      const x = p[0] / p[2], y = p[1] / p[2];
      if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) >= 32 || Math.abs(y) >= 32) { flush(); continue; }
      current.push(mapToFrame(frame)({ x, y }));
    }
    flush();
  }
  return result;
}

/** The reference polygon (or circle) itself, in `frame` pixel coordinates. */
export function referencePolyline(calibration: GroundCalibration, frame: Rect): Point[] {
  const map = mapToFrame(frame);
  const projection = calibration.fieldReference?.landmark === "centreCircle" ? fieldProjection(calibration.points) : null;
  if (projection) {
    const circle = Array.from({ length: 65 }, (_, i) => { const a = (i / 64) * 2 * Math.PI; return cameraPoint(projection, { x: 0.5 + Math.cos(a) * 0.5, y: 0.5 + Math.sin(a) * 0.5 }); });
    return circle.every((p): p is Point => p != null) ? circle.map(map) : [];
  }
  const points = calibration.points.map(map);
  if (calibration.mode === "plane" && calibration.points.length === 4 && points[0]) points.push(points[0]);
  return points;
}

export interface FieldPreviewGeometry {
  referencePath: Point[];
  calibratedPath: Point[][];
  status: string | null;
}

/** Non-editable field guide over the analysis canvas; the saved calibration is the only source of truth. */
export function fieldPreviewGeometry(calibration: GroundCalibration | undefined | null, time: number, frame: Rect): FieldPreviewGeometry {
  if (!calibration || !calibrationIsValid(calibration)) return { referencePath: [], calibratedPath: [], status: "Set up field calibration in Measure" };
  const current = frozenCalibration(calibration, time);
  if (!current) return { referencePath: [], calibratedPath: [], status: "Field preview unavailable · camera tracking is not covering this time" };
  return { referencePath: referencePolyline(current, frame), calibratedPath: overlayPolylines(current, frame), status: null };
}
