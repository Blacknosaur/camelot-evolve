import type { Point } from "@/domain/geometry";
import { rectMaxY, rectMidX } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { DEFAULT_TRAJECTORY_STYLE } from "@/domain/tracking";
import { boxAt, transformAt } from "@/features/analysis/tracking/motion";
import { cameraMatrix, mat3Determinant, mat3Inverse, mat3Multiply, mat3Point } from "@/features/analysis/tracking/geometry";
import { displayPlayerMotion, pointsAt } from "./annotation";

/* Port of PlayerTrajectory.paths: bounded, source-time paths. No extrapolation and no bridging of
   tracking gaps. Camera compensation maps historical feet into the current camera view. */
export function trajectoryPaths(mark: AnalysisAnnotation, time: number, future: boolean): Point[][] {
  const motion = displayPlayerMotion(mark);
  const first = motion?.samples[0], last = motion?.samples[motion.samples.length - 1];
  if (!motion || !first || !last || time < first.time || time > last.time) return [];
  const current = boxAt(motion, time);
  if (!current) return [];
  const drawn = pointsAt(mark, time), left = drawn[0], right = drawn[drawn.length - 1];
  if (!left || !right) return [];
  const style = mark.trajectoryStyle ?? DEFAULT_TRAJECTORY_STYLE;
  const duration = Math.min(10, Math.max(0, future ? style.futureSeconds : style.pastSeconds));
  if (duration <= 0) return [];
  const lower = future ? time : Math.max(first.time, time - duration);
  const upper = future ? Math.min(last.time, time + duration) : time;
  if (upper <= lower) return [];
  const count = Math.min(120, Math.max(1, Math.ceil((upper - lower) * 24)));
  const offset = { x: (left.x + right.x) / 2 - rectMidX(current), y: Math.max(left.y, right.y) - rectMaxY(current) };
  const camera = mark.trajectoryCameraMotion;
  const now = camera ? transformAt(camera, time) : null;
  if (camera && !now) return [];
  const paths: Point[][] = [];
  let path: Point[] = [], previousTime: number | null = null;
  const flush = () => { if (path.length > 1) paths.push(path); path = []; previousTime = null; };
  for (let index = 0; index <= count; index++) {
    const seconds = lower + (upper - lower) * index / count;
    if (previousTime != null && motion.gaps?.some((g) => g[0] <= seconds && g[1] >= previousTime!)) flush();
    const box = boxAt(motion, seconds);
    if (!box) { flush(); continue; }
    let point: Point = { x: rectMidX(box), y: rectMaxY(box) };
    if (camera && now) {
      const then = transformAt(camera, seconds);
      if (!then || Math.abs(mat3Determinant(cameraMatrix(then))) <= 0.00001) { flush(); continue; }
      const inverse = mat3Inverse(cameraMatrix(then));
      const projected = inverse && mat3Point(mat3Multiply(cameraMatrix(now), inverse), point);
      if (!projected) { flush(); continue; }
      point = projected;
    }
    path.push({ x: point.x + offset.x, y: point.y + offset.y });
    previousTime = seconds;
  }
  flush();
  return paths;
}
