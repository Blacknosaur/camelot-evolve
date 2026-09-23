/* Measurement text and trajectory sampling: ports of AnnotationMeasurements.swift (label math) and
   PlayerTrajectory.swift (`paths`). Rendering stays with the analysis renderer; these are pure. */
import type { Point } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import type { AnnotationCameraMotion, PlayerMotion, PlayerTrajectoryStyle } from "@/domain/tracking";
import { DEFAULT_TRAJECTORY_STYLE } from "@/domain/tracking";
import { calibrationIsApproximate, groundDistance, groundSpeed } from "../field/projection";
import { cameraDeterminant, cameraFromMatrix, cameraMatrix, cameraPoint, feet, mat3Inverse, mat3Multiply, rectMaxY, rectMidX } from "./geometry";
import { boxAt, transformAt } from "./motion";

const oneDecimal = new Intl.NumberFormat(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });

/** "12.3" or "≈ 12.3" for approximate (local-scale) calibrations. */
export const formattedMeasurement = (value: number, approximate: boolean) => (approximate ? "≈ " : "") + oneDecimal.format(value);

/** Speed label in km/h from a ground speed in m/s; "—" when unavailable. */
export function speedLabel(metersPerSecond: number | null, approximate = false): string {
  return `${metersPerSecond == null ? "—" : formattedMeasurement(metersPerSecond * 3.6, approximate)} km/h`;
}

/** Distance label in metres; "—" when unavailable. */
export function distanceLabel(meters: number | null, approximate = false): string {
  return `${meters == null ? "—" : formattedMeasurement(meters, approximate)} m`;
}

/** Player speed at `time` in m/s, or null. */
export const playerSpeed = (motion: PlayerMotion | undefined | null, ground: GroundCalibration | undefined | null, time: number) =>
  motion && ground ? groundSpeed(ground, motion, time) : null;

/** The text drawn for a mark, with the speed line appended when `showsSpeed` is on. */
export function measurementText(mark: AnalysisAnnotation, time: number, ground: GroundCalibration | undefined | null): string {
  if (mark.showsSpeed !== true) return mark.text;
  const speed = playerSpeed(mark.playerMotion, ground, time);
  const label = speedLabel(speed, ground ? calibrationIsApproximate(ground) : false);
  return [mark.text, label].filter((s) => s.length > 0).join("\n");
}

export interface DistanceLabel { point: Point; text: string }

/** Distance labels at segment midpoints of the mark's boundary (`boundary` = `shapeBoundary(at:)` from the analysis model). */
export function distanceLabels(mark: AnalysisAnnotation, boundary: readonly Point[], time: number, ground: GroundCalibration | undefined | null): DistanceLabel[] {
  if (mark.showsDistance !== true || mark.fieldLines === true || !["line", "arrow", "connection", "zone"].includes(mark.tool)) return [];
  let points = boundary.slice();
  if (mark.tool === "zone" && mark.linkedPlayers) points = convexHull(points);
  if (mark.tool === "zone" && points.length > 2 && points[0]) points.push(points[0]);
  const labels: DistanceLabel[] = [];
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i]!, b = points[i + 1]!;
    const distance = ground ? groundDistance(ground, a, b, time) : null;
    labels.push({ point: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, text: distanceLabel(distance, ground ? calibrationIsApproximate(ground) : false) });
  }
  return labels;
}

/** Monotone-chain convex hull (port of `GameAnnotationEffects.convexHull`). */
export function convexHull(points: readonly Point[]): Point[] {
  if (points.length < 3) return points.slice();
  const sorted = points.slice().sort((a, b) => (a.x === b.x ? a.y - b.y : a.x - b.x));
  const cross = (o: Point, a: Point, b: Point) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower: Point[] = [];
  for (const p of sorted) { while (lower.length >= 2 && cross(lower[lower.length - 2]!, lower[lower.length - 1]!, p) <= 0) lower.pop(); lower.push(p); }
  const upper: Point[] = [];
  for (let i = sorted.length - 1; i >= 0; i--) { const p = sorted[i]!; while (upper.length >= 2 && cross(upper[upper.length - 2]!, upper[upper.length - 1]!, p) <= 0) upper.pop(); upper.push(p); }
  return [...lower.slice(0, -1), ...upper.slice(0, -1)];
}

