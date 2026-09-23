import { describe, expect, it } from "vitest";
import { joinContinuousWindow, layoutEvents, makeGeometry, makeSnapshot, panelSizes, pointsPerSecond, resizeSnapshot, snapshotEnd, snapshotStart, subdivisionInterval, tickInterval, timeToX, timelineTimecode, trimRange, videoAspectRatioLabel, xToTime } from "./geometry";

describe("timeline geometry", () => {
  it("round-trips coordinates at every zoom, including two-hour recordings", () => {
    for (const duration of [0.1, 15, 7200]) {
      for (const zoom of [1, 4, Math.max(1, duration / 2)]) {
        const g = makeGeometry(duration, 390, zoom);
        for (const time of [0, duration / 3, duration]) {
          expect(xToTime(g, timeToX(g, time, duration / 2), duration / 2)).toBeCloseTo(time, 5);
        }
      }
    }
  });

  it("keeps ruler work bounded for long recordings", () => {
    for (const width of [320, 1024, 1366]) {
      for (const zoom of [1, 10, 3600]) {
        const g = makeGeometry(7200, width, zoom);
        const visible = width / pointsPerSecond(g);
        expect(visible / tickInterval(g)).toBeLessThanOrEqual(width / 72 + 1);
        expect(visible / subdivisionInterval(g)).toBeLessThanOrEqual(width / 12 + 1);
        const ratio = tickInterval(g) / subdivisionInterval(g);
        expect(Math.abs(ratio - Math.round(ratio))).toBeLessThan(0.001);
      }
    }
  });

  it("keeps the time under the fingers for an off-centre pinch", () => {
    const before = makeGeometry(600, 400, 2);
    const anchor = xToTime(before, 280, 300);
    const after = makeGeometry(600, 400, 8);
    const newCenter = anchor - (280 - 200) / pointsPerSecond(after);
    expect(xToTime(after, 280, newCenter)).toBeCloseTo(anchor, 4);
  });

  it("never lets a trim cross or leave the recording", () => {
    expect(trimRange(12, 2, 10, 20, true)[0]).toBeCloseTo(9.9);
    expect(trimRange(-20, 2, 10, 20, false)[1]).toBeCloseTo(2.1);
    expect(trimRange(-20, 2, 10, 20, true)[0]).toBe(0);
    expect(trimRange(100, 2, 10, 20, false)[1]).toBe(20);
    expect(trimRange(0, 0, 0.04, 0.04, false)).toEqual([0, 0.04]);
  });

  it("formats rounded tenths across the minute", () => {
    expect(timelineTimecode(59.99)).toBe("1:00.0");
    expect(timelineTimecode(Number.NaN)).toBe("0:00.0");
    expect(timelineTimecode(3725.25)).toBe("62:05.3");
    expect(timelineTimecode(65, false)).toBe("1:05");
  });

  it("labels aspect ratios despite encoder rounding", () => {
    expect(videoAspectRatioLabel(1080, 1920)).toBe("9:16");
    expect(videoAspectRatioLabel(1920, 1082)).toBe("16:9");
    expect(videoAspectRatioLabel(1080, 1080)).toBe("1:1");
    expect(videoAspectRatioLabel(0, 0)).toBe("…");
  });
});

describe("event snapshots", () => {
  it("event edges still contain the marker and locked drawings cannot resize", () => {
    const event = makeSnapshot({ offset: 5, preRoll: 3, postRoll: 3, kind: "Goal" });
    expect(resizeSnapshot(event, 7, 2, 8, true, 20)[0]).toBe(5);
    expect(resizeSnapshot(event, 3, 2, 8, false, 20)[1]).toBe(5);
    const locked = { ...event, isDrawing: true, isLocked: true };
    expect(resizeSnapshot(locked, 7, 2, 8, true, 20)[0]).toBe(2);
    expect(resizeSnapshot(locked, 3, 2, 8, false, 20)[1]).toBe(8);
  });

  it("drawing edges cross the midpoint but stay inside the clip", () => {
    const drawing = makeSnapshot({ offset: 5, preRoll: 3, postRoll: 3, kind: "✎ Polygon", lowerBound: 1, upperBound: 10, isDrawing: true });
    expect(resizeSnapshot(drawing, 7, 2, 8, true, 20)[0]).toBe(7);
    expect(resizeSnapshot(drawing, 3, 2, 8, false, 20)[1]).toBe(3);
    expect(resizeSnapshot(drawing, -10, 2, 8, true, 20)[0]).toBe(1);
    expect(resizeSnapshot(drawing, 30, 2, 8, false, 20)[1]).toBe(10);
    expect(resizeSnapshot(drawing, 9, 2, 8, true, 20)[0]).toBeCloseTo(8 - 1 / 30, 5);
  });

  it("lays out overlapping windows on separate rows using full pre/post-roll", () => {
    const first = makeSnapshot({ offset: 20, preRoll: 15, postRoll: 5, kind: "Goal" });
    const second = makeSnapshot({ offset: 30, preRoll: 10, postRoll: 10, kind: "Shot" });
    const third = makeSnapshot({ offset: 50, preRoll: 5, postRoll: 5, kind: "Save" });
    expect(snapshotStart(first)).toBe(5);
    expect(snapshotEnd(first)).toBe(25);
    const placed = layoutEvents([third, second, first]);
    const row = (s: typeof first) => placed.find((p) => p.event.id.eventID === s.id.eventID)?.row;
    expect(row(first)).not.toBe(row(second));
    expect(row(third)).toBe(0);
    expect(placed.map((p) => p.event.kind)).toEqual(["Goal", "Shot", "Save"]);
  });

  it("joins only adjacent identical windows", () => {
    const a = makeSnapshot({ id: { eventID: "E", clipID: "A" }, offset: 12, preRoll: 4, postRoll: 6, kind: "Goal", lowerBound: 0, upperBound: 10 });
    const b = makeSnapshot({ id: { eventID: "E", clipID: "B" }, offset: 12, preRoll: 4, postRoll: 6, kind: "Goal", lowerBound: 10, upperBound: 20 });
    const joined = joinContinuousWindow(a, b);
    expect(joined?.id.clipID).toBe("B");
    expect(joined?.lowerBound).toBe(0);
    expect(joined?.upperBound).toBe(20);
    expect(joinContinuousWindow(a, { ...b, lowerBound: 11, upperBound: 20 })).toBeNull();
  });
});

describe("panel sizes", () => {
  it("always fit and retain usable space", () => {
    for (const height of [350, 600, 760, 1024]) {
      for (const request of [100, 240, 600]) {
        const sizes = panelSizes(height, request);
        expect(sizes.preview + sizes.workspace + 20).toBeCloseTo(height, 2);
        expect(sizes.preview).toBeGreaterThan(0);
        expect(sizes.workspace).toBeGreaterThan(0);
      }
    }
    expect(panelSizes(800, 350).workspace).toBeGreaterThan(panelSizes(800, 224).workspace);
    expect(panelSizes(800, 350).preview).toBeLessThan(panelSizes(800, 224).preview);
  });
});
