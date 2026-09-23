/* Field-plane geometry: ports of AnalysisFieldGuide (AnalysisFieldGuide.swift), GroundCalibration.swift,
   GroundEffectProjection.swift and the per-point ground shape helpers in GroundShapeGeometry.swift.
   Pure functions over the persisted `GroundCalibration`; image points are fractions of the display frame. */
import type { Point } from "@/domain/geometry";
import type { AnalysisDrawingTool } from "@/domain/annotation";
import type { AnalysisFieldLayout, GroundCalibration, GroundLineObservation } from "@/domain/ground";
import { LEGACY_FIELD_LAYOUT } from "@/domain/ground";
import type { CameraTransform, PlayerMotion } from "@/domain/tracking";
import { cameraFromMatrix, cameraMatrix, cameraPoint, feet, IDENTITY3, isFinitePoint, mat3Apply, mat3Determinant, mat3Inverse, type Mat3 } from "../tracking/geometry";
import { boxAt, transformAt } from "../tracking/motion";
import { circleTransformed } from "./circle";

// MARK: - AnalysisFieldGuide

/** Projective pitch guide from four clockwise corners (far left, far right, near right, near left). */
export function fieldProjection(p: readonly Point[]): CameraTransform | null {
  if (p.length !== 4) return null;
  const turns = [0, 1, 2, 3].map((i) => {
    const a = p[i]!, b = p[(i + 1) % 4]!, c = p[(i + 2) % 4]!;
    return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
  });
  if (!(turns.every((t) => t > 0.000001) || turns.every((t) => t < -0.000001))) return null;
  const [p0, p1, p2, p3] = p as [Point, Point, Point, Point];
  const dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dy1 = p1.y - p2.y, dy2 = p3.y - p2.y;
  const dx3 = p0.x - p1.x + p2.x - p3.x, dy3 = p0.y - p1.y + p2.y - p3.y;
  const determinant = dx1 * dy2 - dx2 * dy1;
  if (!(Math.abs(determinant) > 0.000001)) return null;
  const g = (dx3 * dy2 - dx2 * dy3) / determinant, h = (dx1 * dy3 - dx3 * dy1) / determinant;
  return { values: [p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x, p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y, g, h, 1] };
}

/** Polylines (image fractions) of the drawn field guide; empty for a crossed quad. Port of `AnalysisFieldGuide.path`. */
export function fieldGuidePolylines(corners: readonly Point[], layout: AnalysisFieldLayout = LEGACY_FIELD_LAYOUT): Point[][] {
  const projection = fieldProjection(corners);
  if (!projection) return [];
  const result: Point[][] = [];
  const line = (points: Point[], closed = false) => {
    const mapped: Point[] = [];
    for (const point of points) {
      const oriented = layout.region !== "fullPitch" && layout.goalSide === "right" ? { x: 1 - point.x, y: point.y } : point;
      const q = cameraPoint(projection, oriented);
      if (!q) return;
      mapped.push(q);
    }
    if (closed && mapped[0]) mapped.push(mapped[0]);
    result.push(mapped);
  };
  line([{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }], true);
  if (layout.region !== "fullPitch") {
    const length = layout.region === "halfPitch" ? 52.5 : 16.5, breadth = layout.region === "halfPitch" ? 68 : 40.32;
    const boxes: [number, number][] = layout.region === "halfPitch" ? [[16.5, 20.16], [5.5, 9.16]] : [[5.5, 9.16]];
    for (const [depth, halfWidth] of boxes) {
      line([{ x: 0, y: 0.5 - halfWidth / breadth }, { x: depth / length, y: 0.5 - halfWidth / breadth }, { x: depth / length, y: 0.5 + halfWidth / breadth }, { x: 0, y: 0.5 + halfWidth / breadth }]);
    }
    if (layout.region === "halfPitch") {
      line(Array.from({ length: 33 }, (_, index) => { const angle = Math.PI / 2 + (index / 32) * Math.PI; return { x: 1 + (Math.cos(angle) * 9.15) / length, y: 0.5 + (Math.sin(angle) * 9.15) / breadth }; }));
    }
    return result;
  }
  line([{ x: 0.5, y: 0 }, { x: 0.5, y: 1 }]);
  for (const side of [0, 1]) {
    const sign = side === 0 ? 1 : -1;
    for (const [depth, halfWidth] of [[16.5 / 105, 20.16 / 68], [5.5 / 105, 9.16 / 68]] as [number, number][]) {
      line([{ x: side, y: 0.5 - halfWidth }, { x: side + sign * depth, y: 0.5 - halfWidth }, { x: side + sign * depth, y: 0.5 + halfWidth }, { x: side, y: 0.5 + halfWidth }]);
    }
  }
  line(Array.from({ length: 64 }, (_, index) => { const angle = (index / 64) * Math.PI * 2; return { x: 0.5 + (Math.cos(angle) * 9.15) / 105, y: 0.5 + (Math.sin(angle) * 9.15) / 68 }; }), true);
  return result;
}

