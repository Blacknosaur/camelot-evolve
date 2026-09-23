/* Port of PitchRegistrationTests.swift: synthetic pitch frames with a known homography prove the snapping geometry
   and its quality report. They are not evidence about real footage. */
import { describe, expect, it } from "vitest";
import type { Point } from "@/domain/geometry";
import type { GroundCalibration, GroundLandmark, GroundLineObservation, GroundPitchLine } from "@/domain/ground";
import { GROUND_LANDMARK_INFO, pitchLineCoordinate, pitchLineIsAcross } from "@/domain/ground";
import type { FramePixels } from "../tracking/frame-pixels";
import { fitLines } from "./line-alignment";
import { overlayPolylines } from "./overlay";
import { imagePoint } from "./projection";
import { MarkingEvidence, qualityGrade, reprojectLines, snapCalibration } from "./registration";

const WIDTH = 1920, HEIGHT = 1080;
const truth: Point[] = [{ x: 0.18, y: 0.16 }, { x: 0.83, y: 0.15 }, { x: 0.98, y: 0.92 }, { x: 0.03, y: 0.94 }];

function calibration(corners: Point[], landmark: GroundLandmark = "fullPitch"): GroundCalibration {
  const info = GROUND_LANDMARK_INFO[landmark];
  return {
    mode: "plane", points: corners, lengthMeters: landmark === "fullPitch" ? 68 : info.defaultLengthMeters, widthMeters: landmark === "fullPitch" ? 105 : info.defaultWidthMeters,
    referenceTime: 0, imageAspectRatio: 16 / 9, fixedCamera: true, fieldReference: { landmark, pitchLength: 105, pitchWidth: 68 },
  };
}

/** Deterministic LCG so the synthetic turf noise is reproducible. */
function random(seed: number) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

/** Green turf with noise, a bright stand, white shirts and painted lines whose width grows toward the bottom of the frame. */
function frame(model: GroundCalibration, lines = true): FramePixels {
  const data = new Uint8ClampedArray(WIDTH * HEIGHT * 4);
  const fill = (x: number, y: number, w: number, h: number, r: number, g: number, b: number) => {
    for (let yy = Math.max(0, Math.floor(y)); yy < Math.min(HEIGHT, y + h); yy++) for (let xx = Math.max(0, Math.floor(x)); xx < Math.min(WIDTH, x + w); xx++) {
      const i = (yy * WIDTH + xx) * 4; data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255;
    }
  };
  fill(0, 0, WIDTH, HEIGHT, 56, 133, 51);
  const next = random(7);
  for (let i = 0; i < 4000; i++) fill(next() * WIDTH, next() * HEIGHT, 6, 6, 51, Math.round((0.42 + next() * 0.18) * 255), 46);
  fill(0, 0, WIDTH, HEIGHT * 0.12, 191, 191, 191);
  if (lines) {
    const stroke = (a: Point, b: Point, width: number) => {
      const length = Math.hypot(b.x - a.x, b.y - a.y), steps = Math.max(1, Math.ceil(length));
      for (let s = 0; s <= steps; s++) {
        const t = s / steps, cx = a.x + (b.x - a.x) * t, cy = a.y + (b.y - a.y) * t;
        // Line width depends on the vertical band, approximating perspective thickness.
        const band = Math.min(5, Math.max(0, Math.floor((cy / HEIGHT) * 5))), w = 2 + band;
        if (Math.abs(w - width) > 0.5) continue;
        fill(cx - w / 2, cy - w / 2, w, w, 255, 255, 255);
      }
    };
    for (const polyline of overlayPolylines(model, { x: 0, y: 0, width: WIDTH, height: HEIGHT })) {
      for (let i = 0; i + 1 < polyline.length; i++) for (let width = 2; width <= 7; width++) stroke(polyline[i]!, polyline[i + 1]!, width);
    }
    for (const x of [0.3, 0.55, 0.7]) fill(WIDTH * x, HEIGHT * 0.6, 22, 40, 255, 255, 255);
  }
  return { width: WIDTH, height: HEIGHT, data, time: 0 };
}

function perturbed(corners: Point[], pixels: number): Point[] {
  const offsets: Point[] = [{ x: 1, y: -0.6 }, { x: -0.8, y: 0.9 }, { x: 0.5, y: 1 }, { x: -1, y: -0.4 }];
  return corners.map((c, i) => ({ x: c.x + (offsets[i]!.x * pixels) / WIDTH, y: c.y + (offsets[i]!.y * pixels) / HEIGHT }));
}
const cornerError = (corners: Point[]) => Math.max(...corners.map((c, i) => Math.hypot((c.x - truth[i]!.x) * WIDTH, (c.y - truth[i]!.y) * HEIGHT)));

