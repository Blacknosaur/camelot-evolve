/* Perspective circle reference: port of GroundCircleReference.swift. The conic is a symmetric 3×3 matrix stored
   row-major; `anchors` recovers the four plane anchors (goal side, near, opposite, far) from the observed conic,
   the corrected centre and the halfway direction. */
import type { Point, Size } from "@/domain/geometry";
import type { GroundCircleReference } from "@/domain/ground";
import type { CameraTransform } from "@/domain/tracking";
import { cameraMatrix, cameraPoint, isFinitePoint, mat3Apply, mat3Inverse, mat3Multiply, mat3Transpose, type Mat3 } from "../tracking/geometry";
import { calibrationCorners } from "./overlay";
import { fieldProjection } from "./projection";

type Vec3 = [number, number, number];
const cross = (a: Vec3, b: Vec3): Vec3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

const conicMatrix = (c: GroundCircleReference): Mat3 => [c.conic[0] ?? 0, c.conic[1] ?? 0, c.conic[2] ?? 0, c.conic[3] ?? 0, c.conic[4] ?? 0, c.conic[5] ?? 0, c.conic[6] ?? 0, c.conic[7] ?? 0, c.conic[8] ?? 0];

/** Points where an image line `[a, b, c]` crosses the conic, or null when it misses. */
export function circleIntersections(c: GroundCircleReference, line: Vec3): Point[] | null {
  if (c.conic.length !== 9) return null;
  const norm = Math.hypot(line[0], line[1]);
  if (!(norm > 1e-12)) return null;
  const p: Vec3 = [(-line[0] * line[2]) / (norm * norm), (-line[1] * line[2]) / (norm * norm), 1];
  const d: Vec3 = [-line[1] / norm, line[0] / norm, 0], e = conicMatrix(c);
  const a = dot(d, mat3Apply(e, d)), b = 2 * dot(p, mat3Apply(e, d)), cc = dot(p, mat3Apply(e, p));
  const discriminant = b * b - 4 * a * cc;
  if (!(a > 1e-12) || !(discriminant > 1e-12)) return null;
  return [-1, 1].map((sign) => { const t = (-b + sign * Math.sqrt(discriminant)) / (2 * a); return { x: p[0] + t * d[0], y: p[1] + t * d[1] }; });
}

/** Recover the true centre from the two circle crossings and the far touchline via their cross-ratio. */
export function circleCenterFromTouchline(c: GroundCircleReference, pitchWidth: number, diameter: number): Point | null {
  const far = c.farTouchline;
  if (!far || far.length !== 2 || c.halfway.length !== 2 || !Number.isFinite(pitchWidth) || !Number.isFinite(diameter) || !(diameter > 0) || !(pitchWidth > diameter)) return null;
  const line = (points: Point[]): Vec3 => cross([points[0]!.x, points[0]!.y, 1], [points[1]!.x, points[1]!.y, 1]);
  const half = line(c.halfway), touch = line(far), intersection = cross(half, touch);
  if (!(Math.abs(intersection[2]) > 1e-10)) return null;
  const crossings = circleIntersections(c, half);
  if (!crossings) return null;
  const sorted = crossings.slice().sort((a, b) => a.y - b.y), farPoint = sorted[0]!, nearPoint = sorted[1]!;
  const dx = nearPoint.x - farPoint.x, dy = nearPoint.y - farPoint.y, norm = dx * dx + dy * dy;
  if (!(norm > 1e-8)) return null;
  const tx = intersection[0] / intersection[2], ty = intersection[1] / intersection[2];
  const observed = ((tx - farPoint.x) * dx + (ty - farPoint.y) * dy) / norm;
  const world = 0.5 - pitchWidth / (2 * diameter);
  if (!(observed < -0.02)) return null;
  const k = (world - observed) / (world * (observed - 1));
  const position = (k + 1) / (k + 2);
  if (!Number.isFinite(position) || !(position > 0.05) || !(position < 0.95)) return null;
  return { x: farPoint.x + position * dx, y: farPoint.y + position * dy };
}