// MARK: - GroundCalibration

const finite = (p: Point): Point | null => (isFinitePoint(p) ? p : null);

export function calibrationIsValid(c: GroundCalibration): boolean {
  if (!Number.isFinite(c.lengthMeters) || !(c.lengthMeters > 0) || !Number.isFinite(c.imageAspectRatio) || !(c.imageAspectRatio > 0)) return false;
  if (!Number.isFinite(c.referenceTime) || !c.points.every(isFinitePoint)) return false;
  if (c.mode === "localScale") {
    if (c.points.length !== 2) return false;
    const d = { x: c.points[1]!.x - c.points[0]!.x, y: c.points[1]!.y - c.points[0]!.y };
    return Math.hypot(d.x * c.imageAspectRatio, d.y) > 1e-9;
  }
  if (c.points.length !== 4 || !Number.isFinite(c.widthMeters) || !(c.widthMeters > 0)) return false;
  const projection = fieldProjection(c.points);
  return projection != null && projection.values.every(Number.isFinite);
}

export const calibrationIsApproximate = (c: GroundCalibration) => c.mode === "localScale";

/** Camera pose at `time` relative to the reference frame; identity for a fixed camera. */
export function cameraTransformAt(c: GroundCalibration, time: number): CameraTransform | null {
  if (!Number.isFinite(time)) return null;
  if (c.fixedCamera) return { values: IDENTITY3.slice() };
  if (!c.cameraMotion) return Math.abs(time - c.referenceTime) <= 0.12 ? { values: IDENTITY3.slice() } : null;
  return transformAt({ ...c.cameraMotion, referenceTime: c.referenceTime }, time);
}

/** A freeze frame reuses the visible ground pose without another camera pass. */
export function frozenCalibration(c: GroundCalibration, time: number): GroundCalibration | null {
  if (!calibrationIsValid(c)) return null;
  const camera = cameraTransformAt(c, time);
  if (!camera) return null;
  const mapped: Point[] = [];
  for (const p of c.points) { const q = cameraPoint(camera, p); if (!q) return null; mapped.push(q); }
  const result: GroundCalibration = { ...c, points: mapped, referenceTime: time, fixedCamera: true, cameraMotion: undefined };
  result.circleReference = c.circleReference ? circleTransformed(c.circleReference, camera) ?? undefined : undefined;
  if (c.lineReferences) {
    const moved: GroundLineObservation[] = c.lineReferences.map((line) => ({ kind: line.kind, points: line.points.flatMap((p) => { const q = cameraPoint(camera, p); return q ? [q] : []; }) }));
    result.lineReferences = moved.every((l) => l.points.length === 2) ? moved : undefined;
  }
  return calibrationIsValid(result) ? result : null;
}

