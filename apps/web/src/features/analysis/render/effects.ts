import type { Point, Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { dashLengths, DEFAULT_LINE_STYLE, type AnnotationEndpoint, type AnnotationLineStyle } from "@/domain/annotation-styles";
import { effectBodyBox, overheadHeight } from "@/features/analysis/tracking/motion";
import { displayPlayerMotion } from "../model/annotation";
import { convexHull } from "../model/geometry";
import { raisedPoint, type GroundEffectProjection } from "../model/ground";
import { boundingBox, clearShadow, gray, linearGradient, pathFrom, polyline, rectMaxY, rectMidX, rgba, type Ctx } from "./canvas";

/* Port of GameAnnotationEffects.swift. Time-driven effects use source seconds so paused frames,
   scrubbing and exports produce the same animation without a display timer. */

export function playerMarkerPath(rect: Rect, mark: AnalysisAnnotation, time: number): Path2D {
  let height = rect.height, bodyWidth = rect.width;
  const motion = displayPlayerMotion(mark);
  const body = motion ? effectBodyBox(motion, time) : null, average = motion ? overheadHeight(motion, time) : null;
  if (body && average != null && body.height > 0) { const scale = average / body.height; height *= scale; bodyWidth *= scale; }
  const marker = Math.max(6, bodyWidth * 0.24);
  const y = rectMaxY(rect) - height - marker * 1.5;
  return pathFrom([{ x: rectMidX(rect) - marker, y: y - marker }, { x: rectMidX(rect) + marker, y: y - marker }, { x: rectMidX(rect), y }], true);
}

/** A screen-space light curtain anchored to the evaluated ground points. */
export function drawWall(ctx: Ctx, points: readonly Point[], closed: boolean, mark: AnalysisAnnotation, time: number, frame: Rect, width: number, projection: GroundEffectProjection | null) {
  if (points.length < 2) return;
  const edges: [Point, Point][] = [];
  for (let i = 0; i + 1 < points.length; i++) edges.push([points[i]!, points[i + 1]!]);
  if (closed) edges.push([points[points.length - 1]!, points[0]!]);
  edges.sort((a, b) => a[0].y + a[1].y - (b[0].y + b[1].y));
  const height = frame.height * Math.min(0.5, Math.max(0.02, mark.wallHeight ?? 0.18));
  const opacity = Math.min(0.8, Math.max(0.05, mark.wallOpacity ?? 0.32));
  const top = (point: Point): Point | null => {
    if (projection) {
      const raised = raisedPoint(projection, { x: (point.x - frame.x) / frame.width, y: (point.y - frame.y) / frame.height }, mark.wallHeightMeters ?? 2);
      return raised ? { x: frame.x + raised.x * frame.width, y: frame.y + raised.y * frame.height } : null;
    }
    const depth = Math.min(1, Math.max(0, (point.y - frame.y) / Math.max(1, frame.height)));
    return { x: point.x, y: point.y - height * (0.55 + depth * 0.45) };
  };
  ctx.save();
  clearShadow(ctx);
  for (const [a, b] of edges) {
    if (Math.hypot(a.x - b.x, a.y - b.y) <= 0.5) continue;
    const upA = top(a), upB = top(b);
    if (!upA || !upB) continue;
    ctx.save();
    ctx.clip(pathFrom([a, b, upB, upA], true));
    const gradient = linearGradient(ctx, { x: (a.x + b.x) / 2, y: Math.min(upA.y, upB.y) }, { x: (a.x + b.x) / 2, y: Math.max(a.y, b.y) }, [[0, rgba(mark.color, 0.015)], [1, rgba(mark.color, opacity)]]);
    ctx.fillStyle = gradient;
    ctx.fillRect(frame.x - frame.width, frame.y - frame.height, frame.width * 3, frame.height * 3);
    ctx.restore();
    ctx.lineWidth = Math.max(1, width * 0.22);
    ctx.strokeStyle = rgba(mark.color, 0.55);
    ctx.beginPath(); polyline(ctx, [upA, a, b, upB]); ctx.stroke();
    // Subtle rising light band; deterministic during scrubbing/export.
    const phase = (Math.max(0, time - mark.start) / 2) % 1;
    ctx.strokeStyle = rgba(mark.color, (1 - phase) * 0.5);
    ctx.beginPath(); ctx.moveTo(a.x, a.y + (upA.y - a.y) * phase); ctx.lineTo(b.x, b.y + (upB.y - b.y) * phase); ctx.stroke();
  }
  ctx.restore();
}

export function drawSpotlightEffect(ctx: Ctx, rect: Rect, frame: Rect, mark: AnalysisAnnotation, width: number) {
  const radius = Math.max(9, rect.width * 0.8);
  const feet = { x: rectMidX(rect), y: rectMaxY(rect) };
  ctx.save();
  ctx.clip(pathFrom([{ x: feet.x - radius * 0.35, y: frame.y }, { x: feet.x + radius * 0.35, y: frame.y }, { x: feet.x + radius, y: feet.y }, { x: feet.x - radius, y: feet.y }], true));
  ctx.fillStyle = linearGradient(ctx, { x: feet.x, y: frame.y }, feet, [[0, rgba(mark.color, 0.04)], [1, rgba(mark.color, 0.28)]]);
  ctx.fillRect(frame.x - frame.width, frame.y - frame.height, frame.width * 3, frame.height * 3);
  ctx.restore();
  const halo = { x: feet.x - radius, y: feet.y - radius * 0.22, width: radius * 2, height: radius * 0.44 };
  ctx.fillStyle = rgba(mark.color, 0.2);
  ctx.beginPath(); ctx.ellipse(feet.x, feet.y, radius, radius * 0.22, 0, 0, Math.PI * 2); ctx.fill();
  ctx.lineWidth = Math.max(1.5, Math.min(width, radius * 0.1));
  ctx.beginPath(); ctx.ellipse(feet.x, halo.y + halo.height / 2, radius, radius * 0.22, 0, 0, Math.PI * 2); ctx.stroke();
}

export function drawPlayerEffect(ctx: Ctx, rect: Rect, mark: AnalysisAnnotation, time: number, width: number) {
  const phase = (time - mark.start) * 2.2;
  const pulse = mark.effect === "pulse" ? 1 + Math.sin(phase * 2) * 0.1 : 1;
  const radius = Math.max(9, rect.width * 0.78) * pulse;
  const feet = { x: rectMidX(rect), y: rectMaxY(rect) };
  ctx.fillStyle = rgba(mark.color, 0.13);
  ctx.beginPath(); ctx.ellipse(feet.x, feet.y, radius, radius * 0.25, 0, 0, Math.PI * 2); ctx.fill();
  ctx.lineWidth = Math.max(1.5, Math.min(width, radius * 0.1));
  ctx.beginPath(); ctx.ellipse(feet.x, feet.y, radius, radius * 0.25, 0, 0, Math.PI * 2); ctx.stroke();
  ctx.save();
  ctx.translate(feet.x, feet.y); ctx.scale(1, 0.25);
  for (let index = 0; index < 3; index++) {
    const angle = phase + index * Math.PI * 2 / 3;
    ctx.beginPath(); ctx.arc(0, 0, radius * 1.18, angle, angle + 1.25); ctx.stroke();
  }
  ctx.restore();
  // Stable overhead marker; ring animation must not bob the player label.
  const marker = Math.max(6, rect.width * 0.24);
  ctx.fillStyle = rgba(mark.color);
  ctx.fill(playerMarkerPath(rect, mark, time));
  if (mark.effect === "radar") {
    ctx.save();
    ctx.clip(pathFrom([{ x: feet.x - radius, y: feet.y }, { x: feet.x - radius * 0.25, y: rect.y - marker }, { x: feet.x + radius * 0.25, y: rect.y - marker }, { x: feet.x + radius, y: feet.y }], true));
    ctx.fillStyle = linearGradient(ctx, { x: feet.x, y: rect.y }, feet, [[0, rgba(mark.color, 0.02)], [1, rgba(mark.color, 0.2)]]);
    ctx.fillRect(feet.x - radius * 2, rect.y - marker - radius, radius * 4, radius * 2 + rect.height + marker);
    ctx.restore();
  }
}

export function drawArea(ctx: Ctx, input: readonly Point[], mark: AnalysisAnnotation, time: number, width: number, style: AnnotationLineStyle = DEFAULT_LINE_STYLE) {
  const points = mark.linkedPlayers ? convexHull(input) : [...input];
  if (points.length < 3) return;
  const path = pathFrom(points, true);
  ctx.fillStyle = rgba(mark.color, mark.areaFill ?? 0.18);
  ctx.fill(path);
  const stroke = Math.max(1.5, width * 0.5);
  ctx.lineWidth = stroke;
  ctx.setLineDash(dashLengths(style, stroke));
  ctx.stroke(path);
  ctx.setLineDash([]);
  if ((mark.effect ?? "clean") !== "clean") {
    ctx.save();
    ctx.clip(path);
    clearShadow(ctx);
    ctx.strokeStyle = rgba(mark.color, 0.2);
    ctx.lineWidth = Math.max(0.5, width * 0.16);
    const box = boundingBox(points), spacing = Math.max(12, box.width / 12);
    ctx.beginPath();
    let x = box.x - box.height, count = 0;
    while (x < box.x + box.width && count < 256) { ctx.moveTo(x, box.y + box.height); ctx.lineTo(x + box.height, box.y); x += spacing; count += 1; }
    ctx.stroke();
    ctx.restore();
    if (!mark.lineStyle) {
      ctx.setLineDash([8, 12]); ctx.lineDashOffset = -(time - mark.start) * 24;
      ctx.stroke(path);
      ctx.setLineDash([]); ctx.lineDashOffset = 0;
    }
  }
}

export function drawConnection(ctx: Ctx, points: readonly Point[], mark: AnalysisAnnotation, time: number, width: number, style: AnnotationLineStyle = DEFAULT_LINE_STYLE) {
  if (points.length < 2) return;
  const path = pathFrom(points);
  const stroke = Math.max(1, width * 0.45);
  ctx.lineWidth = stroke;
  if (!mark.lineStyle) { ctx.strokeStyle = rgba(mark.color, 0.45); ctx.stroke(path); }
  ctx.strokeStyle = rgba(mark.color);
  if (style.pattern !== "solid") ctx.setLineDash(dashLengths(style, stroke));
  if ((mark.effect ?? "clean") !== "clean" && !mark.lineStyle && style.pattern === "solid") { ctx.setLineDash([10, 8]); ctx.lineDashOffset = -(time - mark.start) * 32; }
  ctx.stroke(path);
  ctx.setLineDash([]); ctx.lineDashOffset = 0;
  drawConnectionEndpoints(ctx, style, points, width, rgba(mark.color));
  if ((mark.effect ?? "clean") !== "clean") {
    const t = ((time - mark.start) % 1.6 + 1.6) % 1.6 / 1.6;
    ctx.fillStyle = gray(1, 0.95);
    for (let i = 0; i + 1 < points.length; i++) {
      const a = points[i]!, b = points[i + 1]!;
      const radius = Math.max(2, width * 0.55);
      ctx.beginPath(); ctx.arc(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, radius, 0, Math.PI * 2); ctx.fill();
    }
  }
}

function drawConnectionEndpoints(ctx: Ctx, style: AnnotationLineStyle, points: readonly Point[], width: number, color: string) {
  const first = points[0], last = points[points.length - 1];
  if (!first || !last) return;
  const draw = (endpoint: AnnotationEndpoint, point: Point, other: Point) => {
    const radius = Math.max(4, width * 1.6);
    ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = Math.max(1, width * 0.45);
    switch (endpoint) {
      case "circle": ctx.beginPath(); ctx.ellipse(point.x, point.y, radius, radius * 0.55, 0, 0, Math.PI * 2); ctx.stroke(); break;
      case "point": ctx.beginPath(); ctx.arc(point.x, point.y, radius * 0.45, 0, Math.PI * 2); ctx.fill(); break;
      case "arrow": drawArrowHead(ctx, point, other, Math.max(width * 4, 12)); break;
      case "none": break;
    }
  };
  draw(style.start, first, points.slice(1).find((p) => p.x !== first.x || p.y !== first.y) ?? last);
  draw(style.end, last, [...points.slice(0, -1)].reverse().find((p) => p.x !== last.x || p.y !== last.y) ?? first);
}

export function drawArrowHead(ctx: Ctx, point: Point, other: Point, head: number) {
  const angle = Math.atan2(point.y - other.y, point.x - other.x);
  ctx.beginPath();
  ctx.moveTo(point.x, point.y); ctx.lineTo(point.x - Math.cos(angle - 0.5) * head, point.y - Math.sin(angle - 0.5) * head);
  ctx.moveTo(point.x, point.y); ctx.lineTo(point.x - Math.cos(angle + 0.5) * head, point.y - Math.sin(angle + 0.5) * head);
  ctx.stroke();
}

/** Aerial tactical treatment: translucent ground plane, soft contact shadow and elevated roof edges. */
export function drawAerial(ctx: Ctx, input: readonly Point[], mark: AnalysisAnnotation, time: number, frame: Rect, width: number, projection: GroundEffectProjection | null) {
  if (input.length < 3) return;
  const vertices = mark.linkedPlayers ? convexHull(input) : [...input];
  const ground = pathFrom(vertices, true);
  ctx.save(); ctx.clip(ground);
  ctx.fillStyle = rgba(mark.color, Math.min(0.3, Math.max(0.06, mark.areaFill ?? 0.14)));
  ctx.fillRect(frame.x, frame.y, frame.width, frame.height);
  ctx.restore();
  ctx.save();
  ctx.shadowOffsetX = 0; ctx.shadowOffsetY = Math.max(2, frame.height * 0.012); ctx.shadowBlur = Math.max(4, frame.width * 0.018); ctx.shadowColor = gray(0, 0.26);
  ctx.fillStyle = gray(0, 0.16); ctx.fill(ground);
  ctx.restore();
  const height = frame.height * Math.min(0.5, Math.max(0.02, mark.wallHeight ?? 0.18));
  const opacity = Math.min(0.8, Math.max(0.05, mark.wallOpacity ?? 0.32));
  const roofWidth = Math.max(1.5, width * 0.45);
  const raised = (point: Point): Point | null => {
    if (projection) {
      const top = raisedPoint(projection, { x: (point.x - frame.x) / frame.width, y: (point.y - frame.y) / frame.height }, mark.wallHeightMeters ?? 2);
      return top ? { x: frame.x + top.x * frame.width, y: frame.y + top.y * frame.height } : null;
    }
    return { x: point.x, y: point.y - height * 0.65 };
  };
  ctx.save();
  ctx.lineCap = "round"; ctx.lineJoin = "round";
  ctx.setLineDash([roofWidth * 5, roofWidth * 4]); ctx.lineDashOffset = -(time - mark.start) * 10;
  ctx.lineWidth = roofWidth; ctx.strokeStyle = rgba(mark.color, opacity);
  for (let i = 0; i < vertices.length; i++) {
    const a = vertices[i]!, b = vertices[(i + 1) % vertices.length]!;
    const upA = raised(a), upB = raised(b);
    if (!upA || !upB) continue;
    ctx.beginPath(); ctx.moveTo(upA.x, upA.y);
    if (projection) ctx.lineTo(upB.x, upB.y);
    else ctx.quadraticCurveTo((upA.x + upB.x) / 2, Math.min(upA.y, upB.y) - height * 0.18, upB.x, upB.y);
    ctx.stroke();
  }
  ctx.setLineDash([]); ctx.lineDashOffset = 0;
  ctx.restore();
}
