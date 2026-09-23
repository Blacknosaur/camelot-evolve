import { describe, expect, it } from "vitest";
import type { CompositionClip } from "@/domain/records";
import { compositionDuration } from "@/domain/records";
import { aspectRatioValue, clampFrameRate, cropRect, displayFrame, frameCount, frameTime, locateInClip, outputSize, outputToSource } from "./preview-parity";

const clip = (over: Partial<CompositionClip> = {}): CompositionClip => ({ id: "A", recordingID: "R", startSeconds: 10, endSeconds: 20, rate: 1, annotations: [], ...over });

describe("cropRect", () => {
  it("returns the full frame for original", () => {
    expect(cropRect({ width: 1920, height: 1080 }, "original")).toEqual({ x: 0, y: 0, width: 1920, height: 1080 });
  });
  it("centres a portrait crop inside landscape footage", () => {
    const rect = cropRect({ width: 1920, height: 1080 }, "9:16");
    expect(rect.height).toBe(1080);
    expect(rect.width).toBeCloseTo(607.5);
    expect(rect.x).toBeCloseTo((1920 - 607.5) / 2);
    expect(rect.y).toBe(0);
  });
  it("centres a landscape crop inside portrait footage and accepts iOS spellings", () => {
    const rect = cropRect({ width: 1080, height: 1920 }, "landscape");
    expect(rect.width).toBe(1080);
    expect(rect.height).toBeCloseTo(607.5);
    expect(rect.y).toBeCloseTo((1920 - 607.5) / 2);
    expect(aspectRatioValue("square")).toBe(1);
    expect(aspectRatioValue("4:5")).toBeCloseTo(0.8);
  });
});

describe("outputSize", () => {
  it("keeps the source size for original at source preset", () => {
    expect(outputSize({ width: 1920, height: 1080 }, "original")).toEqual({ width: 1920, height: 1080 });
    expect(outputSize({ width: 3840, height: 2160 }, "original", "1080p")).toEqual({ width: 1920, height: 1080 });
    expect(outputSize({ width: 3840, height: 2160 }, "original", "720p")).toEqual({ width: 1280, height: 720 });
  });
  it("matches EditorSequencePreview for fixed aspects (upscaled portrait crop)", () => {
    expect(outputSize({ width: 1920, height: 1080 }, "9:16")).toEqual({ width: 1080, height: 1920 });
    expect(outputSize({ width: 1920, height: 1080 }, "9:16", "720p")).toEqual({ width: 720, height: 1280 });
    expect(outputSize({ width: 1920, height: 1080 }, "1:1", "1080p")).toEqual({ width: 1920, height: 1920 });
    expect(outputSize({ width: 1920, height: 1080 }, "4:5")).toEqual({ width: 1536, height: 1920 });
  });
  it("never upsizes beyond the source width and keeps even dimensions", () => {
    expect(outputSize({ width: 1280, height: 720 }, "original", "1080p")).toEqual({ width: 1280, height: 720 });
    const odd = outputSize({ width: 1279, height: 721 }, "original");
    expect(odd.width % 2).toBe(0);
    expect(odd.height % 2).toBe(0);
  });
});

describe("displayFrame", () => {
  it("fits (letterbox) for original and fills (crop) for fixed aspects", () => {
    const out = { width: 1920, height: 1080 };
    expect(displayFrame({ width: 1080, height: 1920 }, out, "original")).toEqual({ x: (1920 - 607.5) / 2, y: 0, width: 607.5, height: 1080 });
    const cover = displayFrame({ width: 1920, height: 1080 }, { width: 1080, height: 1920 }, "9:16");
    expect(cover.height).toBe(1920);
    expect(cover.width).toBeCloseTo(3413.33, 1);
    expect(cover.x).toBeLessThan(0);
    // Crop rect and cover frame describe the same visible region.
    const crop = cropRect({ width: 1920, height: 1080 }, "9:16");
    expect(-cover.x / (cover.width / 1920)).toBeCloseTo(crop.x, 3);
  });
});