function inversePoint(point: Point, transform: CameraTransform, anchor: Point = { x: 0.5, y: 0.5 }): Point | null {
  if (transform.values.length !== 9 || !transform.values.every(Number.isFinite)) return null;
  const matrix = cameraMatrix(transform);
  if (!(Math.abs(mat3Determinant(matrix)) > 1e-7)) return null;
  const inverse = mat3Inverse(matrix);
  if (!inverse) return null;
  const value = mat3Apply(inverse, [point.x, point.y, 1]), center = mat3Apply(inverse, [anchor.x, anchor.y, 1]);
  if (!Number.isFinite(value[2]) || !Number.isFinite(center[2]) || !(Math.abs(value[2]) > Math.max(0.00001, Math.abs(center[2]) * 0.0001)) || !(value[2] * center[2] > 0)) return null;
  return finite({ x: value[0] / value[2], y: value[1] / value[2] });
}

function referencePoint(c: GroundCalibration, point: Point, time: number): Point | null {
  if (!isFinitePoint(point)) return null;
  const camera = cameraTransformAt(c, time);
  return camera ? inversePoint(point, camera) : null;
}

function projectWorld(c: GroundCalibration, world: Point, projection: CameraTransform): Point | null {
  const matrix = cameraMatrix(projection);
  const mapped = mat3Apply(matrix, [world.x / c.lengthMeters, world.y / c.widthMeters, 1]), center = mat3Apply(matrix, [0.5, 0.5, 1]);
  if (!Number.isFinite(mapped[2]) || !(Math.abs(mapped[2]) > Math.max(0.00001, Math.abs(center[2]) * 0.0001)) || !(mapped[2] * center[2] > 0)) return null;
  return finite({ x: mapped[0] / mapped[2], y: mapped[1] / mapped[2] });
}

/** Image → metres on the ground plane (local-scale or plane). */
export function worldPoint(c: GroundCalibration, point: Point, time: number): Point | null {
  if (!calibrationIsValid(c)) return null;
  const reference = referencePoint(c, point, time);
  if (!reference) return null;
  const [p0, p1] = c.points as [Point, Point];
  if (c.mode === "localScale") {
    const x = (reference.x - p0.x) * c.imageAspectRatio, y = reference.y - p0.y;
    const scale = c.lengthMeters / Math.hypot((p1.x - p0.x) * c.imageAspectRatio, p1.y - p0.y);
    return finite({ x: x * scale, y: y * scale });
  }
  const projection = fieldProjection(c.points);
  const center = projection ? cameraPoint(projection, { x: 0.5, y: 0.5 }) : null;
  const inverse = projection && center ? inversePoint(reference, projection, center) : null;
  return inverse ? finite({ x: inverse.x * c.lengthMeters, y: inverse.y * c.widthMeters }) : null;
}

/** Metres on the ground plane → image at `time`. */
export function imagePoint(c: GroundCalibration, world: Point, time: number): Point | null {
  if (!calibrationIsValid(c) || !isFinitePoint(world)) return null;
  const camera = cameraTransformAt(c, time);
  if (!camera) return null;
  let reference: Point | null;
  if (c.mode === "localScale") {
    const [p0, p1] = c.points as [Point, Point];
    const scale = c.lengthMeters / Math.hypot((p1.x - p0.x) * c.imageAspectRatio, p1.y - p0.y);
    if (!(scale > 0)) return null;
    reference = { x: p0.x + world.x / scale / c.imageAspectRatio, y: p0.y + world.y / scale };
  } else {
    const projection = fieldProjection(c.points);
    reference = projection ? projectWorld(c, world, projection) : null;
  }
  return reference && isFinitePoint(reference) ? cameraPoint(camera, reference) : null;
}

/** Alias for the contract name: image point on the ground plane after camera compensation. */
export const projectGroundPoint = imagePoint;

export function groundDistance(c: GroundCalibration, a: Point, b: Point, time: number): number | null {
  const lhs = worldPoint(c, a, time), rhs = worldPoint(c, b, time);
  if (!lhs || !rhs) return null;
  const value = Math.hypot(lhs.x - rhs.x, lhs.y - rhs.y);
  return Number.isFinite(value) ? value : null;
}

