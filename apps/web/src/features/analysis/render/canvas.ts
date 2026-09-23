import type { Point, Rect } from "@/domain/geometry";
import type { AnnotationColor } from "@/domain/annotation";

/* Small Canvas 2D helpers shared by the renderer. `Ctx` covers both the DOM and the offscreen
   context so the export worker can reuse every drawing routine. */

export type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export const rgba = (c: AnnotationColor, alpha = 1) => `rgba(${Math.round(c.red * 255)}, ${Math.round(c.green * 255)}, ${Math.round(c.blue * 255)}, ${alpha})`;
export const gray = (value: number, alpha = 1) => `rgba(${Math.round(value * 255)}, ${Math.round(value * 255)}, ${Math.round(value * 255)}, ${alpha})`;

export const mapPoint = (p: Point, frame: Rect): Point => ({ x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height });
export const mapRect = (r: Rect, frame: Rect): Rect => ({ x: frame.x + r.x * frame.width, y: frame.y + r.y * frame.height, width: r.width * frame.width, height: r.height * frame.height });
export const insetRect = (r: Rect, dx: number, dy: number): Rect => ({ x: r.x + dx, y: r.y + dy, width: r.width - dx * 2, height: r.height - dy * 2 });
export const rectMaxX = (r: Rect) => r.x + r.width;
export const rectMaxY = (r: Rect) => r.y + r.height;
export const rectMidX = (r: Rect) => r.x + r.width / 2;
export const rectMidY = (r: Rect) => r.y + r.height / 2;

export function polyline(ctx: Ctx, points: readonly Point[], closed = false) {
  const first = points[0];
  if (!first) return;
  ctx.moveTo(first.x, first.y);
  for (let i = 1; i < points.length; i++) ctx.lineTo(points[i]!.x, points[i]!.y);
  if (closed) ctx.closePath();
}

export function pathFrom(points: readonly Point[], closed = false): Path2D {
  const path = new Path2D();
  const first = points[0];
  if (!first) return path;
  path.moveTo(first.x, first.y);
  for (let i = 1; i < points.length; i++) path.lineTo(points[i]!.x, points[i]!.y);
  if (closed) path.closePath();
  return path;
}

export function ellipsePath(rect: Rect): Path2D {
  const path = new Path2D();
  path.ellipse(rectMidX(rect), rectMidY(rect), Math.max(0.01, rect.width / 2), Math.max(0.01, rect.height / 2), 0, 0, Math.PI * 2);
  return path;
}

export function roundedRectPath(rect: Rect, radius: number): Path2D {
  const path = new Path2D();
  const r = Math.max(0, Math.min(radius, rect.width / 2, rect.height / 2));
  path.roundRect(rect.x, rect.y, rect.width, rect.height, r);
  return path;
}

export function boundingBox(points: readonly Point[]): Rect {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of points) { minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
  return points.length ? { x: minX, y: minY, width: maxX - minX, height: maxY - minY } : { x: 0, y: 0, width: 0, height: 0 };
}

export function linearGradient(ctx: Ctx, start: Point, end: Point, stops: [number, string][]): CanvasGradient {
  const gradient = ctx.createLinearGradient(start.x, start.y, end.x, end.y);
  for (const [offset, color] of stops) gradient.addColorStop(Math.min(1, Math.max(0, offset)), color);
  return gradient;
}

export function clearShadow(ctx: Ctx) { ctx.shadowBlur = 0; ctx.shadowColor = "rgba(0,0,0,0)"; ctx.shadowOffsetX = 0; ctx.shadowOffsetY = 0; }
export function setShadow(ctx: Ctx, blur: number, color: string, offsetX = 0, offsetY = 0) { ctx.shadowBlur = blur; ctx.shadowColor = color; ctx.shadowOffsetX = offsetX; ctx.shadowOffsetY = offsetY; }

export const intersectRects = (a: Rect, b: Rect): Rect | null => {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y), maxX = Math.min(rectMaxX(a), rectMaxX(b)), maxY = Math.min(rectMaxY(a), rectMaxY(b));
  return maxX > x && maxY > y ? { x, y, width: maxX - x, height: maxY - y } : null;
};
