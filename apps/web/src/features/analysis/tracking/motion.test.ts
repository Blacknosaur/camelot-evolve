/* Motion semantics that AnalysisPartialFieldTests.swift relies on: hidden gaps, historical last-seen positions,
   camera transforms and bridging. The connection-rendering cases live with the analysis model. */
import { describe, expect, it } from "vitest";
import type { AnnotationCameraMotion, PlayerMotion } from "@/domain/tracking";
import { boxAt, bridged, coveredDuration, covers, isMissing, missingIntervals, placeSample, projectPoints, transformAt } from "./motion";
import { rectMidX } from "./geometry";

const track = (x: number, extra: Partial<PlayerMotion> = {}): PlayerMotion => ({
  samples: [0, 1, 2, 3, 4].map((t) => ({ time: t, box: { x: x + t * 0.02, y: 0.4, width: 0.04, height: 0.1 } })), smoothing: 0, trackID: "T", ...extra,
});

describe("PlayerMotion", () => {
  it("hides a player inside a long gap and keeps confirmed neighbours", () => {
    const missing = track(0.4, { gaps: [[1.5, 2.5]] });
    expect(boxAt(missing, 1)).not.toBeNull();
    expect(boxAt(missing, 2)).toBeNull();
    expect(isMissing(missing, 2)).toBe(true);
    expect(boxAt(missing, 3)).not.toBeNull();
    expect(rectMidX(boxAt(track(0.1), 2)!)).toBeCloseTo(0.1 + 0.04 + 0.02, 6);
  });

  it("bridges short gaps only between compatible neighbours and never after a loss", () => {
    const short: PlayerMotion = { samples: [0, 0.2, 0.4, 0.85, 1.05].map((t) => ({ time: t, box: { x: 0.4 + t * 0.02, y: 0.4, width: 0.04, height: 0.1 } })), gaps: [[0.45, 0.8]], smoothing: 0, gapBridging: 2 };
    expect(boxAt(short, 0.6)).not.toBeNull();
    expect(isMissing(short, 0.6)).toBe(true);
    const lost: PlayerMotion = { samples: [{ time: 0, box: { x: 0.1, y: 0.2, width: 0.05, height: 0.15 } }, { time: 1, box: { x: 0.2, y: 0.2, width: 0.05, height: 0.15 } }], lostAt: 1.1, trackID: "A" };
    expect(boxAt(lost, 3)).toBeNull();
    expect(missingIntervals(lost, [0, 4])[0]?.[0]).toBeCloseTo(1, 6);
    const held = bridged({ ...lost, gapBridging: 2 }, null);
    expect(held.inferred?.length).toBeGreaterThan(0);
    expect(boxAt(held, 1.5)).not.toBeNull();
    expect(boxAt(held, 3)).toBeNull();
  });

  it("hand placement splits a gap and turns a loss into a gap", () => {
    const missing: PlayerMotion = { ...track(0.4), samples: track(0.4).samples.filter((s) => s.time !== 2), gaps: [[1.5, 2.5]] };
    const placed = placeSample(missing, { x: 0.5, y: 0.4, width: 0.04, height: 0.1 }, 2);
    expect(placed.anchors).toEqual([2]);
    expect(placed.gaps?.some((g) => g[0] <= 2 && g[1] >= 2)).toBe(false);
    expect(placed.gaps?.some((g) => g[1] < 2)).toBe(true);
    expect(placed.gaps?.some((g) => g[0] > 2)).toBe(true);
    expect(boxAt(placed, 2)?.x).toBeCloseTo(0.5, 6);
    const lost: PlayerMotion = { samples: [{ time: 0, box: { x: 0.1, y: 0.2, width: 0.05, height: 0.15 } }], lostAt: 0.5 };
    const revived = placeSample(lost, { x: 0.3, y: 0.2, width: 0.05, height: 0.15 }, 2);
    expect(revived.lostAt).toBeUndefined();
    expect(revived.gaps?.[0]?.[0]).toBeCloseTo(0.5, 6);
  });

  it("camera motion interpolates, respects loss and re-expresses relative to a reference time", () => {
    const camera: AnnotationCameraMotion = { samples: [{ time: 0, transform: { values: [1, 0, 0, 0, 1, 0, 0, 0, 1] } }, { time: 1, transform: { values: [1, 0, 0.2, 0, 1, 0, 0, 0, 1] } }], lostAt: 2 };
    expect(transformAt(camera, 0.5)?.values[2]).toBeCloseTo(0.1, 6);
    expect(transformAt(camera, 2)).toBeNull();
    expect(coveredDuration(camera)).toBeCloseTo(1, 6);
    expect(covers(camera, [0, 1])).toBe(true);
    expect(projectPoints(camera, [{ x: 0.5, y: 0.5 }], 1)?.[0]?.x).toBeCloseTo(0.7, 6);
    const relative = { ...camera, referenceTime: 1 };
    expect(transformAt(relative, 0)?.values[2]).toBeCloseTo(-0.2, 6);
  });
});