/** Ground speed (m/s) of a tracked player from a ±0.3 s linear fit; null across gaps, losses or sparse samples. */
export function groundSpeed(c: GroundCalibration, motion: PlayerMotion, time: number): number | null {
  if (!calibrationIsValid(c) || !Number.isFinite(time)) return null;
  const samples = motion.samples;
  if (samples.length === 0) return null;
  const lower = (value: number) => { let lo = 0, hi = samples.length; while (lo < hi) { const mid = (lo + hi) >> 1; if (samples[mid]!.time < value) lo = mid + 1; else hi = mid; } return lo; };
  const startIndex = lower(time - 0.3), endIndex = lower(time + 0.3);
  if (startIndex >= samples.length) return null;
  const lowerTime = Math.max(time - 0.3, samples[startIndex]!.time);
  const upperSampleIndex = Math.min(samples.length - 1, Math.max(startIndex, endIndex));
  const upperTime = Math.min(time + 0.3, samples[upperSampleIndex]!.time);
  if (upperTime - lowerTime < 0.2 || !boxAt(motion, time)) return null;
  const spanStart = Math.max(0, startIndex - 1), spanEnd = Math.min(samples.length - 1, upperSampleIndex + 1);
  if (spanStart > spanEnd) return null;
  for (let index = spanStart; index < spanEnd; index++) {
    const a = samples[index]!.time, b = samples[index + 1]!.time;
    if (a < upperTime && b > lowerTime && b - a > 0.2) return null;
  }
  if (motion.lostAt != null && lowerTime < motion.lostAt && upperTime >= motion.lostAt) return null;
  if (motion.gaps?.some((g) => g[0] <= upperTime && g[1] >= lowerTime)) return null;
  const values: [number, Point][] = [];
  const count = Math.min(21, Math.max(2, Math.ceil((upperTime - lowerTime) / 0.03) + 1));
  for (let index = 0; index < count; index++) {
    const sampleTime = lowerTime + ((upperTime - lowerTime) * index) / (count - 1);
    const box = boxAt(motion, sampleTime);
    const world = box ? worldPoint(c, feet(box), sampleTime) : null;
    if (!world) return null;
    values.push([sampleTime, world]);
  }
  const n = values.length;
  const meanT = values.reduce((a, v) => a + v[0], 0) / n, meanX = values.reduce((a, v) => a + v[1].x, 0) / n, meanY = values.reduce((a, v) => a + v[1].y, 0) / n;
  const denominator = values.reduce((a, v) => a + (v[0] - meanT) * (v[0] - meanT), 0);
  if (!(denominator > 1e-9)) return null;
  const vx = values.reduce((a, v) => a + (v[0] - meanT) * (v[1].x - meanX), 0) / denominator;
  const vy = values.reduce((a, v) => a + (v[0] - meanT) * (v[1].y - meanY), 0) / denominator;
  const result = Math.hypot(vx, vy);
  return Number.isFinite(result) ? result : null;
}

/** 32-point ground circle around an image point, in image coordinates; plane mode only. */
export function groundCircle(c: GroundCalibration, center: Point, radiusMeters: number, time: number): Point[] | null {
  if (c.mode !== "plane" || !Number.isFinite(radiusMeters) || radiusMeters < 0) return null;
  const origin = worldPoint(c, center, time), projection = fieldProjection(c.points), camera = cameraTransformAt(c, time);
  if (!origin || !projection || !camera) return null;
  const result: Point[] = [];
  for (let i = 0; i < 32; i++) {
    const angle = (i * 2 * Math.PI) / 32;
    const reference = projectWorld(c, { x: origin.x + Math.cos(angle) * radiusMeters, y: origin.y + Math.sin(angle) * radiusMeters }, projection);
    const point = reference ? cameraPoint(camera, reference) : null;
    if (!point) return null;
    result.push(point);
  }
  return result;
}

/** Points on the ground → the same points raised `heightMeters` above the floor (perspective walls). Null unless every point projects. */
export function groundPolygon(c: GroundCalibration, points: readonly Point[], heightMeters: number, time: number): Point[] | null {
  const projection = groundEffectProjection(c, time);
  if (!projection) return null;
  const raised: Point[] = [];
  for (const p of points) { const q = projection.raised(p, heightMeters); if (!q) return null; raised.push(q); }
  return raised;
}

