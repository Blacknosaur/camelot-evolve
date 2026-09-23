import type { Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { DEFAULT_TRAJECTORY_STYLE } from "@/domain/tracking";
import { trajectoryPaths } from "../model/trajectory";
import { drawArrowHead } from "./effects";
import { gray, pathFrom, rgba, type Ctx } from "./canvas";

/** Past is solid in the layer colour; confirmed future movement is dashed with an arrow (port of PlayerTrajectory.draw). */
export function drawTrajectory(ctx: Ctx, mark: AnalysisAnnotation, time: number, frame: Rect) {
  ctx.save();
  const width = Math.max(1.5, frame.width * mark.width * 0.6);
  for (const future of [false, true]) {
    const color = future ? (mark.trajectoryStyle ?? DEFAULT_TRAJECTORY_STYLE).futureColor : mark.color;
    for (const points of trajectoryPaths(mark, time, future)) {
      const mapped = points.map((p) => ({ x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height }));
      const path = pathFrom(mapped);
      ctx.setLineDash(future ? [width * 3, width * 2] : []);
      ctx.lineWidth = width + 2; ctx.strokeStyle = gray(0, 0.6); ctx.stroke(path);
      ctx.lineWidth = width; ctx.strokeStyle = rgba(color); ctx.stroke(path);
      const end = mapped[mapped.length - 1], previous = mapped[mapped.length - 2];
      if (future && end && previous && Math.hypot(end.x - previous.x, end.y - previous.y) > 0.3) {
        ctx.setLineDash([]);
        drawArrowHead(ctx, end, previous, Math.max(6, width * 3));
      }
    }
  }
  ctx.setLineDash([]);
  ctx.restore();
}
