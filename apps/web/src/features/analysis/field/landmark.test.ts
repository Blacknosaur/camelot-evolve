/* Port of GroundLandmarkTests.swift and the field-layout case of AnalysisPartialFieldTests.swift. */
import { describe, expect, it } from "vitest";
import type { Point } from "@/domain/geometry";
import type { GroundCalibration, GroundLandmark } from "@/domain/ground";
import { ANALYSIS_FIELD_REGIONS, GROUND_LANDMARKS, GROUND_LANDMARK_INFO, LEGACY_FIELD_LAYOUT } from "@/domain/ground";
import { calibrationCorners, editingAnchors, overlayPolylines, seedAnchors, worldLines } from "./overlay";
import { calibrationIsValid, fieldGuidePolylines, frozenCalibration } from "./projection";

describe("GroundLandmark", () => {
  it("full-size football presets use IFAB dimensions", () => {
    expect(GROUND_LANDMARK_INFO.penaltyArea.defaultLengthMeters).toBeCloseTo(40.32, 4);
    expect(GROUND_LANDMARK_INFO.penaltyArea.defaultWidthMeters).toBeCloseTo(16.5, 4);
    expect(GROUND_LANDMARK_INFO.goalArea.defaultLengthMeters).toBeCloseTo(18.32, 4);
    expect(GROUND_LANDMARK_INFO.goalArea.defaultWidthMeters).toBeCloseTo(5.5, 4);
    expect(GROUND_LANDMARK_INFO.centreCircle.defaultLengthMeters).toBeCloseTo(18.3, 4);
    expect(GROUND_LANDMARK_INFO.goalWidth.defaultLengthMeters).toBeCloseTo(7.32, 4);
  });

  it("rectangles use four points and plane mode", () => {
    expect(GROUND_LANDMARK_INFO.penaltyArea.mode).toBe("plane");
    expect(GROUND_LANDMARK_INFO.penaltyArea.pointCount).toBe(4);
    expect(GROUND_LANDMARK_INFO.goalArea.pointCount).toBe(4);
  });

  it("circle uses four plane anchors while goal width stays approximate", () => {
    expect(GROUND_LANDMARK_INFO.centreCircle.mode).toBe("plane");
    expect(GROUND_LANDMARK_INFO.centreCircle.pointCount).toBe(4);
    expect(GROUND_LANDMARK_INFO.centreCircle.isApproximate).toBe(false);
    expect(GROUND_LANDMARK_INFO.goalWidth.pointCount).toBe(2);
    expect(GROUND_LANDMARK_INFO.goalWidth.guidance.toLowerCase()).toContain("vertical goal face");
  });

  it("every field template projects and reopens without changing its anchors", () => {
    for (const landmark of GROUND_LANDMARKS.filter((l): l is GroundLandmark => GROUND_LANDMARK_INFO[l].mode === "plane")) {
      for (const right of [true, false]) {
        const anchors = seedAnchors(landmark, right);
        const corners = calibrationCorners(anchors, landmark);
        const model: GroundCalibration = {
          mode: "plane", points: corners, lengthMeters: GROUND_LANDMARK_INFO[landmark].defaultLengthMeters, widthMeters: GROUND_LANDMARK_INFO[landmark].defaultWidthMeters,
          referenceTime: 2, imageAspectRatio: 16 / 9, fixedCamera: true, fieldReference: { landmark, pitchLength: 105, pitchWidth: 68 },
        };
        expect(calibrationIsValid(model), landmark).toBe(true);
        const decoded = JSON.parse(JSON.stringify(model)) as GroundCalibration;
        expect(decoded).toEqual(model);
        const reopened = editingAnchors(decoded, landmark);
        expect(reopened).toHaveLength(4);
        reopened.forEach((b, i) => { expect(b.x).toBeCloseTo(anchors[i]!.x, 4); expect(b.y).toBeCloseTo(anchors[i]!.y, 4); });
        expect(frozenCalibration(model, 4)?.fieldReference).toEqual(model.fieldReference);
        const frame = { x: 0, y: 0, width: 1920, height: 1080 };
        const path = overlayPolylines(model, frame);
        expect(path.length).toBeGreaterThan(0);
        const moved: GroundCalibration = { ...model, points: model.points.map((p, i) => (i === 2 ? { x: p.x + 0.04, y: p.y } : p)) };
        expect(overlayPolylines(moved, frame)).not.toEqual(path);
      }
    }
  });

  it("field overlay contains related markings and rejects invalid alignment", () => {
    const lines = worldLines({ landmark: "penaltyArea", pitchLength: 105, pitchWidth: 68 }, 40.32, 16.5);
    const has = (line: Point[], p: Point) => line.some((q) => Math.abs(q.x - p.x) < 1e-9 && Math.abs(q.y - p.y) < 1e-9);
    expect(lines.some((line) => has(line, { x: 0, y: 0 }) && has(line, { x: 40.32, y: 16.5 }))).toBe(true);
    expect(lines.length).toBeGreaterThan(10);
    const model: GroundCalibration = { mode: "plane", points: [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 0 }, { x: 0, y: 1 }], lengthMeters: 40.32, widthMeters: 16.5, referenceTime: 0, imageAspectRatio: 1, fixedCamera: false };
    expect(calibrationIsValid(model)).toBe(false);
    expect(overlayPolylines(model, { x: 0, y: 0, width: 100, height: 100 })).toHaveLength(0);
  });

  it("visible reference layouts stay inside their four handles and differ per region and side", () => {
    const corners: Point[] = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];
    for (const region of ANALYSIS_FIELD_REGIONS) for (const goalSide of ["left", "right"] as const) {
      const path = fieldGuidePolylines(corners, { region, goalSide });
      expect(path.length).toBeGreaterThan(0);
      const points = path.flat();
      expect(Math.min(...points.map((p) => p.x))).toBeCloseTo(0, 4);
      expect(Math.max(...points.map((p) => p.x))).toBeCloseTo(1, 4);
      expect(Math.min(...points.map((p) => p.y))).toBeCloseTo(0, 4);
      expect(Math.max(...points.map((p) => p.y))).toBeCloseTo(1, 4);
    }
    const half = fieldGuidePolylines(corners, { region: "halfPitch", goalSide: "left" }), box = fieldGuidePolylines(corners, { region: "penaltyArea", goalSide: "left" });
    expect(half).not.toEqual(box);
    expect(fieldGuidePolylines(corners)).toEqual(fieldGuidePolylines(corners, LEGACY_FIELD_LAYOUT));
    expect(box).not.toEqual(fieldGuidePolylines(corners, { region: "penaltyArea", goalSide: "right" }));
  });
});