// MARK: - GroundEffectProjection

export interface GroundEffectProjection {
  plane: Mat3;
  vertical: [number, number, number];
  inverse: Mat3;
  anchorDepth: number;
  /** Image point on the floor raised by `meters`, or null when the extrusion is unstable. */
  raised(imagePoint: Point, meters: number): Point | null;
}

/** Pinhole extrusion of the metric ground homography (centred principal point, square pixels). */
export function groundEffectProjection(ground: GroundCalibration, time: number): GroundEffectProjection | null {
  if (ground.mode !== "plane" || !calibrationIsValid(ground)) return null;
  const camera = cameraTransformAt(ground, time), h = fieldProjection(ground.points);
  if (!camera || !h) return null;
  const m = cameraMatrix(h);
  // Columns of H scaled to metres.
  const col = (i: number): [number, number, number] => [m[i]!, m[3 + i]!, m[6 + i]!];
  const c0 = col(0).map((v) => v / ground.lengthMeters) as [number, number, number];
  const c1 = col(1).map((v) => v / ground.widthMeters) as [number, number, number];
  const c2 = col(2);
  const aspect = ground.imageAspectRatio;
  const centred = (v: [number, number, number]): [number, number, number] => [aspect * (v[0] - 0.5 * v[2]), v[1] - 0.5 * v[2], v[2]];
  const a = centred(c0), b = centred(c1);
  const cx = a[0] * b[0] + a[1] * b[1], cy = a[0] * a[0] + a[1] * a[1] - b[0] * b[0] - b[1] * b[1];
  const dx = a[2] * b[2], dy = a[2] * a[2] - b[2] * b[2];
  const denominator = dx * dx + dy * dy;
  const squared = denominator > 1e-14 ? -(cx * dx + cy * dy) / denominator : -1;
  const focal = Number.isFinite(squared) && squared > 0.0625 && squared < 100 ? Math.sqrt(squared) : Math.max(1, aspect);
  const ray = (v: [number, number, number]): [number, number, number] => [v[0] / focal, v[1] / focal, v[2]];
  const first = ray(a), second = ray(b);
  const length = (v: [number, number, number]) => Math.hypot(v[0], v[1], v[2]);
  const scale = (length(first) + length(second)) / 2;
  let normal: [number, number, number] = [first[1] * second[2] - first[2] * second[1], first[2] * second[0] - first[0] * second[2], first[0] * second[1] - first[1] * second[0]];
  const normalLength = length(normal);
  if (!(normalLength > 1e-9) || !Number.isFinite(scale) || !(scale > 0)) return null;
  normal = [normal[0] / normalLength, normal[1] / normalLength, normal[2] / normalLength];
  const r2 = ray(centred(c2));
  if (normal[0] * r2[0] + normal[1] * r2[1] + normal[2] * r2[2] > 0) normal = [-normal[0], -normal[1], -normal[2]];
  let column: [number, number, number] = [((focal / aspect) * normal[0] + 0.5 * normal[2]) * scale, (focal * normal[1] + 0.5 * normal[2]) * scale, normal[2] * scale];
  const cameraM = cameraMatrix(camera);
  const metric: Mat3 = [c0[0], c1[0], c2[0], c0[1], c1[1], c2[1], c0[2], c1[2], c2[2]];
  const plane = multiply(cameraM, metric);
  column = mat3Apply(cameraM, column);
  const center = mat3Apply(plane, [ground.lengthMeters / 2, ground.widthMeters / 2, 1]);
  const inverse = mat3Inverse(plane);
  if (!inverse || !(Math.abs(mat3Determinant(plane)) > 1e-10) || !Number.isFinite(center[2]) || !(Math.abs(center[2]) > 1e-6)) return null;
  const anchorDepth = center[2];
  return {
    plane, vertical: column, inverse, anchorDepth,
    raised(imagePoint, meters) {
      if (!Number.isFinite(meters) || meters < 0 || meters > 20) return null;
      const raw = mat3Apply(inverse, [imagePoint.x, imagePoint.y, 1]);
      if (!(Math.abs(raw[2]) > 1e-7)) return null;
      const floor = mat3Apply(plane, [raw[0] / raw[2], raw[1] / raw[2], 1]);
      const top: [number, number, number] = [floor[0] + column[0] * meters, floor[1] + column[1] * meters, floor[2] + column[2] * meters];
      if (!(floor[2] * anchorDepth > 0) || !(top[2] * floor[2] > 0) || !(Math.abs(top[2]) > Math.abs(floor[2]) * 0.1)) return null;
      const result = { x: top[0] / top[2], y: top[1] / top[2] };
      if (!isFinitePoint(result) || !(Math.hypot(result.x - imagePoint.x, result.y - imagePoint.y) < 2)) return null;
      return result;
    },
  };
}

