/* Snapping a projected pitch template to painted markings: port of PitchRegistration.swift. Any plane alignment is
   refined against the frame's white lines; the result reports how much of the template found evidence. It is a
   refinement, not proof of metric accuracy. */
import type { Point } from "@/domain/geometry";
import type { GroundCalibration, GroundFieldReference, GroundLineObservation } from "@/domain/ground";
import { pitchLineCoordinate, pitchLineIsAcross } from "@/domain/ground";
import { cameraMatrix, mat3Apply, mat3Determinant, mat3Inverse, mat3Multiply, type Mat3 } from "../tracking/geometry";
import { solveNormalEquations } from "../tracking/camera-registration";
import { cropRegion, type FramePixels } from "../tracking/frame-pixels";
import { RECTANGLE, worldLines } from "./overlay";
import { calibrationIsValid, fieldProjection } from "./projection";
import { visionKernels } from "@/wasm/camelot-vision";

export type FitGrade = "good" | "check" | "poor";
export const FIT_GRADE_TITLES: Record<FitGrade, string> = { good: "Good fit", check: "Check fit", poor: "Weak fit" };

export interface SnapQuality {
  /** Median perpendicular distance between supported samples and the snapped template, in source pixels. */
  residualPixels: number;
  /** Supported samples divided by template samples visible in the frame. */
  coverage: number;
  supportedLines: number;
  acrossSupported: boolean;
  alongSupported: boolean;
}

export function qualityGrade(q: SnapQuality): FitGrade {
  const directions = q.acrossSupported && q.alongSupported;
  if (directions && q.supportedLines >= 4 && q.coverage >= 0.4 && q.residualPixels <= 1.6) return "good";
  if (directions && q.supportedLines >= 3 && q.coverage >= 0.2 && q.residualPixels <= 3.2) return "check";
  return "poor";
}
export const qualitySummary = (q: SnapQuality) => `${FIT_GRADE_TITLES[qualityGrade(q)]} · ${q.residualPixels.toFixed(1)} px · ${q.supportedLines} line${q.supportedLines === 1 ? "" : "s"}`;

export interface SnapResult { calibration: GroundCalibration; quality: SnapQuality }

/** White-marking evidence for one frame at a bounded working resolution; residuals convert to source pixels. */
export class MarkingEvidence {
  readonly width: number;
  readonly height: number;
  private readonly whiteness: Uint8Array;
  private readonly turf: Uint8Array;

  constructor(frame: FramePixels, readonly sourceWidth: number, readonly sourceHeight: number, maximumWidth = 1280) {
    const width = Math.min(maximumWidth, frame.width), height = Math.max(1, Math.floor((frame.height * width) / frame.width));
    const image = width === frame.width ? frame : cropRegion(frame, { x: 0, y: 0, width: 1, height: 1 }, width, height);
    this.width = width; this.height = height;
    const kernels = visionKernels();
    if (kernels) {
      const maps = kernels.markingEvidence(image.data, width, height);
      this.whiteness = maps.whiteness; this.turf = maps.turf;
      return;
    }
    const n = width * height, whiteness = new Uint8Array(n), turf = new Uint8Array(n), data = image.data;
    for (let index = 0; index < n; index++) {
      const r = data[index * 4]!, g = data[index * 4 + 1]!, b = data[index * 4 + 2]!;
      if (g > 45 && g * 100 > r * 94 && g * 100 > b * 135) turf[index] = 1;
      if (!(r * 10 > g * 8) || !(b * 20 > g * 13)) continue;
      const value = Math.min(r, g, b) * 2 - Math.max(r, g, b);
      if (value > 0) whiteness[index] = Math.min(255, value);
    }
    this.whiteness = whiteness; this.turf = turf;
  }

  static fromFrame(frame: FramePixels, sourceWidth = frame.width, sourceHeight = frame.height): MarkingEvidence | null {
    if (frame.width <= 32 || frame.height <= 32) return null;
    return new MarkingEvidence(frame, sourceWidth, sourceHeight);
  }

  get sourceScale() { return this.sourceWidth / this.width; }

  white(x: number, y: number): number {
    const ix = Math.round(x), iy = Math.round(y);
    if (ix < 0 || ix >= this.width || iy < 0 || iy >= this.height) return 0;
    return this.whiteness[iy * this.width + ix]!;
  }
  isTurf(x: number, y: number): boolean {
    const ix = Math.round(x), iy = Math.round(y);
    if (ix < 0 || ix >= this.width || iy < 0 || iy >= this.height) return false;
    return this.turf[iy * this.width + ix] === 1;
  }
  /** Bright neutral paint against darker surroundings along the line normal. */
  response(x: number, y: number, nx: number, ny: number, halfWidth: number): { value: number; score: number } {
    const value = this.white(x, y);
    const background = (this.white(x - halfWidth * nx, y - halfWidth * ny) + this.white(x + halfWidth * nx, y + halfWidth * ny)) / 2;
    return { value, score: value - background };
  }
}

