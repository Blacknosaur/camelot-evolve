/* Field alignment from traced portions of named pitch lines: port of GroundLineAlignment.swift. */
import type { Point } from "@/domain/geometry";
import type { GroundCalibration, GroundLineObservation } from "@/domain/ground";
import { pitchLineCoordinate, pitchLineIsAcross } from "@/domain/ground";
import { isFinitePoint, mat3Apply, mat3Determinant, mat3Inverse, type Mat3 } from "../tracking/geometry";
import { solveNormalEquations } from "../tracking/camera-registration";
import { RECTANGLE } from "./overlay";
import { calibrationIsValid } from "./projection";

export interface LineFit {
  calibration: GroundCalibration;
  /** Residual in normalized image coordinates, not a metric accuracy claim. */
  residual: number;
  minimumCrossingAngle: number;
}

export function fitLines(lines: readonly GroundLineObservation[], length: number, width: number, time: number, aspect: number, fixed: boolean): LineFit | null {
  if (!Number.isFinite(length) || !Number.isFinite(width) || !(length > 33) || !(width > 40.32)) return null;
  const usable = lines.filter((l) => l.points.length === 2 && l.points.every(isFinitePoint) && Math.hypot(l.points[1]!.x - l.points[0]!.x, l.points[1]!.y - l.points[0]!.y) >= 0.035);
  if (usable.length < 4 || new Set(usable.map((l) => l.kind)).size !== usable.length) return null;
  const system: number[][] = Array.from({ length: 8 }, () => new Array<number>(9).fill(0));
  for (const line of usable) {
    const k = pitchLineCoordinate(line.kind, length, width);
    for (const p of line.points) {
      const u = p.x, v = p.y;
      const row = pitchLineIsAcross(line.kind) ? [0, 0, 0, u, v, 1, -k * u, -k * v] : [u, v, 1, 0, 0, 0, -k * u, -k * v];
      for (let i = 0; i < 8; i++) { for (let j = 0; j < 8; j++) system[i]![j]! += row[i]! * row[j]!; system[i]![8]! += row[i]! * k; }
    }
  }
  const h = solveNormalEquations(system, 1e-10, true);
  if (!h) return null;
  const matrix: Mat3 = [h[0]!, h[1]!, h[2]!, h[3]!, h[4]!, h[5]!, h[6]!, h[7]!, 1];
  if (!(Math.abs(mat3Determinant(matrix)) > 1e-9)) return null;
  const inverse = mat3Inverse(matrix);
  if (!inverse) return null;
  const corners: Point[] = [];
  let sign: number | null = null;
  for (const p of RECTANGLE) {
    const result = mat3Apply(inverse, [p.x, p.y, 1]);
    if (!Number.isFinite(result[2]) || !(Math.abs(result[2]) > 1e-7) || (sign != null && !(sign * result[2] > 0))) return null;
    sign = result[2];
    const x = result[0] / result[2], y = result[1] / result[2];
    if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) >= 32 || Math.abs(y) >= 32) return null;
    corners.push({ x, y });
  }
  let residual = 0;
  for (const line of usable) {
    const k = pitchLineCoordinate(line.kind, length, width), across = pitchLineIsAcross(line.kind);
    const a = across ? h[3]! - k * h[6]! : h[0]! - k * h[6]!, b = across ? h[4]! - k * h[7]! : h[1]! - k * h[7]!, c = across ? h[5]! - k : h[2]! - k;
    if (!(Math.hypot(a, b) > 1e-9)) return null;
    for (const p of line.points) residual = Math.max(residual, Math.abs(a * p.x + b * p.y + c) / Math.hypot(a, b));
  }
  if (!(residual < 0.012)) return null;
  const calibration: GroundCalibration = {
    mode: "plane", points: corners, lengthMeters: width, widthMeters: length, referenceTime: time, imageAspectRatio: aspect, fixedCamera: fixed,
    fieldReference: { landmark: "fullPitch", pitchLength: length, pitchWidth: width }, lineReferences: usable.map((l) => ({ kind: l.kind, points: l.points.slice() })),
  };
  if (!calibrationIsValid(calibration)) return null;
  let minimumAngle = 90;
  for (const a of usable) {
    if (!pitchLineIsAcross(a.kind)) continue;
    for (const b of usable) {
      if (pitchLineIsAcross(b.kind)) continue;
      const ax = (a.points[1]!.x - a.points[0]!.x) * aspect, ay = a.points[1]!.y - a.points[0]!.y;
      const bx = (b.points[1]!.x - b.points[0]!.x) * aspect, by = b.points[1]!.y - b.points[0]!.y;
      const cosine = Math.min(1, Math.abs(ax * bx + ay * by) / Math.max(1e-12, Math.hypot(ax, ay) * Math.hypot(bx, by)));
      minimumAngle = Math.min(minimumAngle, (Math.acos(cosine) * 180) / Math.PI);
    }
  }
  return { calibration, residual, minimumCrossingAngle: minimumAngle };
}
