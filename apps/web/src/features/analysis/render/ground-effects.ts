import type { Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import { groundCircle, hasPlane } from "../model/ground";
import { playerMarkerPath } from "./effects";
import { boundingBox, gray, linearGradient, pathFrom, rectMaxY, rectMidX, rgba, type Ctx } from "./canvas";

/** Ground-plane footprints share calibration across all player effects (port of GroundPlayerEffects).
 *  Returns false when the effect must fall back to the screen-space drawing. */
export function drawGroundPlayerEffect(ctx: Ctx, mark: AnalysisAnnotation, rect: Rect, time: number, ground: GroundCalibration | null, frame: Rect, width: number): boolean {
  if (!hasPlane(ground) || frame.width <= 0 || frame.height <= 0) return false;
  const feet = { x: (rectMidX(rect) - frame.x) / frame.width, y: (rectMaxY(rect) - frame.y) / frame.height };
  const pulse = mark.effect === "pulse" ? 1 + Math.sin((time - mark.start) * 4.4) * 0.1 : 1;
  const ring = groundCircle(ground, feet, 0.6 * pulse, time);
  if (!ring || ring.length === 0) return false;
  const points = ring.map((p) => ({ x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height }));
  const path = pathFrom(points, true), bounds = boundingBox(points);
  if (bounds.width >= frame.width * 0.4 || bounds.height >= frame.height * 0.4) return false;
  if (mark.tool === "spotlight" && (mark.effect ?? "clean") === "clean") {
    const shade = new Path2D();
    shade.rect(frame.x, frame.y, frame.width, frame.height);
    shade.ellipse(rectMidX(rect), rect.y + rect.height / 2, rect.width * 0.75, rect.height * 0.58, 0, 0, Math.PI * 2);
    ctx.fillStyle = gray(0, 0.5); ctx.fill(shade, "evenodd");
  } else if (mark.tool === "spotlight" || mark.effect === "radar") {
    const top = mark.tool === "spotlight" ? frame.y : rect.y;
    ctx.save();
    ctx.clip(pathFrom([{ x: rectMidX(rect) - rect.width * 0.2, y: top }, { x: rectMidX(rect) + rect.width * 0.2, y: top }, { x: bounds.x + bounds.width, y: rectMaxY(rect) }, { x: bounds.x, y: rectMaxY(rect) }], true));
    ctx.fillStyle = linearGradient(ctx, { x: rectMidX(rect), y: top }, { x: rectMidX(rect), y: rectMaxY(rect) }, [[0, rgba(mark.color, 0.02)], [1, rgba(mark.color, 0.25)]]);
    ctx.fillRect(frame.x, frame.y, frame.width, frame.height);
    ctx.restore();
  }
  ctx.fillStyle = rgba(mark.color, 0.16); ctx.fill(path);
  ctx.strokeStyle = rgba(mark.color); ctx.lineWidth = Math.max(1, Math.min(width, bounds.width * 0.04));
  ctx.stroke(path);
  if (mark.tool === "player" && (mark.effect ?? "clean") !== "clean") {
    const phase = Math.floor(Math.max(0, time - mark.start) * 12) % points.length;
    ctx.lineWidth = Math.max(1.5, Math.min(width * 0.6, bounds.width * 0.06));
    for (let section = 0; section < 3; section++) {
      ctx.beginPath();
      const start = points[(phase + section * 10) % points.length]!;
      ctx.moveTo(start.x, start.y);
      for (let i = 1; i <= 5; i++) { const p = points[(phase + section * 10 + i) % points.length]!; ctx.lineTo(p.x, p.y); }
      ctx.stroke();
    }
    ctx.fillStyle = rgba(mark.color); ctx.fill(playerMarkerPath(rect, mark, time));
  }
  return true;
}