interface Observation { line: [number, number, number]; observed: [number, number]; pixelScale: number; evidence: number; polyline: number; distance: number }
interface TemplatePolyline { points: [number, number][]; across: boolean; along: boolean }
interface Template { polylines: TemplatePolyline[] }
interface Stage { reach: number; radius: number; threshold: number | null }

/** Coarse-to-fine schedule: lock markings near the reference before trusting extrapolated lines. */
const STAGES: Stage[] = [
  { reach: 1.5, radius: 40, threshold: null }, { reach: 1.5, radius: 24, threshold: null }, { reach: 1.5, radius: 12, threshold: null }, { reach: 1.5, radius: 6, threshold: 4 },
  { reach: 4, radius: 28, threshold: null }, { reach: 4, radius: 14, threshold: null }, { reach: 4, radius: 7, threshold: 4 },
  { reach: Infinity, radius: 18, threshold: null }, { reach: Infinity, radius: 10, threshold: null }, { reach: Infinity, radius: 6, threshold: 3 }, { reach: Infinity, radius: 4, threshold: 2 },
];

export interface SnapTrace { iteration: number; visible: number; matched: number; corners: Point[] }

export function snapCalibration(calibration: GroundCalibration, evidence: MarkingEvidence, iterations = 33, trace?: (t: SnapTrace) => void): SnapResult | null {
  const reference = calibration.fieldReference;
  if (!calibrationIsValid(calibration) || calibration.mode !== "plane" || !reference) return null;
  const template = makeTemplate(reference, calibration.lengthMeters, calibration.widthMeters);
  let homography = homographyOf(calibration.points);
  if (!template || !homography) return null;
  let iteration = 0;
  stages: for (const stage of STAGES) {
    const wide = stage.radius * evidence.sourceScale * 1.2;
    const threshold = Math.min(wide, stage.threshold ?? wide);
    for (let repeat = 0; repeat < 3; repeat++) {
      if (iteration >= Math.max(1, iterations)) break stages;
      iteration += 1;
      const sampling = observeTemplate(template, homography, evidence, stage.radius, stage.reach);
      const observations = sampling.observations;
      if (observations.length < 12) continue stages;
      const correction = solveCorrection(observations, homography, threshold);
      if (!correction) continue stages;
      const inverse = mat3Inverse(correction);
      if (!inverse) continue stages;
      const next = mat3Multiply(homography, inverse);
      const before = cornersOf(homography), after = cornersOf(next);
      if (!before || !after || !(maximumCornerMovement(calibration.points, after) < 0.35)) continue stages;
      homography = next;
      trace?.({ iteration, visible: sampling.visibleSamples, matched: observations.length, corners: after });
      if (maximumCornerMovement(before, after) * evidence.sourceWidth < 0.5) break;
    }
  }
  const corners = cornersOf(homography);
  if (!corners) return null;
  const result: GroundCalibration = { ...calibration, points: corners, circleReference: undefined };
  if (!calibrationIsValid(result)) return null;
  const final = observeTemplate(template, homography, evidence, 4, Infinity);
  return { calibration: result, quality: qualityOf(final, template) };
}

/** Moves traced line endpoints onto the snapped template so a lines draft reproduces the refined alignment. */
export function reprojectLines(lines: readonly GroundLineObservation[], calibration: GroundCalibration, pitchLength: number, pitchWidth: number): GroundLineObservation[] | null {
  const homography = homographyOf(calibration.points);
  const inverse = homography ? mat3Inverse(homography) : null;
  if (!homography || !inverse) return null;
  const result: GroundLineObservation[] = [];
  for (const line of lines) {
    const k = pitchLineCoordinate(line.kind, pitchLength, pitchWidth);
    const points: Point[] = [];
    for (const point of line.points) {
      const q = mat3Apply(inverse, [point.x, point.y, 1]);
      if (!(Math.abs(q[2]) > 1e-9)) return null;
      const template: [number, number] = [q[0] / q[2], q[1] / q[2]];
      if (pitchLineIsAcross(line.kind)) template[1] = k; else template[0] = k;
      const p = mat3Apply(homography, [template[0], template[1], 1]);
      if (!(Math.abs(p[2]) > 1e-9) || !Number.isFinite(p[0] / p[2]) || !Number.isFinite(p[1] / p[2])) return null;
      points.push({ x: p[0] / p[2], y: p[1] / p[2] });
    }
    result.push({ kind: line.kind, points });
  }
  return result;
}