/** The four plane anchors (goal side, near, opposite, far) implied by the conic, centre and halfway direction. */
export function circleAnchors(c: GroundCircleReference): Point[] | null {
  if (c.conic.length !== 9 || !c.conic.every(Number.isFinite) || c.halfway.length !== 2 || !isFinitePoint(c.center)) return null;
  const centre: Vec3 = [c.center.x, c.center.y, 1], e = conicMatrix(c);
  if (!(dot(centre, mat3Apply(e, centre)) < -1e-9)) return null;
  const direction = { x: c.halfway[1]!.x - c.halfway[0]!.x, y: c.halfway[1]!.y - c.halfway[0]!.y };
  if (!(Math.hypot(direction.x, direction.y) > 0.01)) return null;
  const line: Vec3 = [-direction.y, direction.x, direction.y * centre[0] - direction.x * centre[1]];
  const vanishing = mat3Apply(e, centre);
  const v = cross(line, vanishing);
  const perpendicular = mat3Apply(e, v);
  const across = circleIntersections(c, line), along = circleIntersections(c, perpendicular);
  if (!across || !along) return null;
  const nearFar = across.slice().sort((a, b) => a.y - b.y), leftRight = along.slice().sort((a, b) => a.x - b.x);
  const result = [leftRight[0]!, nearFar[1]!, leftRight[1]!, nearFar[0]!];
  return calibrationCorners(result, "centreCircle").length === 4 ? result : null;
}

/** Re-express the reference after a camera warp. */
export function circleTransformed(c: GroundCircleReference, transform: CameraTransform): GroundCircleReference | null {
  const anchors = circleAnchors(c), center = cameraPoint(transform, c.center);
  if (c.conic.length !== 9 || !anchors || !center) return null;
  const h = cameraMatrix(transform), inverse = mat3Inverse(h);
  if (!inverse) return null;
  const e = mat3Multiply(mat3Multiply(mat3Transpose(inverse), conicMatrix(c)), inverse);
  const halfway = [anchors[3]!, anchors[1]!].flatMap((p) => { const q = cameraPoint(transform, p); return q ? [q] : []; });
  const result: GroundCircleReference = { ...c, conic: e.slice(), center, halfway, farTouchline: c.farTouchline?.flatMap((p) => { const q = cameraPoint(transform, p); return q ? [q] : []; }) };
  return circleAnchors(result) ? result : null;
}

/** Largest overlay displacement for a one-pixel centre perturbation; a stability warning, not an error bound. */
export function circlePixelSensitivity(c: GroundCircleReference, imageSize: Size): number | null {
  if (!(imageSize.width > 0) || !(imageSize.height > 0)) return null;
  const anchors = circleAnchors(c);
  const original = anchors ? fieldProjection(calibrationCorners(anchors, "centreCircle")) : null;
  if (!anchors || !original) return null;
  let maximum = 0;
  for (const offset of [{ x: 1, y: 0 }, { x: -1, y: 0 }, { x: 0, y: 1 }, { x: 0, y: -1 }]) {
    const changed: GroundCircleReference = { ...c, center: { x: c.center.x + offset.x / imageSize.width, y: c.center.y + offset.y / imageSize.height } };
    const adjusted = circleAnchors(changed);
    const projection = adjusted ? fieldProjection(calibrationCorners(adjusted, "centreCircle")) : null;
    if (!projection) return Infinity;
    for (let x = -2; x <= 3; x++) for (let y = -2; y <= 3; y++) {
      const a = cameraPoint(original, { x, y });
      if (!a || a.x < 0 || a.x > 1 || a.y < 0 || a.y > 1) continue;
      const b = cameraPoint(projection, { x, y });
      if (!b) return Infinity;
      maximum = Math.max(maximum, Math.hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height));
    }
  }
  return maximum;
}

