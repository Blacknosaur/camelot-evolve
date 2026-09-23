import type { Point, Rect, Size } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { supportsGrounding, isGrounded } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import { dashLengths, type AnnotationEndpoint, type AnnotationLineStyle } from "@/domain/annotation-styles";
import { hasMotion, isActiveInEditor, opacityAt, resolvedLineStyle, shapeBoundary } from "../model/annotation";
import { frozenGround, groundEffectProjection, hasPlane, imagePoint, worldPoint } from "../model/ground";
import { distanceLabels } from "../model/measurements";
import { loupeGeometryFor, loupeLensRect, type LoupeGeometry } from "../model/loupe";
import { textStyle } from "@/domain/annotation-styles";
import { toolRegistry, type ToolDrawContext } from "./toolRegistry";
import { drawAnnotationText } from "./text";
import { drawArrowHead } from "./effects";
import { clearShadow, gray, mapPoint, pathFrom, rgba, setShadow, type Ctx } from "./canvas";

/* The editor and the video compositor share this exact drawing code (port of AnnotationRenderer.swift
   plus the loupe compositing from AnalysisLoupePreview). No DOM, no React: the export worker imports it. */

export interface DrawOptions {
  /** Ground calibration for grounded effects, measurements and perspective walls. */
  ground?: GroundCalibration | null;
  /** Clip rectangle in the canvas pixel space; defaults to the frame. */
  bounds?: Rect;
  /** Pixel rectangle the source frame occupies; defaults to `{0, 0, size}` (the workspace passes a zoomed/panned frame). */
  frame?: Rect;
  /** Editing mode shows every active layer at full opacity, ignoring fades. */
  editing?: boolean;
  /** Unannotated source frame for loupes. Loupes draw only their border when absent. */
  source?: CanvasImageSource | null;
  /** Skip these tools (the loupe pass draws them separately). */
  skipLoupes?: boolean;
}

/** Draws `annotations` at `time` onto a canvas whose source frame is `size` pixels. */
export function drawAnnotations(ctx: Ctx, annotations: readonly AnalysisAnnotation[], time: number, size: Size, options: DrawOptions = {}): void {
  const frame = options.frame ?? { x: 0, y: 0, width: size.width, height: size.height };
  const bounds = options.bounds ?? frame;
  const ground = options.ground ?? null;
  const editing = options.editing === true;
  ctx.save();
  ctx.beginPath(); ctx.rect(bounds.x, bounds.y, bounds.width, bounds.height); ctx.clip();
  const groundProjection = groundEffectProjection(ground, time);
  const planeAvailable = hasPlane(ground);
  for (const mark of annotations) {
    if (mark.isHidden === true || mark.tool === "zoom") continue;
    if (mark.tool === "loupe") { if (!options.skipLoupes) drawLoupe(ctx, mark, time, frame, bounds, editing, options.source ?? null); continue; }
    if (!hasMotion(mark, time)) continue;
    const alpha = editing ? (isActiveInEditor(mark, time) ? 1 : 0) : opacityAt(mark, time);
    if (alpha <= 0) continue;
    const grounded = supportsGrounding(mark) && isGrounded(mark, planeAvailable);
    if (grounded && !groundProjection) continue;
    const points = shapeBoundary(mark, time, ground).map((p) => mapPoint(p, frame));
    const first = points[0];
    if (!first) continue;
    const last = points[points.length - 1] ?? first;
    const rect: Rect = { x: Math.min(first.x, last.x), y: Math.min(first.y, last.y), width: Math.max(2, Math.abs(last.x - first.x)), height: Math.max(2, Math.abs(last.y - first.y)) };
    const width = Math.max(1, frame.width * mark.width);
    const style = resolvedLineStyle(mark);
    ctx.save();
    const pulse = mark.effect === "pulse" ? 0.8 + 0.2 * Math.sin((time - mark.start) * 4.4) : 1;
    ctx.globalAlpha = alpha * pulse;
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.strokeStyle = rgba(mark.color); ctx.fillStyle = rgba(mark.color);
    if (mark.effect && mark.effect !== "clean") setShadow(ctx, Math.max(3, width * 2), rgba(mark.color, 0.7)); else clearShadow(ctx);
    const context: ToolDrawContext = { ctx, mark, time, frame, bounds, ground, points, rect, width, style, grounded, projection: grounded ? groundProjection : null, path: new Path2D(), strokeWidth: width };
    const definition = toolRegistry[mark.tool];
    const strokeWidth = definition.draw(context);
    if (strokeWidth != null) {
      ctx.setLineDash(dashLengths(style, strokeWidth));
      ctx.strokeStyle = gray(0, 0.5); ctx.lineWidth = strokeWidth + 2; ctx.stroke(context.path);
      ctx.strokeStyle = rgba(mark.color); ctx.lineWidth = strokeWidth; ctx.stroke(context.path);
      if (definition.endpoints) drawEndpoints(ctx, style, points, strokeWidth, rgba(mark.color), grounded && ground ? frozenGround(ground, time) : null, time, frame);
      ctx.setLineDash([]);
    }
    for (const label of distanceLabels(mark, time, ground)) {
      const text: AnalysisAnnotation = { ...mark, tool: "text", text: label.text, textStyle: textStyle({ alignment: "center", size: 0.018, weight: "bold", background: true }) };
      drawAnnotationText(ctx, text, label.text, mapPoint(label.point, frame), frame.width, true);
    }
    ctx.restore();
  }
  ctx.restore();
}

