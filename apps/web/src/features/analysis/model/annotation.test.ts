import { describe, expect, it } from "vitest";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { PlayerMotion } from "@/domain/tracking";
import { applyTimelineEdit, editHandles, enableKeyframes, handleIndexAt, hasMotion, hitTest, insertPolygonCorner, isActiveInEditor, makeStatic, motionMode, moveDrawing, opacityAt, pointsAt, removePolygonCorner, renderedPoints, reshaped, setKeyframe, trackedSpan } from "./annotation";
import { zoomTransform } from "./viewport";
import { loupeGeometry } from "./loupe";
import { convexHull } from "./geometry";

const mark = (overrides: Partial<AnalysisAnnotation> = {}): AnalysisAnnotation => ({
  id: "A", tool: "arrow", points: [{ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 }], color: { red: 1, green: 1, blue: 0 }, width: 0.006, text: "", start: 1, end: 5, fade: false, keyframes: [], ...overrides,
});

const motion = (samples: [number, number][], extra: Partial<PlayerMotion> = {}): PlayerMotion => ({
  samples: samples.map(([time, x]) => ({ time, box: { x, y: 0.4, width: 0.1, height: 0.2 } })), smoothing: 0, ...extra,
});

describe("pointsAt", () => {
  it("returns authored points without motion", () => {
    expect(pointsAt(mark(), 2)).toEqual([{ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 }]);
  });
  it("interpolates between keyframes and clamps outside", () => {
    const a = mark({ keyframes: [{ id: "k1", time: 1, points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }, { id: "k2", time: 3, points: [{ x: 1, y: 0 }, { x: 0, y: 1 }] }] });
    expect(pointsAt(a, 2)[0]).toEqual({ x: 0.5, y: 0 });
    expect(pointsAt(a, 0)).toEqual([{ x: 0, y: 0 }, { x: 1, y: 1 }]);
    expect(pointsAt(a, 9)).toEqual([{ x: 1, y: 0 }, { x: 0, y: 1 }]);
  });
  it("translates player-following labels by the box centre", () => {
    const m = motion([[1, 0.1], [3, 0.5]], { referenceBox: { x: 0.1, y: 0.4, width: 0.1, height: 0.2 } });
    const label = mark({ tool: "text", points: [{ x: 0.15, y: 0.35 }], playerMotion: m });
    expect(pointsAt(label, 2)[0]!.x).toBeCloseTo(0.35, 5);
    expect(pointsAt(label, 2)[0]!.y).toBeCloseTo(0.35, 5);
  });
  it("scales shapes from the reference box to the tracked box", () => {
    const m = motion([[1, 0.1], [3, 0.1]], { referenceBox: { x: 0.1, y: 0.4, width: 0.1, height: 0.2 } });
    const rect = mark({ tool: "rectangle", points: [{ x: 0.1, y: 0.4 }, { x: 0.2, y: 0.6 }], playerMotion: m });
    const p = pointsAt(rect, 2);
    expect(p[0]!.x).toBeCloseTo(0.1); expect(p[1]!.x).toBeCloseTo(0.2); expect(p[1]!.y).toBeCloseTo(0.6);
  });
  it("uses camera motion when present", () => {
    const camera = { samples: [{ time: 0, transform: { values: [1, 0, 0, 0, 1, 0, 0, 0, 1] } }, { time: 2, transform: { values: [1, 0, 0.2, 0, 1, 0, 0, 0, 1] } }] };
    const a = mark({ cameraMotion: camera });
    expect(pointsAt(a, 1)[0]!.x).toBeCloseTo(0.3);
    expect(hasMotion(a, 5)).toBe(false);
  });
});

describe("opacityAt", () => {
  it("is zero outside the range, hidden or without motion", () => {
    expect(opacityAt(mark(), 0.5)).toBe(0);
    expect(opacityAt(mark(), 5)).toBe(0);
    expect(opacityAt(mark({ isHidden: true }), 2)).toBe(0);
    expect(opacityAt(mark({ playerMotion: motion([[1, 0.1], [2, 0.2]]) }), 4)).toBe(0);
  });
  it("ramps with fade using min(0.18, duration/4)", () => {
    const a = mark({ fade: true });
    expect(opacityAt(a, 1.09)).toBeCloseTo(0.5, 5);
    expect(opacityAt(a, 3)).toBe(1);
    expect(opacityAt(a, 4.91)).toBeCloseTo(0.5, 5);
    expect(opacityAt(mark({ fade: true, start: 1, end: 1.4 }), 1.05)).toBeCloseTo(0.5, 5);
  });
  it("keeps editor visibility a fraction of a frame early", () => {
    expect(isActiveInEditor(mark(), 1 - 1 / 1000)).toBe(true);
    expect(isActiveInEditor(mark(), 0.9)).toBe(false);
  });
});