function multiply(a: Mat3, b: Mat3): Mat3 {
  return cameraMatrix(cameraFromMatrix([
    a[0] * b[0] + a[1] * b[3] + a[2] * b[6], a[0] * b[1] + a[1] * b[4] + a[2] * b[7], a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
    a[3] * b[0] + a[4] * b[3] + a[5] * b[6], a[3] * b[1] + a[4] * b[4] + a[5] * b[7], a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
    a[6] * b[0] + a[7] * b[3] + a[8] * b[6], a[6] * b[1] + a[7] * b[4] + a[8] * b[7], a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
  ]));
}

// MARK: - Per-point field-plane shapes (GroundShapeGeometry.swift)

/** The frozen plane for a grounded drawing at `time`, or null when the camera is not covered. */
export function groundPlaneAt(ground: GroundCalibration | undefined | null, time: number): GroundCalibration | null {
  if (!ground || ground.mode !== "plane") return null;
  return frozenCalibration(ground, time);
}

function projectGroundPoints(points: readonly Point[], plane: GroundCalibration, time: number): Point[] | null {
  const projected: Point[] = [];
  for (const p of points) { const q = imagePoint(plane, p, time); if (!q) return null; projected.push(q); }
  return projected;
}

/** Four floor corners of a grounded rectangle/ellipse authored by two handles. */
export function groundShapeCorners(tool: AnalysisDrawingTool, pose: readonly Point[], plane: GroundCalibration, time: number): Point[] | null {
  if (tool !== "rectangle" && tool !== "ellipse") return null;
  const first = pose[0], last = pose[pose.length - 1];
  if (!first || !last) return null;
  const a = worldPoint(plane, first, time), b = worldPoint(plane, last, time);
  if (!a || !b) return null;
  return projectGroundPoints([a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }], plane, time);
}

/** Normalized image vertices of a grounded shape, expanded in metric field coordinates before projecting back. */
export function groundShapeBoundary(tool: AnalysisDrawingTool, pose: readonly Point[], plane: GroundCalibration, time: number): Point[] {
  const first = pose[0], last = pose[pose.length - 1];
  if (!first || !last) return [];
  if (tool === "rectangle") return groundShapeCorners(tool, pose, plane, time) ?? [];
  if (tool === "ellipse") {
    const a = worldPoint(plane, first, time), b = worldPoint(plane, last, time);
    if (!a || !b) return [];
    const center = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    const vertices = Array.from({ length: 96 }, (_, index) => { const angle = (index * 2 * Math.PI) / 96; return { x: center.x + ((b.x - a.x) / 2) * Math.cos(angle), y: center.y + ((b.y - a.y) / 2) * Math.sin(angle) }; });
    return projectGroundPoints(vertices, plane, time) ?? [];
  }
  if (tool === "zone" && pose.length === 2) {
    const a = worldPoint(plane, first, time), b = worldPoint(plane, last, time);
    if (!a || !b) return [];
    return projectGroundPoints([a, { x: b.x, y: a.y }, b], plane, time) ?? [];
  }
  return pose.slice();
}