// MARK: - Template

function makeTemplate(reference: GroundFieldReference, length: number, depth: number): Template | null {
  const lines = worldLines(reference, length, depth);
  if (lines.length === 0 || !(length > 0) || !(depth > 0)) return null;
  const polylines: TemplatePolyline[] = [];
  for (const line of lines) {
    const points = line.map((p): [number, number] => [p.x / length, p.y / depth]);
    if (points.length < 2) continue;
    let across = false, along = false;
    for (let i = 0; i + 1 < points.length; i++) { const dx = points[i + 1]![0] - points[i]![0], dy = points[i + 1]![1] - points[i]![1]; if (Math.abs(dx) >= Math.abs(dy)) across = true; else along = true; }
    polylines.push({ points, across, along });
  }
  return polylines.length ? { polylines } : null;
}

/** The plane homography (template → image) of four corners, or null when degenerate. */
export function homographyOf(corners: readonly Point[]): Mat3 | null {
  const projection = fieldProjection(corners);
  if (!projection || projection.values.length !== 9 || !projection.values.every(Number.isFinite)) return null;
  const matrix = cameraMatrix(projection);
  return Math.abs(mat3Determinant(matrix)) > 1e-12 ? matrix : null;
}

function cornersOf(homography: Mat3): Point[] | null {
  const center = mat3Apply(homography, [0.5, 0.5, 1]);
  if (!(Math.abs(center[2]) > 1e-9)) return null;
  const result: Point[] = [];
  for (const point of RECTANGLE) {
    const p = mat3Apply(homography, [point.x, point.y, 1]);
    if (!(Math.abs(p[2]) > 1e-9) || !(p[2] * center[2] > 0)) return null;
    const x = p[0] / p[2], y = p[1] / p[2];
    if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) >= 32 || Math.abs(y) >= 32) return null;
    result.push({ x, y });
  }
  return fieldProjection(result) ? result : null;
}

const maximumCornerMovement = (a: readonly Point[], b: readonly Point[]) => Math.max(...a.map((p, i) => Math.hypot(p.x - b[i]!.x, p.y - b[i]!.y)));

// MARK: - Sampling

interface Sampling { observations: Observation[]; visibleSamples: number; visiblePerLine: Map<number, number> }