describe("PitchRegistration", () => {
  const image = frame(calibration(truth));
  const evidence = MarkingEvidence.fromFrame(image)!;

  it("snap recovers the whole pitch from rough handles", () => {
    const rough = calibration(perturbed(truth, 18));
    expect(cornerError(rough.points)).toBeGreaterThan(12);
    const result = snapCalibration(rough, evidence);
    expect(result).not.toBeNull();
    expect(cornerError(result!.calibration.points)).toBeLessThan(1.5);
    expect(qualityGrade(result!.quality)).toBe("good");
    expect(result!.quality.residualPixels).toBeLessThan(1.2);
    expect(result!.quality.supportedLines).toBeGreaterThan(6);
    expect(result!.calibration.fieldReference?.landmark).toBe("fullPitch");
    expect(JSON.parse(JSON.stringify(result!.calibration))).toEqual(result!.calibration);
  });

  it("snap refines a partial penalty-area reference", () => {
    const plane = calibration(truth);
    const box: Point[] = [{ x: (68 - 40.32) / 2, y: 0 }, { x: (68 + 40.32) / 2, y: 0 }, { x: (68 + 40.32) / 2, y: 16.5 }, { x: (68 - 40.32) / 2, y: 16.5 }];
    const exact = box.map((p) => imagePoint(plane, p, 0)!);
    expect(exact.every(Boolean)).toBe(true);
    const rough = calibration(perturbed(exact, 14), "penaltyArea");
    const result = snapCalibration(rough, evidence);
    expect(result).not.toBeNull();
    result!.calibration.points.forEach((actual, i) => {
      expect(Math.abs(actual.x - exact[i]!.x) * WIDTH).toBeLessThan(1.5);
      expect(Math.abs(actual.y - exact[i]!.y) * HEIGHT).toBeLessThan(1.5);
    });
    expect(qualityGrade(result!.quality)).not.toBe("poor");
  });

  it("flat turf without markings is reported as weak", () => {
    const flat = MarkingEvidence.fromFrame(frame(calibration(truth), false))!;
    const result = snapCalibration(calibration(perturbed(truth, 10)), flat);
    expect(result == null || qualityGrade(result.quality) === "poor").toBe(true);
  });

  it("traced lines reproject onto the snapped template and refit", () => {
    const rough = calibration(perturbed(truth, 16));
    const kinds: GroundPitchLine[] = ["farTouch", "nearTouch", "halfway", "leftGoal", "leftBoxFront"];
    const traced: GroundLineObservation[] = kinds.map((kind) => {
      const k = pitchLineCoordinate(kind, 105, 68);
      const world = pitchLineIsAcross(kind) ? [{ x: 68 * 0.3, y: 105 * k }, { x: 68 * 0.7, y: 105 * k }] : [{ x: 68 * k, y: 105 * 0.2 }, { x: 68 * k, y: 105 * 0.6 }];
      return { kind, points: world.map((p) => imagePoint(rough, p, 0)!) };
    });
    const fit = fitLines(traced, 105, 68, 0, 16 / 9, true);
    expect(fit).not.toBeNull();
    const snapped = snapCalibration(fit!.calibration, evidence);
    expect(snapped).not.toBeNull();
    expect(cornerError(snapped!.calibration.points)).toBeLessThan(1.5);
    const moved = reprojectLines(traced, snapped!.calibration, 105, 68);
    expect(moved).not.toBeNull();
    const refit = fitLines(moved!, 105, 68, 0, 16 / 9, true);
    expect(refit).not.toBeNull();
    refit!.calibration.points.forEach((a, i) => {
      expect(Math.abs(a.x - snapped!.calibration.points[i]!.x) * WIDTH).toBeLessThan(0.05);
      expect(Math.abs(a.y - snapped!.calibration.points[i]!.y) * HEIGHT).toBeLessThan(0.05);
    });
  });

  it("snap rejects references without a plane", () => {
    const local: GroundCalibration = { mode: "localScale", points: [{ x: 0, y: 0 }, { x: 0.5, y: 0 }], lengthMeters: 10, widthMeters: 0, referenceTime: 0, imageAspectRatio: 16 / 9, fixedCamera: false };
    expect(snapCalibration(local, evidence)).toBeNull();
    const custom = { ...calibration(truth), fieldReference: undefined };
    expect(snapCalibration(custom, evidence)).toBeNull();
  });

  it("evidence and snap stay interactive", () => {
    const start = performance.now();
    const fresh = MarkingEvidence.fromFrame(image)!;
    const result = snapCalibration(calibration(perturbed(truth, 12)), fresh);
    const total = (performance.now() - start) / 1000;
    expect(result).not.toBeNull();
    expect(total).toBeLessThan(6);
  });
});
