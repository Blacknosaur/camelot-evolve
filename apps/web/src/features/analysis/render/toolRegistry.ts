import type { Point, Rect } from "@/domain/geometry";
import type { AnalysisAnnotation, AnalysisDrawingTool } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import type { AnnotationLineStyle } from "@/domain/annotation-styles";
import { editHandles, handleIndexAt, hitTest } from "../model/annotation";
import type { GroundEffectProjection } from "../model/ground";
import { fieldGuidePolylines } from "../model/ground";
import { measurementText } from "../model/measurements";
import { resolvedTextStyle } from "../model/annotation";
import { convexHull as convexHullPoints } from "../model/geometry";
import { drawTrajectory } from "./trajectory";
import { drawAnnotationText } from "./text";
import { drawAerial, drawArea, drawConnection, drawPlayerEffect, drawSpotlightEffect, drawWall } from "./effects";
import { drawGroundPlayerEffect } from "./ground-effects";
import { ellipsePath, gray, pathFrom, rectMaxY, rgba, type Ctx } from "./canvas";

/* One registry entry per drawing tool. The overlay, renderer and inspector all consult it, so a
   new tool is one new entry here (plus its inspector in workspace/toolInspectors.tsx), never a
   switch case in the overlay. Everything in this file is DOM-free so the export worker can use it. */

/** How the pointer creates a layer of this tool. */
export type ToolCreation = "tap" | "drag" | "path" | "construction" | "none";

export interface ToolDrawContext {
  ctx: Ctx;
  mark: AnalysisAnnotation;
  time: number;
  /** Pixel rectangle of the source frame. */
  frame: Rect;
  /** Clip rectangle in the same pixel space. */
  bounds: Rect;
  ground: GroundCalibration | null;
  /** Shape boundary mapped to pixels. */
  points: Point[];
  /** Bounding rect of the first and last point (Swift `rect`). */
  rect: Rect;
  /** Stroke width in pixels for `mark.width`. */
  width: number;
  style: AnnotationLineStyle;
  grounded: boolean;
  projection: GroundEffectProjection | null;
  /** Path the common loop strokes (outline + colour) after the tool draws. */
  path: Path2D;
  /** Override the common stroke width (player ring). */
  strokeWidth: number;
}

export interface ToolDefinition {
  tool: AnalysisDrawingTool;
  title: string;
  /** Keyboard shortcut (single key). */
  shortcut?: string;
  /** Icon key resolved by the workspace icon set. */
  icon: string;
  creation: ToolCreation;
  /** Defaults applied to new layers. */
  defaults: Partial<AnalysisAnnotation>;
  /** Draw into the context; return the stroke width to use for the common stroke (or null to skip it). */
  draw(context: ToolDrawContext): number | null;
  /** Editable handles in normalised coordinates. */
  handles(mark: AnalysisAnnotation, time: number, ground: GroundCalibration | null): Point[];
  /** Whether the common loop draws line endpoints (arrows, circles, points). */
  endpoints: boolean;
  /** Which effects the Style inspector offers. */
  effects(mark: AnalysisAnnotation): readonly AnalysisAnnotation["effect"][];
  /** The tool supports a `lineStyle` (pattern + endpoints). */
  lineStyle: boolean;
  /** Included in the Tools sheet. Spotlight and trajectory are created from the Player panel. */
  inToolbar: boolean;
}

const rectFrom = (first: Point, last: Point): Rect => ({ x: Math.min(first.x, last.x), y: Math.min(first.y, last.y), width: Math.max(2, Math.abs(last.x - first.x)), height: Math.max(2, Math.abs(last.y - first.y)) });
const CLEAN_NEON_PULSE = ["clean", "neon", "pulse"] as const;

