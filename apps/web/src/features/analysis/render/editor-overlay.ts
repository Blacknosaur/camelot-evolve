import type { Point, Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import { editHandles, isActiveInEditor, type ConnectionAnchor } from "../model/annotation";
import { applyAffineRect, invertAffine, zoomTransform } from "../model/viewport";
import { intersectRects, mapPoint, mapRect, roundedRectPath, type Ctx } from "./canvas";

/* Editor-only chrome drawn above the annotations: detected players, the selected player box,
   handles, the zoom crop guide, construction points and connection anchors. Never exported. */

const SIGNAL = "rgb(209, 255, 64)";
const ORANGE = "rgb(255, 149, 0)";

export interface EditorOverlayOptions {
  frame: Rect;
  bounds: Rect;
  time: number;
  ground: GroundCalibration | null;
  selected: AnalysisAnnotation | null;
  detections: readonly Rect[];
  selectedPlayer: Rect | null;
  constructionPoints: readonly Point[];
  anchors: readonly ConnectionAnchor[];
  correctingAnchor: number | null;
}

export function drawEditorOverlay(ctx: Ctx, o: EditorOverlayOptions) {
  ctx.save();
  ctx.lineWidth = 1;
  ctx.strokeStyle = "rgba(255,255,255,0.65)";
  for (const box of o.detections) { const r = mapRect(box, o.frame); ctx.strokeRect(r.x, r.y, r.width, r.height); }
  if (o.selectedPlayer) {
    const r = mapRect(o.selectedPlayer, o.frame);
    ctx.strokeStyle = SIGNAL; ctx.lineWidth = 2; ctx.strokeRect(r.x - 3, r.y - 3, r.width + 6, r.height + 6);
  }
  const selected = o.selected;
  if (selected && selected.isLocked !== true && selected.isHidden !== true && isActiveInEditor(selected, o.time)) {
    if (selected.tool === "zoom") {
      const transform = zoomTransform([selected], (selected.start + selected.end) / 2, o.frame, o.bounds);
      const visible = intersectRects(o.frame, o.bounds);
      if (visible) {
        const crop = applyAffineRect(invertAffine(transform), visible);
        ctx.strokeStyle = SIGNAL; ctx.lineWidth = 1.5; ctx.setLineDash([6, 4]);
        ctx.strokeRect(crop.x, crop.y, crop.width, crop.height); ctx.setLineDash([]);
      }
    }
    ctx.fillStyle = "#fff"; ctx.strokeStyle = "#000"; ctx.lineWidth = 2;
    const handles = selected.linkedPlayers ? [] : editHandles(selected, o.time, o.ground);
    for (const point of handles) {
      const p = mapPoint(point, o.frame);
      ctx.beginPath(); ctx.arc(p.x, p.y, 6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    }
  }
  drawConstruction(ctx, o.constructionPoints, o.frame);
  drawAnchors(ctx, o.anchors, o.correctingAnchor, o.frame);
  ctx.restore();
}

/** Screen-sized markers stay visible before a polygon or connection has enough points to render. */
export function drawConstruction(ctx: Ctx, points: readonly Point[], frame: Rect) {
  ctx.save();
  ctx.font = "700 12px -apple-system, Helvetica, Arial, sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
  points.forEach((point, index) => {
    const centre = mapPoint(point, frame), radius = index === 0 ? 13 : 10;
    ctx.shadowBlur = 4; ctx.shadowColor = "#000";
    ctx.fillStyle = index === 0 ? SIGNAL : "#fff"; ctx.strokeStyle = "#000"; ctx.lineWidth = 2.5;
    ctx.beginPath(); ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.shadowBlur = 0;
    ctx.fillStyle = "#000"; ctx.fillText(String(index + 1), centre.x, centre.y);
    if (index === 0) {
      const label = "START", width = ctx.measureText(label).width;
      const x = Math.min(frame.x + frame.width - width - 8, Math.max(frame.x + 4, centre.x - width / 2));
      const y = centre.y - 34 < frame.y ? centre.y + 17 : centre.y - 34;
      ctx.fillStyle = SIGNAL; ctx.fill(roundedRectPath({ x: x - 3, y: y - 2, width: width + 6, height: 18 }, 4));
      ctx.fillStyle = "#000"; ctx.textAlign = "left"; ctx.fillText(label, x, y + 7); ctx.textAlign = "center";
    }
  });
  ctx.restore();
}

/** Editor-only identity markers. Missing positions are explicitly historical. */
export function drawAnchors(ctx: Ctx, anchors: readonly ConnectionAnchor[], correcting: number | null, frame: Rect) {
  ctx.save();
  ctx.textAlign = "center"; ctx.textBaseline = "middle";
  for (const anchor of anchors) {
    if (!anchor.point) continue;
    const center = mapPoint(anchor.point, frame), active = correcting === anchor.id;
    const color = active || anchor.isMissing ? ORANGE : SIGNAL;
    ctx.fillStyle = "rgba(0,0,0,0.85)"; ctx.beginPath(); ctx.arc(center.x, center.y, 13, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = color; ctx.lineWidth = active ? 3 : 2;
    ctx.setLineDash(anchor.isMissing ? [3, 2] : []);
    ctx.beginPath(); ctx.arc(center.x, center.y, 13, 0, Math.PI * 2); ctx.stroke(); ctx.setLineDash([]);
    ctx.font = "700 13px -apple-system, Helvetica, Arial, sans-serif"; ctx.fillStyle = color; ctx.fillText(String(anchor.id + 1), center.x, center.y);
    if (anchor.isMissing) {
      ctx.font = "700 8px -apple-system, Helvetica, Arial, sans-serif";
      const label = "LAST SEEN", width = ctx.measureText(label).width;
      ctx.fillStyle = "rgba(0,0,0,0.8)"; ctx.fillRect(center.x - width / 2 - 2, center.y + 15, width + 4, 11);
      ctx.fillStyle = ORANGE; ctx.fillText(label, center.x, center.y + 20.5);
    }
  }
  ctx.restore();
}
