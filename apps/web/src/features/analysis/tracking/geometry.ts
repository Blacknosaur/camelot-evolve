/* Rect and 3×3 matrix helpers shared by tracking and field geometry. All coordinates are fractions of
   the display frame. Matrices are row-major `number[9]` (the `CameraTransform.values` layout). */
import type { Point, Rect } from "@/domain/geometry";
import type { CameraTransform } from "@/domain/tracking";

export type Mat3 = [number, number, number, number, number, number, number, number, number];
const asMat3 = (values: readonly number[]): Mat3 => [values[0] ?? 0, values[1] ?? 0, values[2] ?? 0, values[3] ?? 0, values[4] ?? 0, values[5] ?? 0, values[6] ?? 0, values[7] ?? 0, values[8] ?? 0];
export { asMat3 };

export const rectMinX = (r: Rect) => r.x;
export const rectMinY = (r: Rect) => r.y;
export const rectMaxX = (r: Rect) => r.x + r.width;
export const rectMaxY = (r: Rect) => r.y + r.height;
export const rectMidX = (r: Rect) => r.x + r.width / 2;
export const rectMidY = (r: Rect) => r.y + r.height / 2;
export const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });
export const offsetRect = (r: Rect, dx: number, dy: number): Rect => ({ x: r.x + dx, y: r.y + dy, width: r.width, height: r.height });
export const insetRect = (r: Rect, dx: number, dy: number): Rect => ({ x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy });
export const rectsEqual = (a: Rect, b: Rect) => a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
export const feet = (r: Rect): Point => ({ x: rectMidX(r), y: rectMaxY(r) });
/** Rect from a feet point and size (feet at the bottom centre). */
export const rectFromFeet = (feet: Point, width: number, height: number): Rect => ({ x: feet.x - width / 2, y: feet.y - height, width, height });
export const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t });
export const UNIT_RECT: Rect = { x: 0, y: 0, width: 1, height: 1 };

export function intersectRects(a: Rect, b: Rect): Rect | null {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  const maxX = Math.min(rectMaxX(a), rectMaxX(b)), maxY = Math.min(rectMaxY(a), rectMaxY(b));
  if (maxX <= x || maxY <= y) return null;
  return { x, y, width: maxX - x, height: maxY - y };
}
export const rectsIntersect = (a: Rect, b: Rect) => intersectRects(a, b) !== null;

/** Intersection over union (`PlayerTracker.overlap`). */
export function overlap(a: Rect, b: Rect): number {
  const i = intersectRects(a, b);
  if (!i) return 0;
  const union = a.width * a.height + b.width * b.height - i.width * i.height;
  return union > 0 ? (i.width * i.height) / union : 0;
}

export const hypot = Math.hypot;
export const isFinitePoint = (p: Point) => Number.isFinite(p.x) && Number.isFinite(p.y);

// MARK: - Matrices (row-major)

export const IDENTITY3: Mat3 = [1, 0, 0, 0, 1, 0, 0, 0, 1];

export function mat3Multiply(a: Mat3, b: Mat3): Mat3 {
  return [
    a[0] * b[0] + a[1] * b[3] + a[2] * b[6], a[0] * b[1] + a[1] * b[4] + a[2] * b[7], a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
    a[3] * b[0] + a[4] * b[3] + a[5] * b[6], a[3] * b[1] + a[4] * b[4] + a[5] * b[7], a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
    a[6] * b[0] + a[7] * b[3] + a[8] * b[6], a[6] * b[1] + a[7] * b[4] + a[8] * b[7], a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
  ];
}

export function mat3Determinant(m: Mat3): number {
  return m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
}

export function mat3Inverse(m: Mat3): Mat3 | null {
  const det = mat3Determinant(m);
  if (!Number.isFinite(det) || Math.abs(det) < 1e-300) return null;
  const inv: Mat3 = [
    m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
    m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
    m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
  ];
  return mat3Scale(inv, 1 / det);
}

export const mat3Transpose = (m: Mat3): Mat3 => [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
export const mat3Scale = (m: Mat3, s: number): Mat3 => asMat3(m.map((v) => v * s));
export const mat3Apply = (m: Mat3, v: [number, number, number]): [number, number, number] => [
  m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2], m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
];

/** Projects a point through a homography; null when the point is at infinity or non-finite. */
export function mat3Point(m: Mat3, p: Point): Point | null {
  const [x, y, z] = mat3Apply(m, [p.x, p.y, 1]);
  if (!Number.isFinite(z) || Math.abs(z) <= 0.0001) return null;
  const px = x / z, py = y / z;
  return Number.isFinite(px) && Number.isFinite(py) ? { x: px, y: py } : null;
}

// MARK: - CameraTransform helpers (port of `CameraTransform`)

export const cameraMatrix = (t: CameraTransform): Mat3 => (t.values.length === 9 ? asMat3(t.values) : IDENTITY3);
export const cameraFromMatrix = (m: Mat3): CameraTransform => ({ values: m.slice() });
export const cameraPoint = (t: CameraTransform, p: Point): Point | null => (t.values.length === 9 ? mat3Point(asMat3(t.values), p) : null);
export const cameraDeterminant = (t: CameraTransform) => mat3Determinant(cameraMatrix(t));
/** `current * previous⁻¹`: the motion between two absolute poses. */
export function relativeCamera(from: CameraTransform, to: CameraTransform): CameraTransform | null {
  const inverse = mat3Inverse(cameraMatrix(from));
  if (!inverse || Math.abs(cameraDeterminant(from)) <= 0.00001) return null;
  return cameraFromMatrix(mat3Multiply(cameraMatrix(to), inverse));
}
export const cameraIsFinite = (t: CameraTransform) => t.values.length === 9 && t.values.every(Number.isFinite);

/** Lower-bound binary search: first index whose `key` is >= value. */
export function lowerBound<T>(items: readonly T[], value: number, key: (item: T) => number): number {
  let low = 0, high = items.length;
  while (low < high) { const mid = (low + high) >> 1; if (key(items[mid]!) < value) low = mid + 1; else high = mid; }
  return low;
}

/** Swift `Double.nextUp` / `nextDown` on the 1e-9 scale used by the tracking code. */
export const nextUp = (v: number) => v + Math.max(Number.EPSILON * Math.abs(v), Number.MIN_VALUE) * 4;
export const nextDown = (v: number) => v - Math.max(Number.EPSILON * Math.abs(v), Number.MIN_VALUE) * 4;
