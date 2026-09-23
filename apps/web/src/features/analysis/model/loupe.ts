import type { Point, Rect } from "@/domain/geometry";
import { rectMaxX, rectMaxY } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { DEFAULT_LOUPE_STYLE, type AnnotationLoupeStyle } from "@/domain/annotation-styles";
import { hasMotion, opacityAt, pointsAt } from "./annotation";

/* Port of AnnotationLoupeGeometry (AnnotationLoupe.swift). Pixel units of the drawing surface. */

export interface LoupeGeometry { focus: Point; center: Point; radius: number; sourceRadius: number }
export const loupeLensRect = (g: LoupeGeometry): Rect => ({ x: g.center.x - g.radius, y: g.center.y - g.radius, width: g.radius * 2, height: g.radius * 2 });

export function loupeGeometry(style: AnnotationLoupeStyle, focus: Point, frame: Rect, bounds: Rect): LoupeGeometry | null {
  if (frame.width <= 0 || frame.height <= 0 || bounds.width <= 0 || bounds.height <= 0) return null;
  if (![focus.x, focus.y, style.diameter, style.magnification, style.offset.x, style.offset.y].every(Number.isFinite)) return null;
  const diameter = Math.min(1, Math.max(0.02, style.diameter)) * frame.width;
  const radius = Math.min(diameter, Math.min(bounds.width, bounds.height)) / 2;
  const raw = { x: focus.x + style.offset.x * frame.width, y: focus.y + style.offset.y * frame.height };
  const center = { x: Math.min(rectMaxX(bounds) - radius, Math.max(bounds.x + radius, raw.x)), y: Math.min(rectMaxY(bounds) - radius, Math.max(bounds.y + radius, raw.y)) };
  return { focus, center, radius, sourceRadius: radius / Math.min(20, Math.max(1, style.magnification)) };
}

export function loupeGeometryFor(mark: AnalysisAnnotation, time: number, frame: Rect, bounds: Rect): LoupeGeometry | null {
  if (mark.tool !== "loupe" || opacityAt(mark, time) <= 0 || !hasMotion(mark, time)) return null;
  const focus = pointsAt(mark, time)[0];
  if (!focus) return null;
  return loupeGeometry(mark.loupeStyle ?? DEFAULT_LOUPE_STYLE, { x: frame.x + focus.x * frame.width, y: frame.y + focus.y * frame.height }, frame, bounds);
}
