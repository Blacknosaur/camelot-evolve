import type { Point } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import { groundDistance, groundIsApproximate, groundSpeed } from "./ground";
import { shapeBoundary } from "./annotation";
import { convexHull } from "./geometry";

/* Port of AnnotationMeasurements.swift. Values stay "—" without calibration; approximate
   (two-point) calibrations are prefixed with "≈". */

const formatted = (value: number, approximate: boolean) => (approximate ? "≈ " : "") + value.toFixed(1);

/** km/h label for a player-following text layer, or null when the layer does not show speed. */
export function speedLabel(mark: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): string | null {
  if (mark.showsSpeed !== true) return null;
  const speed = mark.playerMotion && ground ? groundSpeed(ground, mark.playerMotion, time) : null;
  return `${speed != null ? formatted(speed * 3.6, ground ? groundIsApproximate(ground) : false) : "—"} km/h`;
}

/** Text drawn for a layer: the authored text plus the speed line when enabled. */
export function measurementText(mark: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): string {
  const speed = speedLabel(mark, time, ground);
  if (!speed) return mark.text;
  return [mark.text, speed].filter((s) => s.length > 0).join("\n");
}

export function distanceLabels(mark: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): { point: Point; text: string }[] {
  if (mark.showsDistance !== true || mark.fieldLines === true) return [];
  if (!["line", "arrow", "connection", "zone"].includes(mark.tool)) return [];
  let points = shapeBoundary(mark, time, ground);
  if (mark.tool === "zone" && mark.linkedPlayers) points = convexHull(points);
  if (mark.tool === "zone" && points.length > 2 && points[0]) points = [...points, points[0]];
  const out: { point: Point; text: string }[] = [];
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i]!, b = points[i + 1]!;
    const distance = ground ? groundDistance(ground, a, b, time) : null;
    out.push({ point: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, text: `${distance != null ? formatted(distance, groundIsApproximate(ground!)) : "—"} m` });
  }
  return out;
}

export const measurementStatus = (ground: GroundCalibration | null | undefined): string | null =>
  ground ? (groundIsApproximate(ground) ? "Approximate local measurements · not perspective corrected." : "Ground-calibrated estimates · speed uses the recorded source time.") : null;