describe("keyframes", () => {
  it("replaces within a frame and inserts sorted otherwise", () => {
    let a = setKeyframe(mark(), 3, [{ x: 0, y: 0 }, { x: 1, y: 1 }]);
    a = setKeyframe(a, 2, [{ x: 0.5, y: 0 }, { x: 1, y: 1 }]);
    expect(a.keyframes.map((k) => k.time)).toEqual([2, 3]);
    a = setKeyframe(a, 3.005, [{ x: 9, y: 9 }, { x: 9, y: 9 }]);
    expect(a.keyframes).toHaveLength(2);
    expect(a.keyframes[1]!.points[0]).toEqual({ x: 9, y: 9 });
  });
  it("enableKeyframes seeds start and current pose", () => {
    const a = enableKeyframes(mark(), 3);
    expect(motionMode(a)).toBe("keyframes");
    expect(a.keyframes.map((k) => k.time)).toEqual([1, 3]);
  });
  it("moveDrawing records a keyframe in keyframe mode", () => {
    const a = moveDrawing(enableKeyframes(mark(), 3), [{ x: 0.3, y: 0.3 }, { x: 0.7, y: 0.7 }], 4);
    expect(a.keyframes.map((k) => k.time)).toEqual([1, 3, 4]);
    expect(pointsAt(a, 4)[0]).toEqual({ x: 0.3, y: 0.3 });
  });
  it("makeStatic bakes the pose and drops motion", () => {
    const a = makeStatic(mark({ keyframes: [{ id: "k", time: 1, points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }, { id: "k2", time: 3, points: [{ x: 1, y: 0 }, { x: 0, y: 1 }] }] }), 2);
    expect(a.keyframes).toEqual([]);
    expect(a.points[0]).toEqual({ x: 0.5, y: 0 });
  });
});

describe("timeline edits", () => {
  it("moves within bounds and shifts authored keyframes", () => {
    const a = mark({ keyframes: [{ id: "k", time: 2, points: [] }] });
    const moved = applyTimelineEdit(a, { kind: "move", delta: 10 }, 0, 8);
    expect(moved.start).toBe(4); expect(moved.end).toBe(8); expect(moved.keyframes[0]!.time).toBe(5);
  });
  it("trims with a one-frame minimum and locks", () => {
    expect(applyTimelineEdit(mark(), { kind: "trimStart", value: 4.99 }, 0, 8).start).toBeCloseTo(5 - 1 / 30);
    expect(applyTimelineEdit(mark(), { kind: "trimEnd", value: 100 }, 0, 8).end).toBe(8);
    expect(applyTimelineEdit(mark({ isLocked: true }), { kind: "trimEnd", value: 2 }, 0, 8).end).toBe(5);
  });
  it("keeps keyframes ordered when retimed", () => {
    const a = mark({ keyframes: [{ id: "k1", time: 2, points: [] }, { id: "k2", time: 3, points: [] }] });
    expect(applyTimelineEdit(a, { kind: "keyframe", id: "k1", value: 4 }, 0, 8).keyframes[0]!.time).toBeCloseTo(3 - 1 / 60);
  });
  it("reports tracked span and mode for player layers", () => {
    const a = mark({ playerMotion: motion([[2, 0.1], [4, 0.2]]) });
    expect(motionMode(a)).toBe("player");
    expect(trackedSpan(a)).toEqual([2, 4]);
  });
});

