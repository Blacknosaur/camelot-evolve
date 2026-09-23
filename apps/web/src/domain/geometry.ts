/** Fractions of the source display frame (0…1) unless stated otherwise. */
export interface Point { x: number; y: number }
export interface Size { width: number; height: number }
export interface Rect { x: number; y: number; width: number; height: number }

export const point = (x: number, y: number): Point => ({ x, y });
export const rectMidX = (r: Rect) => r.x + r.width / 2;
export const rectMidY = (r: Rect) => r.y + r.height / 2;
export const rectMaxX = (r: Rect) => r.x + r.width;
export const rectMaxY = (r: Rect) => r.y + r.height;
export const rectCenter = (r: Rect): Point => ({ x: rectMidX(r), y: rectMidY(r) });
export const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const lerpPoint = (a: Point, b: Point, t: number): Point => ({ x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) });
export const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));
export const pointsEqual = (a: Point, b: Point, epsilon = 1e-9) => Math.abs(a.x - b.x) < epsilon && Math.abs(a.y - b.y) < epsilon;
export const boundingRect = (points: readonly Point[]): Rect | null => {
  if (points.length === 0) return null;
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of points) { minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
};