function drawEndpoints(ctx: Ctx, style: AnnotationLineStyle, points: readonly Point[], width: number, color: string, plane: GroundCalibration | null, time: number, frame: Rect) {
  if (points.length < 2) return;
  const first = points[0]!, last = points[points.length - 1]!;
  const next = points.slice(1).find((p) => Math.hypot(p.x - first.x, p.y - first.y) > 0.5) ?? last;
  const previous = [...points.slice(0, -1)].reverse().find((p) => Math.hypot(p.x - last.x, p.y - last.y) > 0.5) ?? first;
  const draw = (endpoint: AnnotationEndpoint, point: Point, other: Point) => {
    if (endpoint === "none") return;
    if (plane) { drawGroundEndpoint(ctx, endpoint, point, other, width, color, plane, time, frame); return; }
    const radius = Math.max(3, width * 1.8);
    ctx.save(); ctx.setLineDash([]); ctx.fillStyle = color; ctx.strokeStyle = color; ctx.lineWidth = width;
    switch (endpoint) {
      case "point": ctx.beginPath(); ctx.arc(point.x, point.y, radius * 0.55, 0, Math.PI * 2); ctx.fill(); break;
      case "circle": ctx.beginPath(); ctx.arc(point.x, point.y, radius, 0, Math.PI * 2); ctx.stroke(); break;
      case "arrow": drawArrowHead(ctx, point, other, Math.max(width * 4, 12)); break;
    }
    ctx.restore();
  };
  draw(style.start, first, next); draw(style.end, last, previous);
}

function drawGroundEndpoint(ctx: Ctx, endpoint: AnnotationEndpoint, point: Point, other: Point, width: number, color: string, plane: GroundCalibration, time: number, frame: Rect) {
  const normalized = (p: Point) => ({ x: (p.x - frame.x) / frame.width, y: (p.y - frame.y) / frame.height });
  const radius = Math.max(3, width * 1.8);
  const center = worldPoint(plane, normalized(point), time), neighbor = worldPoint(plane, normalized(other), time), edge = worldPoint(plane, normalized({ x: point.x + radius, y: point.y }), time);
  if (!center || !neighbor || !edge) return;
  const meters = Math.hypot(edge.x - center.x, edge.y - center.y);
  let world: Point[];
  if (endpoint === "arrow") {
    const angle = Math.atan2(center.y - neighbor.y, center.x - neighbor.x), head = meters * Math.max(width * 4, 12) / radius;
    world = [{ x: center.x - Math.cos(angle - 0.5) * head, y: center.y - Math.sin(angle - 0.5) * head }, center, { x: center.x - Math.cos(angle + 0.5) * head, y: center.y - Math.sin(angle + 0.5) * head }];
  } else {
    const r = meters * (endpoint === "point" ? 0.55 : 1);
    world = Array.from({ length: 48 }, (_, i) => { const angle = i * 2 * Math.PI / 48; return { x: center.x + Math.cos(angle) * r, y: center.y + Math.sin(angle) * r }; });
  }
  const vertices: Point[] = [];
  for (const w of world) { const p = imagePoint(plane, w, time); if (!p) return; vertices.push(mapPoint(p, frame)); }
  ctx.save(); ctx.setLineDash([]); ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = width;
  const path = pathFrom(vertices, endpoint !== "arrow");
  if (endpoint === "point") ctx.fill(path); else ctx.stroke(path);
  ctx.restore();
}

/** Composites a lens from the unannotated source (never from earlier drawings, to avoid recursion). */
function drawLoupe(ctx: Ctx, mark: AnalysisAnnotation, time: number, frame: Rect, bounds: Rect, editing: boolean, source: CanvasImageSource | null) {
  const geometry = loupeGeometryFor(mark, time, frame, bounds);
  if (!geometry) return;
  const alpha = editing ? (isActiveInEditor(mark, time) ? 1 : 0) : opacityAt(mark, time);
  if (alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha = alpha;
  const lens = loupeLensRect(geometry);
  if (source) {
    ctx.save();
    ctx.beginPath(); ctx.ellipse(geometry.center.x, geometry.center.y, geometry.radius, geometry.radius, 0, 0, Math.PI * 2); ctx.clip();
    ctx.fillStyle = "#000"; ctx.fillRect(lens.x, lens.y, lens.width, lens.height);
    ctx.translate(geometry.center.x, geometry.center.y);
    const zoom = geometry.radius / geometry.sourceRadius;
    ctx.scale(zoom, zoom);
    ctx.translate(-geometry.focus.x, -geometry.focus.y);
    try { ctx.drawImage(source, frame.x, frame.y, frame.width, frame.height); } catch { /* source not decodable yet */ }
    ctx.restore();
  }
  drawLoupeBorder(ctx, geometry);
  ctx.restore();
}

export function drawLoupeBorder(ctx: Ctx, geometry: LoupeGeometry) {
  ctx.save();
  ctx.lineCap = "round";
  ctx.lineWidth = Math.max(2, geometry.radius * 0.035); ctx.strokeStyle = gray(1, 0.92);
  ctx.beginPath(); ctx.ellipse(geometry.center.x, geometry.center.y, geometry.radius, geometry.radius, 0, 0, Math.PI * 2); ctx.stroke();
  ctx.lineWidth = Math.max(1, geometry.radius * 0.012); ctx.strokeStyle = gray(0, 0.8);
  const dx = geometry.center.x - geometry.focus.x, dy = geometry.center.y - geometry.focus.y, distance = Math.max(0.001, Math.hypot(dx, dy));
  if (distance > geometry.radius) {
    ctx.beginPath(); ctx.moveTo(geometry.focus.x, geometry.focus.y);
    ctx.lineTo(geometry.center.x - dx / distance * geometry.radius, geometry.center.y - dy / distance * geometry.radius); ctx.stroke();
  }
  ctx.restore();
}