describe("outputToSource", () => {
  const clips = [clip({ id: "A", startSeconds: 10, endSeconds: 20, rate: 1 }), clip({ id: "B", startSeconds: 0, endSeconds: 8, rate: 2 }), clip({ id: "C", startSeconds: 30, endSeconds: 31, freezeDuration: 5 })];

  it("maps output time through rate and freeze clips", () => {
    expect(compositionDuration(clips)).toBe(19);
    expect(outputToSource(clips, 5)).toMatchObject({ clipIndex: 0, sourceTime: 15, annotationTime: 15, elapsed: 5 });
    expect(outputToSource(clips, 12)).toMatchObject({ clipIndex: 1, clipStart: 10, sourceTime: 4, annotationTime: 4 });
    // Held frame: picture stays on startSeconds, annotations advance at 1x.
    expect(outputToSource(clips, 16.5)).toMatchObject({ clipIndex: 2, clipStart: 14, sourceTime: 30, annotationTime: 32.5 });
  });
  it("is inclusive at the very end and null past it", () => {
    expect(outputToSource(clips, 19)?.clipIndex).toBe(2);
    expect(outputToSource(clips, 19.01)).toBeNull();
    expect(outputToSource([], 0)).toBeNull();
  });
  it("clamps slow-motion source time at the clip end", () => {
    const slow = clip({ startSeconds: 0, endSeconds: 2, rate: 0.5 });
    expect(locateInClip(slow, 0, 3.9).sourceTime).toBeCloseTo(1.95);
    expect(locateInClip(slow, 0, 4.5).sourceTime).toBe(2);
  });
});

describe("frame timing", () => {
  it("drops and duplicates frames onto the constant output grid", () => {
    const fast = clip({ startSeconds: 0, endSeconds: 4, rate: 4 });
    const fps = 30;
    const sourceTimes = Array.from({ length: frameCount(1, fps) }, (_, k) => locateInClip(fast, 0, frameTime(k, fps)).sourceTime);
    // 4x: consecutive output frames advance 4 source frames (at 30fps source that is 4/30 s).
    expect(sourceTimes[1]! - sourceTimes[0]!).toBeCloseTo(4 / 30);
    const slow = clip({ startSeconds: 0, endSeconds: 1, rate: 0.25 });
    const slowTimes = Array.from({ length: frameCount(4, fps) }, (_, k) => locateInClip(slow, 0, frameTime(k, fps)).sourceTime);
    // 0.25x: four output frames share one source frame interval.
    expect(slowTimes[4]! - slowTimes[0]!).toBeCloseTo(1 / 30);
    expect(slowTimes.length).toBe(120);
  });
  it("counts frames exactly for a two-hour composition without drift", () => {
    const twoHours = 2 * 60 * 60;
    expect(frameCount(twoHours, 30)).toBe(216_000);
    expect(frameCount(twoHours, 60)).toBe(432_000);
    expect(frameCount(twoHours, 24)).toBe(172_800);
    expect(frameTime(216_000, 30)).toBe(twoHours);
    // Frame timestamps stay on the grid: no accumulated floating error from repeated addition.
    let accumulated = 0;
    for (let k = 0; k < 216_000; k++) accumulated += 1 / 30;
    expect(Math.abs(accumulated - twoHours)).toBeGreaterThan(1e-9);
    expect(frameTime(215_999, 30)).toBeCloseTo(twoHours - 1 / 30, 12);
  });
  it("frame boundaries between clips hand over on the grid", () => {
    const clips = [clip({ startSeconds: 0, endSeconds: 1.5, rate: 1 }), clip({ id: "B", startSeconds: 7, endSeconds: 8, rate: 1 })];
    const fps = 30;
    const total = frameCount(compositionDuration(clips), fps);
    expect(total).toBe(75);
    const owners = Array.from({ length: total }, (_, k) => outputToSource(clips, frameTime(k, fps))!.clipIndex);
    expect(owners.filter((o) => o === 0).length).toBe(45);
    expect(owners.filter((o) => o === 1).length).toBe(30);
  });
  it("handles empty and degenerate inputs", () => {
    expect(frameCount(0, 30)).toBe(0);
    expect(frameCount(0.001, 30)).toBe(1);
    expect(clampFrameRate(119.88)).toBe(60);
    expect(clampFrameRate(29.97)).toBe(30);
    expect(clampFrameRate(0)).toBe(1);
  });
});
