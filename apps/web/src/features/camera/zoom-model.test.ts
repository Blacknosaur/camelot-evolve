import { describe, expect, it } from "vitest";
import { crossedStop, defaultArcDial, dialAngle, dialTicks, dialValue, mergeStops, pillLabel, selectedPill, snapZoom, stepZoom, zoomPills } from "./zoom-model";

describe("zoom stops", () => {
  it("derives Camera.app-style pills", () => {
    expect(zoomPills({ minimum: 1, maximum: 4, lensFactors: [] })).toEqual([1, 2]);
    expect(zoomPills({ minimum: 0.5, maximum: 6, lensFactors: [0.5, 1, 3] })).toEqual([0.5, 1, 2, 3]);
    expect(zoomPills({ minimum: 1, maximum: 1.5, lensFactors: [] })).toEqual([1]);
  });

  it("merges near-duplicate stops and clamps to the range", () => {
    expect(mergeStops([1, 1.02, 2, 7], 1, 6)).toEqual([1, 2]);
  });

  it("selects the pill owning the live value and labels it live", () => {
    const pills = [0.5, 1, 2];
    expect(selectedPill(1.7, pills)).toBe(1);
    expect(selectedPill(0.3, pills)).toBe(0.5);
    expect(pillLabel(1, 1.74, true)).toBe("1.7×");
    expect(pillLabel(0.5, 1, false)).toBe("0.5");
    expect(pillLabel(2, 1, false)).toBe("2");
  });
});

describe("arc dial", () => {
  const dial = defaultArcDial({ minimum: 0.5, maximum: 6, lensFactors: [] });

  it("spaces ticks logarithmically", () => {
    expect(dialAngle(dial, 2, 1)).toBeCloseTo(48);
    expect(dialAngle(dial, 4, 2)).toBeCloseTo(48);
    expect(dialAngle(dial, 0.5, 1)).toBeCloseTo(-48);
  });

  it("maps horizontal drag to a ratio and clamps", () => {
    expect(dialValue(dial, 1, -120)).toBeCloseTo(2);
    expect(dialValue(dial, 1, 120)).toBeCloseTo(0.5);
    expect(dialValue(dial, 1, 5000)).toBe(0.5);
    expect(dialValue(dial, 4, -5000)).toBe(6);
  });

  it("lists labelled stops and fine ticks inside the sweep, sorted", () => {
    const ticks = dialTicks(dial, 1);
    const stops = ticks.filter((t) => t.isStop).map((t) => t.zoom);
    expect(stops).toEqual([0.5, 1, 2]);
    expect(ticks.every((t) => Math.abs(t.angle) <= dial.halfSweep)).toBe(true);
    for (let i = 1; i < ticks.length; i += 1) expect(ticks[i]!.angle).toBeGreaterThan(ticks[i - 1]!.angle);
    expect(ticks.some((t) => !t.isStop)).toBe(true);
  });

  it("detects crossed stops, snaps near stops and steps by 10%", () => {
    expect(crossedStop(1.8, 2.2, [1, 2, 3])).toBe(2);
    expect(crossedStop(2.2, 1.8, [1, 2, 3])).toBe(2);
    expect(crossedStop(2.1, 2.4, [1, 2, 3])).toBeNull();
    expect(snapZoom(2.03, [1, 2, 3])).toBe(2);
    expect(snapZoom(2.3, [1, 2, 3])).toBe(2.3);
    expect(stepZoom(dial.scale, 1, 1)).toBeCloseTo(1.1);
    expect(stepZoom(dial.scale, 0.5, -1)).toBe(0.5);
  });
});