describe("handles, reshaping and hit testing", () => {
  it("exposes four corners for rectangles and endpoints for arrows", () => {
    expect(editHandles(mark({ tool: "rectangle" }), 2)).toHaveLength(4);
    expect(editHandles(mark(), 2)).toHaveLength(2);
    expect(editHandles(mark({ tool: "pen" }), 2)).toHaveLength(0);
  });
  it("reshapes one corner or moves the whole drawing", () => {
    const rect = mark({ tool: "rectangle" });
    const corner = reshaped(rect, 2, 1, { width: 0.1, height: 0.1 });
    expect(corner[0]!.x).toBeCloseTo(0.2); expect(corner[0]!.y).toBeCloseTo(0.3); expect(corner[1]!.x).toBeCloseTo(0.7); expect(corner[1]!.y).toBeCloseTo(0.6);
    const moved = reshaped(rect, 2, null, { width: 0.1, height: 0 });
    expect(moved[0]!.x).toBeCloseTo(0.3); expect(moved[0]!.y).toBeCloseTo(0.2);
  });
  it("hit tests the topmost unlocked layer with padding", () => {
    const bottom = mark({ id: "B" }), top = mark({ id: "T", points: [{ x: 0.5, y: 0.5 }, { x: 0.9, y: 0.9 }] });
    expect(hitTest([bottom, top], { x: 0.55, y: 0.55 }, 2, null, 16 / 9)?.id).toBe("T");
    expect(hitTest([bottom, top], { x: 0.21, y: 0.21 }, 2, null, 16 / 9)?.id).toBe("B");
    expect(hitTest([bottom, top], { x: 0.05, y: 0.9 }, 2, null, 16 / 9)).toBeNull();
    expect(hitTest([mark({ isLocked: true })], { x: 0.3, y: 0.3 }, 2, null, 16 / 9)).toBeNull();
  });
  it("finds the nearest handle within 22 px", () => {
    const frame = { x: 0, y: 0, width: 1000, height: 500 };
    expect(handleIndexAt(mark(), { x: 610, y: 305 }, frame, 2, null)).toBe(1);
    expect(handleIndexAt(mark(), { x: 700, y: 400 }, frame, 2, null)).toBeNull();
  });
  it("edits polygon topology in every keyframe", () => {
    const zone = mark({ tool: "zone", points: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }], keyframes: [{ id: "k", time: 1, points: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }] }] });
    const inserted = insertPolygonCorner(zone, 0);
    expect(inserted.points).toHaveLength(4); expect(inserted.points[1]).toEqual({ x: 0.5, y: 0 }); expect(inserted.keyframes[0]!.points).toHaveLength(4);
    expect(removePolygonCorner(inserted, 1).points).toHaveLength(3);
    expect(removePolygonCorner(zone, 1).points).toHaveLength(3);
  });
  it("renders connections only through confirmed players", () => {
    const links = [motion([[1, 0.1], [3, 0.3]], { referenceBox: { x: 0.1, y: 0.4, width: 0.1, height: 0.2 } }), motion([[1, 0.6], [1.5, 0.6]], { referenceBox: { x: 0.6, y: 0.4, width: 0.1, height: 0.2 } })];
    const connection = mark({ tool: "connection", points: [{ x: 0.15, y: 0.6 }, { x: 0.65, y: 0.6 }], linkedPlayers: links });
    expect(renderedPoints(connection, 1.2)).toHaveLength(2);
    expect(renderedPoints(connection, 2.5)).toHaveLength(1);
    expect(hasMotion(connection, 2.5)).toBe(false);
  });
});

describe("viewport, loupe and hull", () => {
  it("eases the zoom over the ramp and centres on the focus", () => {
    const zoom = mark({ tool: "zoom", points: [{ x: 0.5, y: 0.5 }], start: 0, end: 4, zoomScale: 2, zoomRamp: 1 });
    const frame = { x: 0, y: 0, width: 1000, height: 500 };
    expect(zoomTransform([zoom], 0, frame, frame)[0]).toBe(1);
    const full = zoomTransform([zoom], 2, frame, frame);
    expect(full[0]).toBe(2); expect(full[4]).toBeCloseTo(-500); expect(full[5]).toBeCloseTo(-250);
    expect(zoomTransform([zoom], 0.5, frame, frame)[0]).toBeCloseTo(1.5);
  });
  it("clamps the lens inside the bounds", () => {
    const g = loupeGeometry({ magnification: 2, diameter: 0.2, offset: { x: 0, y: -0.5 } }, { x: 100, y: 100 }, { x: 0, y: 0, width: 1000, height: 500 }, { x: 0, y: 0, width: 1000, height: 500 });
    expect(g!.radius).toBe(100); expect(g!.center.y).toBe(100); expect(g!.sourceRadius).toBe(50);
  });
  it("builds a convex hull", () => {
    expect(convexHull([{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }, { x: 0.5, y: 0.5 }])).toHaveLength(4);
  });
});