/** Fit a projective conic to all observed outline samples (robust least squares), not four ellipse extrema. */
export function fitCircleReference(outline: readonly Point[], halfway: Point[], imageSize: Size): GroundCircleReference | null {
  if (outline.length < 24 || halfway.length !== 2 || !(imageSize.width > 0) || !(imageSize.height > 0)) return null;
  const n = outline.length;
  const cx = outline.reduce((a, p) => a + p.x, 0) / n, cy = outline.reduce((a, p) => a + p.y, 0) / n;
  const sx = Math.sqrt(outline.reduce((a, p) => a + (p.x - cx) ** 2, 0) / n), sy = Math.sqrt(outline.reduce((a, p) => a + (p.y - cy) ** 2, 0) / n);
  if (!(sx > 0.02) || !(sy > 0.003)) return null;
  const normalized = outline.map((p) => ({ x: (p.x - cx) / sx, y: (p.y - cy) / sy }));
  let accepted = normalized, coefficients: number[] = [];
  for (let round = 0; round < 3; round++) {
    const rows = accepted.map((p) => [p.x * p.x, 2 * p.x * p.y, p.y * p.y, 2 * p.x, 2 * p.y]);
    const solution = solveConic(rows);
    if (!solution) return null;
    coefficients = solution;
    const errors = normalized.map((p) => {
      const value = solution[0]! * p.x * p.x + 2 * solution[1]! * p.x * p.y + solution[2]! * p.y * p.y + 2 * solution[3]! * p.x + 2 * solution[4]! * p.y - 1;
      const dx = 2 * (solution[0]! * p.x + solution[1]! * p.y + solution[3]!), dy = 2 * (solution[1]! * p.x + solution[2]! * p.y + solution[4]!);
      return Math.abs(value) / Math.max(1e-9, Math.hypot(dx, dy));
    });
    const cutoff = Math.max(0.025, errors.slice().sort((a, b) => a - b)[errors.length >> 1]! * 3);
    accepted = normalized.filter((_, i) => errors[i]! <= cutoff);
    if (accepted.length < Math.floor((normalized.length * 2) / 3)) return null;
  }
  const q = coefficients as [number, number, number, number, number];
  if (!(q[0] > 0) || !(q[2] > 0) || !(q[0] * q[2] - q[1] * q[1] > 1e-8)) return null;
  const local: Mat3 = [q[0], q[1], q[3], q[1], q[2], q[4], q[3], q[4], -1];
  const normalization: Mat3 = [1 / sx, 0, -cx / sx, 0, 1 / sy, -cy / sy, 0, 0, 1];
  const e = mat3Multiply(mat3Multiply(mat3Transpose(normalization), local), normalization);
  const determinant = q[0] * q[2] - q[1] * q[1];
  const center = { x: cx + (sx * (q[1] * q[4] - q[2] * q[3])) / determinant, y: cy + (sy * (q[1] * q[3] - q[0] * q[4])) / determinant };
  const errors = outline.map((p) => {
    const v: Vec3 = [p.x, p.y, 1], ev = mat3Apply(e, v);
    return Math.abs(dot(v, ev)) / Math.max(1e-9, 2 * Math.hypot(ev[0] / imageSize.width, ev[1] / imageSize.height));
  }).sort((a, b) => a - b);
  const residual = errors[Math.floor((errors.length * 3) / 4)]!;
  if (!(residual < 4)) return null;
  const result: GroundCircleReference = { conic: e.slice(), center, halfway, outlineErrorPixels: residual };
  return circleAnchors(result) ? result : null;
}

function solveConic(rows: number[][]): number[] | null {
  const system: number[][] = Array.from({ length: 5 }, () => new Array<number>(6).fill(0));
  for (const row of rows) for (let i = 0; i < 5; i++) { for (let j = 0; j < 5; j++) system[i]![j]! += row[i]! * row[j]!; system[i]![5]! += row[i]!; }
  for (let i = 0; i < 5; i++) {
    let pivot = i;
    for (let r = i + 1; r < 5; r++) if (Math.abs(system[r]![i]!) > Math.abs(system[pivot]![i]!)) pivot = r;
    if (!(Math.abs(system[pivot]![i]!) > 1e-9)) return null;
    [system[i], system[pivot]] = [system[pivot]!, system[i]!];
    const divisor = system[i]![i]!;
    for (let j = i; j <= 5; j++) system[i]![j]! /= divisor;
    for (let k = 0; k < 5; k++) { if (k === i) continue; const factor = system[k]![i]!; for (let j = i; j <= 5; j++) system[k]![j]! -= factor * system[i]![j]!; }
  }
  return system.map((row) => row[5]!);
}
