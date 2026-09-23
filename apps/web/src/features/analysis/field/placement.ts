/* Field placement interaction: ports of FieldPointNudge, FieldPlacementViewport and FieldPlacementTouchState
   (FieldPlacementInteraction.swift). All pure; the sheet feeds pointer events into `FieldPlacementTouchState`. */
import type { Point, Rect, Size } from "@/domain/geometry";

/** Source display pixels, independent of preview fit, pan, zoom or downsampling. */
export function nudgePoint(point: Point, dx: number, dy: number, sourceSize: Size): Point {
  if (!Number.isFinite(sourceSize.width) || !Number.isFinite(sourceSize.height) || !(sourceSize.width > 0) || !(sourceSize.height > 0)) return point;
  return { x: point.x + dx / sourceSize.width, y: point.y + dy / sourceSize.height };
}

/** Preview → source fraction, optionally allowing points outside the frame (offscreen landmarks stay editable). */
export function sourcePoint(point: Point, frame: Rect, allowsOffscreen = false): Point {
  const x = (point.x - frame.x) / Math.max(1e-9, frame.width), y = (point.y - frame.y) / Math.max(1e-9, frame.height);
  return allowsOffscreen ? { x, y } : { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
}

/** Inspection zoom/pan local to placement; authored corners remain in source coordinates. */
export interface PlacementViewport { zoom: number; center: Point }
export const DEFAULT_VIEWPORT: PlacementViewport = { zoom: 1, center: { x: 0.5, y: 0.5 } };

export function viewportFrame(viewport: PlacementViewport, fitted: Rect): Rect {
  const midX = fitted.x + fitted.width / 2, midY = fitted.y + fitted.height / 2;
  return { x: midX - fitted.width * viewport.zoom * viewport.center.x, y: midY - fitted.height * viewport.zoom * viewport.center.y, width: fitted.width * viewport.zoom, height: fitted.height * viewport.zoom };
}

export function navigateViewport(viewport: PlacementViewport, scale: number, from: Point, to: Point, fitted: Rect): PlacementViewport {
  if (!Number.isFinite(scale) || !(scale > 0) || !(fitted.width > 0) || !(fitted.height > 0)) return viewport;
  const anchor = sourcePoint(from, viewportFrame(viewport, fitted), true);
  const nextZoom = Math.min(8, Math.max(0.25, viewport.zoom * scale));
  const midX = fitted.x + fitted.width / 2, midY = fitted.y + fitted.height / 2;
  return { zoom: nextZoom, center: { x: anchor.x + (midX - to.x) / (fitted.width * nextZoom), y: anchor.y + (midY - to.y) / (fitted.height * nextZoom) } };
}

/** Loupe placement that stays inside `bounds` and clear of the finger. */
export function loupeCenter(finger: Point, bounds: Rect, size: Size): Point {
  const insetX = Math.min(bounds.width / 2, size.width / 2 + 8), insetY = Math.min(bounds.height / 2, size.height / 2 + 8);
  const clamp = (p: Point): Point => ({ x: Math.min(bounds.x + bounds.width - insetX, Math.max(bounds.x + insetX, p.x)), y: Math.min(bounds.y + bounds.height - insetY, Math.max(bounds.y + insetY, p.y)) });
  const candidates = [
    { x: finger.x, y: finger.y - size.height / 2 - 54 }, { x: finger.x, y: finger.y + size.height / 2 + 54 },
    { x: finger.x - size.width / 2 - 54, y: finger.y }, { x: finger.x + size.width / 2 + 54, y: finger.y },
  ].map(clamp);
  const clearance = (p: Point) => Math.hypot(Math.max(0, Math.abs(finger.x - p.x) - size.width / 2), Math.max(0, Math.abs(finger.y - p.y) - size.height / 2));
  const clear = candidates.find((c) => clearance(c) >= 40);
  if (clear) return clear;
  let best = candidates[0]!;
  for (const c of candidates) if (clearance(c) > clearance(best)) best = c;
  return best;
}

export type TouchAction =
  | { type: "beginCorner"; location: Point } | { type: "moveCorner"; location: Point } | { type: "endCorner" } | { type: "cancelCorner" }
  | { type: "beginNavigation" } | { type: "navigate"; scale: number; from: Point; to: Point } | { type: "endNavigation" };

/** One finger edits, two fingers navigate; lifting one navigation finger never places a corner. */
export class FieldPlacementTouchState {
  private mode: "idle" | "corner" | "navigation" | "waiting" = "idle";
  private navigationCenter: Point = { x: 0, y: 0 };
  private navigationDistance = 1;

  update(points: readonly Point[]): TouchAction[] {
    if (points.length > 2) { const actions = this.cancel(); this.mode = "waiting"; return actions; }
    switch (this.mode) {
      case "idle":
        if (points.length === 1) { this.mode = "corner"; return [{ type: "beginCorner", location: points[0]! }]; }
        if (points.length >= 2) { this.beginNavigation(points); return [{ type: "beginNavigation" }]; }
        return [];
      case "corner":
        if (points.length === 0) { this.mode = "idle"; return [{ type: "endCorner" }]; }
        if (points.length >= 2) { this.beginNavigation(points); return [{ type: "cancelCorner" }, { type: "beginNavigation" }]; }
        return [{ type: "moveCorner", location: points[0]! }];
      case "navigation":
        if (points.length < 2) { this.mode = points.length === 0 ? "idle" : "waiting"; return [{ type: "endNavigation" }]; }
        return [{ type: "navigate", scale: distance(points) / this.navigationDistance, from: this.navigationCenter, to: center(points) }];
      case "waiting":
        if (points.length === 0) this.mode = "idle";
        return [];
    }
  }

  cancel(): TouchAction[] {
    const mode = this.mode;
    this.mode = "idle";
    if (mode === "corner") return [{ type: "cancelCorner" }];
    if (mode === "navigation") return [{ type: "endNavigation" }];
    return [];
  }

  private beginNavigation(points: readonly Point[]) { this.mode = "navigation"; this.navigationCenter = center(points); this.navigationDistance = Math.max(1, distance(points)); }
}

const center = (points: readonly Point[]): Point => ({ x: (points[0]!.x + points[1]!.x) / 2, y: (points[0]!.y + points[1]!.y) / 2 });
const distance = (points: readonly Point[]) => Math.hypot(points[0]!.x - points[1]!.x, points[0]!.y - points[1]!.y);
