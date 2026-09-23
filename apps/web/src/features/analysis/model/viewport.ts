import type { Point, Rect } from "@/domain/geometry";
import { rectMaxX, rectMaxY, rectMidX, rectMidY } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { opacityAt, pointsAt } from "./annotation";

/* Port of AnnotationViewport.swift and FieldPlacementViewport. One source-space zoom drives the
   workspace, sequence preview and export. */

/** Affine transform `[a, b, c, d, tx, ty]` in canvas order. */
export type Affine = readonly [number, number, number, number, number, number];
export const AFFINE_IDENTITY: Affine = [1, 0, 0, 1, 0, 0];

export const applyAffine = (t: Affine, p: Point): Point => ({ x: t[0] * p.x + t[2] * p.y + t[4], y: t[1] * p.x + t[3] * p.y + t[5] });
export function applyAffineRect(t: Affine, r: Rect): Rect {
  const a = applyAffine(t, { x: r.x, y: r.y }), b = applyAffine(t, { x: rectMaxX(r), y: rectMaxY(r) });
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) };
}
export function concatAffine(first: Affine, second: Affine): Affine {
  // Apply `first` then `second`.
  return [
    second[0] * first[0] + second[2] * first[1], second[1] * first[0] + second[3] * first[1],
    second[0] * first[2] + second[2] * first[3], second[1] * first[2] + second[3] * first[3],
    second[0] * first[4] + second[2] * first[5] + second[4], second[1] * first[4] + second[3] * first[5] + second[5],
  ];
}
export function invertAffine(t: Affine): Affine {
  const det = t[0] * t[3] - t[1] * t[2] || 1e-12;
  return [t[3] / det, -t[1] / det, -t[2] / det, t[0] / det, (t[2] * t[5] - t[3] * t[4]) / det, (t[1] * t[4] - t[0] * t[5]) / det];
}

/** Largest rect with the given aspect ratio inside `bounds`, centred (port of `AVMakeRect`). */
export function fitRect(aspect: number, bounds: Rect): Rect {
  const width = Math.min(bounds.width, bounds.height * aspect), height = width / aspect;
  return { x: bounds.x + (bounds.width - width) / 2, y: bounds.y + (bounds.height - height) / 2, width, height };
}

export function sourcePoint(point: Point, frame: Rect, allowsOffscreen = false): Point {
  const x = (point.x - frame.x) / Math.max(1, frame.width), y = (point.y - frame.y) / Math.max(1, frame.height);
  return allowsOffscreen ? { x, y } : { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
}
export const framePoint = (point: Point, frame: Rect): Point => ({ x: frame.x + point.x * frame.width, y: frame.y + point.y * frame.height });

/** Inspection is only a viewport change; it must never alter drawing geometry. */
export function inspectionCenter(center: Point, zoom: number): Point {
  const inset = 0.5 / Math.max(1, zoom);
  return { x: Math.min(1 - inset, Math.max(inset, center.x)), y: Math.min(1 - inset, Math.max(inset, center.y)) };
}

export interface InspectionViewport { zoom: number; center: Point }
export const DEFAULT_INSPECTION: InspectionViewport = { zoom: 1, center: { x: 0.5, y: 0.5 } };

export function viewportFrame(viewport: InspectionViewport, fitted: Rect): Rect {
  return { x: rectMidX(fitted) - fitted.width * viewport.zoom * viewport.center.x, y: rectMidY(fitted) - fitted.height * viewport.zoom * viewport.center.y, width: fitted.width * viewport.zoom, height: fitted.height * viewport.zoom };
}

/** Two-finger pinch/pan anchored under the fingers (port of `FieldPlacementViewport.navigating`). */
export function navigateViewport(viewport: InspectionViewport, scale: number, start: Point, current: Point, fitted: Rect): InspectionViewport {
  if (!Number.isFinite(scale) || scale <= 0 || fitted.width <= 0 || fitted.height <= 0) return viewport;
  const anchor = sourcePoint(start, viewportFrame(viewport, fitted), true);
  const zoom = Math.min(8, Math.max(0.25, viewport.zoom * scale));
  return { zoom, center: { x: anchor.x + (rectMidX(fitted) - current.x) / (fitted.width * zoom), y: anchor.y + (rectMidY(fitted) - current.y) / (fitted.height * zoom) } };
}

/** Apply inspection outside authored effects, so their focus cannot cancel a pan. */
export function inspectionTransform(fitted: Rect, zoom: number, center: Point): Affine {
  const viewport = viewportFrame({ zoom, center }, fitted);
  return [zoom, 0, 0, zoom, viewport.x - fitted.x * zoom, viewport.y - fitted.y * zoom];
}

/** Timed zoom: topmost active zoom layer wins; ramps ease in/out; pan interpolates with the zoom. */
export function zoomTransform(marks: readonly AnalysisAnnotation[], time: number, frame: Rect, bounds: Rect): Affine {
  let mark: AnalysisAnnotation | undefined;
  for (let i = marks.length - 1; i >= 0; i--) { const m = marks[i]!; if (m.tool === "zoom" && opacityAt(m, time) > 0) { mark = m; break; } }
  if (!mark) return AFFINE_IDENTITY;
  const focus = pointsAt(mark, time)[0];
  if (!focus || !Number.isFinite(focus.x) || !Number.isFinite(focus.y)) return AFFINE_IDENTITY;
  const ramp = Math.min(Math.max(0, mark.zoomRamp ?? 0.35), (mark.end - mark.start) / 2);
  const fraction = ramp > 0 ? Math.min(1, Math.max(0, Math.min(time - mark.start, mark.end - time) / ramp)) : 1;
  const eased = fraction * fraction * (3 - 2 * fraction);
  const targetScale = Math.min(4, Math.max(1, mark.zoomScale ?? 2));
  const scale = 1 + (targetScale - 1) * eased;
  const vx = Math.max(frame.x, bounds.x), vy = Math.max(frame.y, bounds.y);
  const vmaxX = Math.min(rectMaxX(frame), rectMaxX(bounds)), vmaxY = Math.min(rectMaxY(frame), rectMaxY(bounds));
  if (vmaxX <= vx || vmaxY <= vy) return AFFINE_IDENTITY;
  const x = frame.x + Math.min(1, Math.max(0, focus.x)) * frame.width, y = frame.y + Math.min(1, Math.max(0, focus.y)) * frame.height;
  const tx = Math.min(vx - frame.x * targetScale, Math.max(vmaxX - rectMaxX(frame) * targetScale, (vx + vmaxX) / 2 - x * targetScale));
  const ty = Math.min(vy - frame.y * targetScale, Math.max(vmaxY - rectMaxY(frame) * targetScale, (vy + vmaxY) / 2 - y * targetScale));
  return [scale, 0, 0, scale, tx * eased, ty * eased];
}