function observeTemplate(template: Template, homography: Mat3, evidence: MarkingEvidence, radius: number, reach: number): Sampling {
  const width = evidence.width, height = evidence.height;
  const inverse = mat3Inverse(homography);
  const center = mat3Apply(homography, [0.5, 0.5, 1]);
  const sampling: Sampling = { observations: [], visibleSamples: 0, visiblePerLine: new Map() };
  if (!inverse || !(Math.abs(center[2]) > 1e-9)) return sampling;
  const halfWidth = 6;
  const claimed = new Map<number, number>();
  const image = (t: [number, number]): [number, number] | null => {
    const p = mat3Apply(homography, [t[0], t[1], 1]);
    if (!(Math.abs(p[2]) > 1e-9) || !(p[2] * center[2] > 0)) return null;
    const x = (p[0] / p[2]) * width, y = (p[1] / p[2]) * height;
    return Number.isFinite(x) && Number.isFinite(y) ? [x, y] : null;
  };
  template.polylines.forEach((polyline, index) => {
    let lastSample: [number, number] | null = null;
    for (let i = 0; i + 1 < polyline.points.length; i++) {
      const a = polyline.points[i]!, b = polyline.points[i + 1]!;
      const direction: [number, number] = [b[0] - a[0], b[1] - a[1]];
      const length = Math.hypot(direction[0], direction[1]);
      if (!(length > 1e-9)) continue;
      const tangent: [number, number] = [direction[0] / length, direction[1] / length];
      const normal: [number, number] = [-tangent[1], tangent[0]];
      const line: [number, number, number] = [normal[0], normal[1], -(normal[0] * a[0] + normal[1] * a[1])];
      const count = Math.max(2, Math.ceil(length * 200));
      for (let step = 0; step <= count; step++) {
        const t: [number, number] = [a[0] + (direction[0] * step) / count, a[1] + (direction[1] * step) / count];
        if (Math.abs(t[0] - 0.5) > reach + 0.5 || Math.abs(t[1] - 0.5) > reach + 0.5) continue;
        const p = image(t);
        if (!p || p[0] < 2 || p[0] >= width - 2 || p[1] < 2 || p[1] >= height - 2) continue;
        if (lastSample && Math.hypot(p[0] - lastSample[0], p[1] - lastSample[1]) < 4) continue;
        lastSample = p;
        const epsilon = 0.0005;
        const ahead = image([t[0] + tangent[0] * epsilon, t[1] + tangent[1] * epsilon]), behind = image([t[0] - tangent[0] * epsilon, t[1] - tangent[1] * epsilon]);
        const side = image([t[0] + normal[0] * epsilon, t[1] + normal[1] * epsilon]);
        if (!ahead || !behind || !side) continue;
        const imageTangent: [number, number] = [ahead[0] - behind[0], ahead[1] - behind[1]];
        const tangentLength = Math.hypot(imageTangent[0], imageTangent[1]);
        if (!(tangentLength > 1e-9)) continue;
        const n: [number, number] = [-imageTangent[1] / tangentLength, imageTangent[0] / tangentLength];
        const pixelScale = (Math.abs((side[0] - p[0]) * n[0] + (side[1] - p[1]) * n[1]) / epsilon) * evidence.sourceScale;
        if (!Number.isFinite(pixelScale) || !(pixelScale > 0)) continue;
        sampling.visibleSamples += 1;
        sampling.visiblePerLine.set(index, (sampling.visiblePerLine.get(index) ?? 0) + 1);
        const hit = searchMarking(p, n, [imageTangent[0] / tangentLength, imageTangent[1] / tangentLength], radius, halfWidth, evidence);
        if (!hit) continue;
        const q = mat3Apply(inverse, [hit.point[0] / width, hit.point[1] / height, 1]);
        const qp = mat3Apply(inverse, [p[0] / width, p[1] / height, 1]);
        if (!(Math.abs(q[2]) > 1e-9) || !(q[2] * qp[2] > 0)) continue;
        const observation: Observation = { line, observed: [q[0] / q[2], q[1] / q[2]], pixelScale: Math.min(pixelScale, 20000), evidence: hit.evidence, polyline: index, distance: Math.hypot(hit.point[0] - p[0], hit.point[1] - p[1]) };
        const cell = Math.floor(hit.point[1] / 3) * (Math.floor(evidence.width / 3) + 2) + Math.floor(hit.point[0] / 3);
        const existing = claimed.get(cell);
        if (existing != null && sampling.observations[existing]!.polyline !== index) {
          if (sampling.observations[existing]!.distance > observation.distance) sampling.observations[existing] = observation;
          continue;
        }
        claimed.set(cell, sampling.observations.length);
        sampling.observations.push(observation);
      }
    }
  });
  return sampling;
}

function searchMarking(p: [number, number], n: [number, number], tangent: [number, number], radius: number, halfWidth: number, evidence: MarkingEvidence): { point: [number, number]; evidence: number } | null {
  const steps = Math.ceil(radius);
  const scores = new Float64Array(steps * 2 + 1);
  let best: { index: number; score: number } | null = null;
  for (let offset = -steps; offset <= steps; offset++) {
    const x = p[0] + offset * n[0], y = p[1] + offset * n[1];
    const response = evidence.response(x, y, n[0], n[1], halfWidth);
    scores[offset + steps] = Math.max(0, response.score);
    if (response.value < 50 || response.score < 24) continue;
    const ranked = response.score * (1 - (0.5 * Math.abs(offset)) / steps);
    if (!best || ranked > best.score) best = { index: offset + steps, score: ranked };
  }
  if (!best) return null;
  const peak = scores[best.index]!;
  let low = best.index, high = best.index;
  while (low > 0 && scores[low - 1]! >= peak * 0.6) low -= 1;
  while (high < scores.length - 1 && scores[high + 1]! >= peak * 0.6) high += 1;
  let offset: number;
  if (high > low) {
    let weighted = 0, total = 0;
    for (let index = low; index <= high; index++) { weighted += (index - steps) * scores[index]!; total += scores[index]!; }
    offset = total > 0 ? weighted / total : best.index - steps;
  } else {
    offset = best.index - steps;
    if (best.index > 0 && best.index < scores.length - 1) {
      const left = scores[best.index - 1]!, right = scores[best.index + 1]!, denominator = left - 2 * peak + right;
      if (denominator < -1e-6) offset += Math.max(-0.5, Math.min(0.5, (0.5 * (left - right)) / denominator));
    }
  }
  const bx = p[0] + offset * n[0], by = p[1] + offset * n[1];
  const value = evidence.white(bx, by);
  if (!(evidence.white(bx + 5 * tangent[0], by + 5 * tangent[1]) >= value * 0.4) || !(evidence.white(bx - 5 * tangent[0], by - 5 * tangent[1]) >= value * 0.4)) return null;
  const margin = halfWidth + 3 + (high - low) / 2;
  const sideA: [number, number] = [bx + margin * n[0], by + margin * n[1]], sideB: [number, number] = [bx - margin * n[0], by - margin * n[1]];
  if (!(evidence.white(sideA[0], sideA[1]) <= value * 0.4) || !(evidence.white(sideB[0], sideB[1]) <= value * 0.4)) return null;
  if (!(evidence.isTurf(sideA[0], sideA[1]) || evidence.isTurf(sideB[0], sideB[1]))) return null;
  return { point: [bx, by], evidence: Math.min(1, peak / 80) };
}