const definitions: ToolDefinition[] = [
  {
    tool: "select", title: "Select", shortcut: "v", icon: "cursor", creation: "none", defaults: {}, endpoints: false, lineStyle: false, inToolbar: true,
    draw: () => null, handles: () => [], effects: () => CLEAN_NEON_PULSE,
  },
  {
    tool: "player", title: "Player", shortcut: "p", icon: "figure", creation: "tap", defaults: { effect: "radar" }, endpoints: false, lineStyle: false, inToolbar: true,
    effects: () => ["clean", "neon", "pulse", "radar"],
    handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) {
      if (drawGroundPlayerEffect(c.ctx, c.mark, c.rect, c.time, c.grounded ? c.ground : null, c.frame, c.width)) return null;
      if (c.mark.effect && c.mark.effect !== "clean") { drawPlayerEffect(c.ctx, c.rect, c.mark, c.time, c.width); return null; }
      const ring = { x: c.rect.x - c.rect.width * 0.2, y: rectMaxY(c.rect) - c.rect.width * 0.2, width: c.rect.width * 1.4, height: Math.max(8, c.rect.width * 0.4) };
      c.ctx.fillStyle = rgba(c.mark.color, 0.22);
      c.ctx.fill(ellipsePath(ring));
      c.path.addPath(ellipsePath(ring));
      return Math.min(c.width, ring.height * 0.2);
    },
  },
  {
    tool: "spotlight", title: "Spotlight", icon: "beacon", creation: "tap", defaults: { effect: "neon" }, endpoints: false, lineStyle: false, inToolbar: false,
    effects: () => CLEAN_NEON_PULSE,
    handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) {
      if (drawGroundPlayerEffect(c.ctx, c.mark, c.rect, c.time, c.grounded ? c.ground : null, c.frame, c.width)) return null;
      if (c.mark.effect && c.mark.effect !== "clean") { drawSpotlightEffect(c.ctx, c.rect, c.frame, c.mark, c.width); return null; }
      const shade = new Path2D();
      shade.rect(c.frame.x, c.frame.y, c.frame.width, c.frame.height);
      shade.addPath(ellipsePath({ x: c.rect.x - c.rect.width * 0.25, y: c.rect.y - c.rect.height * 0.08, width: c.rect.width * 1.5, height: c.rect.height * 1.16 }));
      c.ctx.fillStyle = gray(0, 0.5);
      c.ctx.fill(shade, "evenodd");
      c.path.addPath(ellipsePath({ x: c.rect.x, y: rectMaxY(c.rect) - c.rect.width * 0.15, width: c.rect.width, height: c.rect.width * 0.3 }));
      return c.width;
    },
  },
  {
    tool: "pen", title: "Pen", shortcut: "e", icon: "pencil", creation: "path", defaults: {}, endpoints: true, lineStyle: true, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: () => [],
    draw(c) {
      c.path.addPath(pathFrom(c.points));
      const first = c.points[0]!;
      if (c.points.length === 1) c.path.addPath(ellipsePath({ x: first.x - c.width / 2, y: first.y - c.width / 2, width: c.width, height: c.width }));
      return c.width;
    },
  },
  {
    tool: "arrow", title: "Arrow", shortcut: "a", icon: "arrow", creation: "drag", defaults: {}, endpoints: true, lineStyle: true, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) { const first = c.points[0]!, last = c.points[c.points.length - 1]!; c.path.moveTo(first.x, first.y); c.path.lineTo(last.x, last.y); return c.width; },
  },
  {
    tool: "line", title: "Line", shortcut: "l", icon: "line", creation: "drag", defaults: {}, endpoints: true, lineStyle: true, inToolbar: true,
    effects: (mark) => (mark.fieldLines !== true ? ["clean", "neon", "pulse", "wall"] : CLEAN_NEON_PULSE),
    handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) {
      const first = c.points[0]!, last = c.points[c.points.length - 1]!;
      if (c.mark.effect === "wall") drawWall(c.ctx, c.points, false, c.mark, c.time, c.frame, c.width, c.projection);
      c.path.moveTo(first.x, first.y); c.path.lineTo(last.x, last.y);
      return c.width;
    },
  },
  {
    tool: "ellipse", title: "Circle", shortcut: "c", icon: "circle", creation: "drag", defaults: {}, endpoints: false, lineStyle: true, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) { if (c.grounded) c.path.addPath(pathFrom(c.points, true)); else c.path.addPath(ellipsePath(c.rect)); return c.width; },
  },
  {
    tool: "rectangle", title: "Rectangle", shortcut: "r", icon: "rectangle", creation: "drag", defaults: {}, endpoints: false, lineStyle: true, inToolbar: true,
    effects: (mark) => (mark.fieldLines !== true ? ["clean", "neon", "pulse", "wall", "aerial"] : CLEAN_NEON_PULSE),
    handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) {
      const corners = c.grounded ? c.points : [{ x: c.rect.x, y: c.rect.y }, { x: c.rect.x + c.rect.width, y: c.rect.y }, { x: c.rect.x + c.rect.width, y: rectMaxY(c.rect) }, { x: c.rect.x, y: rectMaxY(c.rect) }];
      c.path.addPath(pathFrom(corners, true));
      if (c.mark.effect === "wall") drawWall(c.ctx, corners, true, c.mark, c.time, c.frame, c.width, c.projection);
      if (c.mark.effect === "aerial") drawAerial(c.ctx, corners, c.mark, c.time, c.frame, c.width, c.projection);
      return c.width;
    },
  },
  {
    tool: "zone", title: "Polygon", shortcut: "g", icon: "pentagon", creation: "construction", defaults: { effect: "neon" }, endpoints: false, lineStyle: true, inToolbar: true,
    effects: (mark) => (mark.fieldLines !== true ? ["clean", "neon", "pulse", "wall", "aerial"] : CLEAN_NEON_PULSE),
    handles: (mark, time, ground) => editHandles(mark, time, ground),
    draw(c) {
      if (c.mark.fieldLines === true) {
        for (const line of fieldGuidePolylines(c.points.map((p) => ({ x: (p.x - c.frame.x) / c.frame.width, y: (p.y - c.frame.y) / c.frame.height })), c.mark.fieldLayout)) {
          c.path.addPath(pathFrom(line.map((p) => ({ x: c.frame.x + p.x * c.frame.width, y: c.frame.y + p.y * c.frame.height }))));
        }
        return c.width;
      }
      const first = c.points[0]!, last = c.points[c.points.length - 1]!;
      // Two-point legacy areas retain their original triangle.
      const vertices = c.points.length >= 3 ? c.points : [first, { x: last.x, y: first.y }, last];
      if (c.mark.effect === "aerial") drawAerial(c.ctx, vertices, c.mark, c.time, c.frame, c.width, c.projection);
      else drawArea(c.ctx, vertices, c.mark, c.time, c.width, c.style);
      if (c.mark.effect === "wall") drawWall(c.ctx, c.mark.linkedPlayers ? convexHullPoints(vertices) : vertices, true, c.mark, c.time, c.frame, c.width, c.projection);
      return c.width;
    },
  },
  {
    tool: "text", title: "Text", shortcut: "t", icon: "text", creation: "tap", defaults: { text: "Text" }, endpoints: false, lineStyle: false, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: (mark, time) => editHandles(mark, time),
    draw(c) {
      const first = c.points[0]!;
      drawAnnotationText(c.ctx, c.mark, measurementText(c.mark, c.time, c.ground), first, c.frame.width, resolvedTextStyle(c.mark).background);
      return null;
    },
  },
  {
    tool: "connection", title: "Connect", shortcut: "n", icon: "connect", creation: "construction", defaults: { effect: "neon" }, endpoints: false, lineStyle: true, inToolbar: true,
    effects: (mark) => (mark.fieldLines !== true ? ["clean", "neon", "pulse", "wall"] : CLEAN_NEON_PULSE),
    handles: (mark, time, ground) => (mark.linkedPlayers ? [] : editHandles(mark, time, ground)),
    draw(c) {
      drawConnection(c.ctx, c.points, c.mark, c.time, c.width, c.style);
      if (c.mark.effect === "wall") drawWall(c.ctx, c.points, false, c.mark, c.time, c.frame, c.width, c.projection);
      return c.width;
    },
  },
  {
    tool: "loupe", title: "Loupe", shortcut: "m", icon: "loupe", creation: "tap", defaults: {}, endpoints: false, lineStyle: false, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: (mark, time) => editHandles(mark, time), draw: () => null,
  },
  {
    tool: "zoom", title: "Zoom", shortcut: "z", icon: "zoom", creation: "tap", defaults: { zoomScale: 2, zoomRamp: 0.35 }, endpoints: false, lineStyle: false, inToolbar: true,
    effects: () => CLEAN_NEON_PULSE, handles: (mark, time) => editHandles(mark, time), draw: () => null,
  },
  {
    tool: "trajectory", title: "Trajectory", icon: "trail", creation: "none", defaults: { effect: "clean" }, endpoints: false, lineStyle: false, inToolbar: false,
    effects: () => ["clean"], handles: () => [],
    draw(c) { drawTrajectory(c.ctx, c.mark, c.time, c.frame); return null; },
  },
];


export const toolRegistry: Readonly<Record<AnalysisDrawingTool, ToolDefinition>> = Object.fromEntries(definitions.map((d) => [d.tool, d])) as Record<AnalysisDrawingTool, ToolDefinition>;
export const toolbarTools = definitions.filter((d) => d.inToolbar).map((d) => d.tool);
export const toolForShortcut = (key: string): AnalysisDrawingTool | null => definitions.find((d) => d.shortcut === key.toLowerCase())?.tool ?? null;
export { rectFrom, hitTest, handleIndexAt };
