import type { Point, Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { resolvedTextStyle, textPixelSize } from "../model/annotation";
import { gray, rgba, roundedRectPath, setShadow, clearShadow, type Ctx } from "./canvas";

/* Port of AnnotationTextLayout: shared metrics for rendering and hit testing, including
   multiline alignment. The anchor is the first point; lines stack downward from the baseline. */

export interface TextLine { text: string; origin: Point }
export interface TextLayout { lines: TextLine[]; bounds: Rect; font: string; size: number }

export function fontFor(mark: AnalysisAnnotation, frameWidth: number): { font: string; size: number } {
  const style = resolvedTextStyle(mark), size = textPixelSize(mark, frameWidth);
  return { font: `${style.weight === "bold" ? "700" : "400"} ${size}px Helvetica, Arial, sans-serif`, size };
}

export function layoutText(ctx: Ctx, mark: AnalysisAnnotation, frameWidth: number, text = mark.text): TextLayout {
  const style = resolvedTextStyle(mark);
  const { font, size } = fontFor(mark, frameWidth);
  ctx.font = font;
  const lines: TextLine[] = [];
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  text.split(/\r?\n/).forEach((line, index) => {
    const metrics = ctx.measureText(line);
    const width = Math.max(1, metrics.width);
    const ascent = metrics.actualBoundingBoxAscent || size * 0.8, descent = metrics.actualBoundingBoxDescent || size * 0.22;
    const x = style.alignment === "left" ? 0 : style.alignment === "center" ? -width / 2 : -width;
    const y = index * size * 1.2;
    lines.push({ text: line, origin: { x, y } });
    minX = Math.min(minX, x); maxX = Math.max(maxX, x + width);
    minY = Math.min(minY, y - ascent); maxY = Math.max(maxY, y - ascent + Math.max(size, ascent + descent));
  });
  const bounds = lines.length ? { x: minX - size * 0.15, y: minY - size * 0.1, width: maxX - minX + size * 0.3, height: maxY - minY + size * 0.2 } : { x: 0, y: 0, width: 0, height: 0 };
  return { lines, bounds, font, size };
}

export function drawTextLayout(ctx: Ctx, layout: TextLayout, anchor: Point, color: string, background: boolean) {
  ctx.save();
  ctx.translate(anchor.x, anchor.y);
  if (background) {
    clearShadow(ctx);
    ctx.fillStyle = gray(0.04, 0.8);
    ctx.fill(roundedRectPath(layout.bounds, layout.bounds.height * 0.12));
  }
  ctx.font = layout.font;
  ctx.textBaseline = "alphabetic";
  ctx.textAlign = "left";
  ctx.fillStyle = color;
  setShadow(ctx, 3, gray(0, 0.95), 0, 1);
  for (const line of layout.lines) ctx.fillText(line.text, line.origin.x, line.origin.y);
  ctx.restore();
}

/** Draws `text` for `mark` at a normalised anchor. */
export function drawAnnotationText(ctx: Ctx, mark: AnalysisAnnotation, text: string, anchor: Point, frameWidth: number, background: boolean) {
  const layout = layoutText(ctx, mark, frameWidth, text);
  drawTextLayout(ctx, layout, anchor, rgba(mark.color), background);
}