// MARK: - Solving

function solveCorrection(observations: readonly Observation[], homography: Mat3, threshold: number): Mat3 | null {
  const normal: number[][] = Array.from({ length: 8 }, () => new Array<number>(9).fill(0));
  let used = 0;
  for (const o of observations) {
    const [a, b, c] = o.line, [qx, qy] = o.observed;
    const residual = a * qx + b * qy + c;
    const pixels = residual * o.pixelScale;
    if (!(Math.abs(pixels) < threshold)) continue;
    const ratio = pixels / threshold, robust = (1 - ratio * ratio) * (1 - ratio * ratio);
    const weight = o.pixelScale * o.pixelScale * o.evidence * robust;
    if (!Number.isFinite(weight) || !(weight > 0)) continue;
    accumulate(normal, [a * qx, a * qy, a, b * qx, b * qy, b, c * qx, c * qy], -residual, weight);
    used += 1;
  }
  if (used < 12) return null;
  for (const point of RECTANGLE) {
    const cx = point.x, cy = point.y;
    const scale = Math.min(4000, Math.max(1, cornerPixelScale(homography, [cx, cy])));
    const damping = 0.3 * scale * scale;
    accumulate(normal, [cx, cy, 1, 0, 0, 0, -cx * cx, -cx * cy], 0, damping);
    accumulate(normal, [0, 0, 0, cx, cy, 1, -cy * cx, -cy * cy], 0, damping);
  }
  const d = solveNormalEquations(normal, 1e-12, true);
  if (!d) return null;
  const correction: Mat3 = [1 + d[0]!, d[1]!, d[2]!, d[3]!, 1 + d[4]!, d[5]!, d[6]!, d[7]!, 1];
  return Math.abs(mat3Determinant(correction)) > 1e-9 ? correction : null;
}

function cornerPixelScale(homography: Mat3, t: [number, number]): number {
  const epsilon = 0.001;
  const map = (p: [number, number]): [number, number] | null => { const v = mat3Apply(homography, [p[0], p[1], 1]); return Math.abs(v[2]) > 1e-9 ? [(v[0] / v[2]) * 1920, (v[1] / v[2]) * 1080] : null; };
  const a = map(t), b = map([t[0] + epsilon, t[1] + epsilon]);
  if (!a || !b) return 4000;
  return Math.hypot(b[0] - a[0], b[1] - a[1]) / (epsilon * 1.4142);
}

function accumulate(normal: number[][], row: number[], value: number, weight: number): void {
  for (let i = 0; i < 8; i++) {
    const wi = row[i]! * weight;
    if (wi === 0) continue;
    for (let j = 0; j < 8; j++) normal[i]![j]! += wi * row[j]!;
    normal[i]![8]! += wi * value;
  }
}

// MARK: - Quality

function qualityOf(sampling: Sampling, template: Template): SnapQuality {
  const residuals: number[] = [];
  const supportedPerLine = new Map<number, number>();
  for (const o of sampling.observations) {
    residuals.push(Math.abs(o.line[0] * o.observed[0] + o.line[1] * o.observed[1] + o.line[2]) * o.pixelScale);
    supportedPerLine.set(o.polyline, (supportedPerLine.get(o.polyline) ?? 0) + 1);
  }
  residuals.sort((a, b) => a - b);
  let supportedLines = 0, across = false, along = false;
  for (const [index, visible] of sampling.visiblePerLine) {
    if (visible < 3) continue;
    const supported = supportedPerLine.get(index) ?? 0;
    if (supported < 3 || supported < visible * 0.4) continue;
    supportedLines += 1;
    if (template.polylines[index]!.across) across = true;
    if (template.polylines[index]!.along) along = true;
  }
  const coverage = sampling.visibleSamples > 0 ? sampling.observations.length / sampling.visibleSamples : 0;
  return { residualPixels: residuals.length === 0 ? Infinity : residuals[residuals.length >> 1]!, coverage, supportedLines, acrossSupported: across, alongSupported: along };
}