// MARK: - Trajectories

export const trajectoryStyle = (style: PlayerTrajectoryStyle | undefined | null): PlayerTrajectoryStyle => ({ ...DEFAULT_TRAJECTORY_STYLE, ...(style ?? {}) });
export const clampTrajectorySeconds = (seconds: number) => Math.min(10, Math.max(0, seconds));

export interface TrajectoryInput {
  /** The mark's display motion (`displayPlayerMotion`). */
  motion: PlayerMotion;
  /** The mark's drawn points at `time` (`points(at:)`); the feet offset is taken from the first and last. */
  drawn: readonly Point[];
  style?: PlayerTrajectoryStyle | null;
  camera?: AnnotationCameraMotion | null;
}

/** Bounded source-time foot paths, split at gaps; camera compensation maps historical feet into the current view. */
export function trajectoryPaths(input: TrajectoryInput, time: number, future: boolean): Point[][] {
  const { motion, drawn } = input;
  const first = motion.samples[0], last = motion.samples[motion.samples.length - 1];
  if (!first || !last || time < first.time || time > last.time) return [];
  const current = boxAt(motion, time);
  const left = drawn[0], right = drawn[drawn.length - 1];
  if (!current || !left || !right) return [];
  const style = trajectoryStyle(input.style);
  const duration = clampTrajectorySeconds(future ? style.futureSeconds : style.pastSeconds);
  if (!(duration > 0)) return [];
  const lower = future ? time : Math.max(first.time, time - duration);
  const upper = future ? Math.min(last.time, time + duration) : time;
  if (!(upper > lower)) return [];
  const count = Math.min(120, Math.max(1, Math.ceil((upper - lower) * 24)));
  const offset = { x: (left.x + right.x) / 2 - rectMidX(current), y: Math.max(left.y, right.y) - rectMaxY(current) };
  const camera = input.camera ?? null;
  const now = camera ? transformAt(camera, time) : null;
  if (camera && !now) return [];
  const paths: Point[][] = [];
  let path: Point[] = [], previousTime: number | null = null;
  const flush = () => { if (path.length > 1) paths.push(path); path = []; previousTime = null; };
  for (let index = 0; index <= count; index++) {
    const seconds = lower + ((upper - lower) * index) / count;
    if (previousTime != null && motion.gaps?.some((g) => g[0] <= seconds && g[1] >= previousTime!)) flush();
    const box = boxAt(motion, seconds);
    if (!box) { flush(); continue; }
    let point = feet(box);
    if (camera && now) {
      const then = transformAt(camera, seconds);
      const inverse = then && Math.abs(cameraDeterminant(then)) > 0.00001 ? mat3Inverse(cameraMatrix(then)) : null;
      const projected = inverse ? cameraPoint(cameraFromMatrix(mat3Multiply(cameraMatrix(now), inverse)), point) : null;
      if (!projected) { flush(); continue; }
      point = projected;
    }
    path.push({ x: point.x + offset.x, y: point.y + offset.y });
    previousTime = seconds;
  }
  flush();
  return paths;
}

/** Stroke geometry shared by canvas and SVG renderers (port of the constants in `PlayerTrajectory.draw`). */
export function trajectoryStroke(frameWidth: number, markWidth: number) {
  const width = Math.max(1.5, frameWidth * markWidth * 0.6);
  return { width, outlineWidth: width + 2, futureDash: [width * 3, width * 2] as [number, number], arrowHead: Math.max(6, width * 3) };
}

/** Arrow head for the future path end when the last segment is long enough; null otherwise. */
export function trajectoryArrowHead(path: readonly Point[], head: number): [Point, Point, Point] | null {
  const end = path[path.length - 1], previous = path[path.length - 2];
  if (!end || !previous || !(Math.hypot(end.x - previous.x, end.y - previous.y) > 0.3)) return null;
  const angle = Math.atan2(end.y - previous.y, end.x - previous.x);
  return [{ x: end.x - Math.cos(angle - 0.5) * head, y: end.y - Math.sin(angle - 0.5) * head }, end, { x: end.x - Math.cos(angle + 0.5) * head, y: end.y - Math.sin(angle + 0.5) * head }];
}
