/* Port of FieldPlacementInteractionTests.swift (the cases that do not depend on the analysis viewport). */
import { describe, expect, it } from "vitest";
import { DEFAULT_VIEWPORT, FieldPlacementTouchState, loupeCenter, navigateViewport, nudgePoint, sourcePoint, viewportFrame, type TouchAction } from "./placement";

describe("FieldPlacementInteraction", () => {
  it("nudges use source pixels in landscape, portrait and offscreen", () => {
    for (const size of [{ width: 1920, height: 1080 }, { width: 3840, height: 2160 }, { width: 1080, height: 1920 }]) {
      for (const point of [{ x: 0.4, y: 0.6 }, { x: -0.2, y: 1.3 }]) {
        const moved = nudgePoint(point, 1, -1, size);
        expect((moved.x - point.x) * size.width).toBeCloseTo(1, 5);
        expect((moved.y - point.y) * size.height).toBeCloseTo(-1, 5);
        const restored = nudgePoint(moved, -1, 1, size);
        expect(restored.x).toBeCloseTo(point.x, 5);
        expect(restored.y).toBeCloseTo(point.y, 5);
      }
    }
    expect(nudgePoint({ x: 0, y: 0 }, 1, 1, { width: 0, height: 0 })).toEqual({ x: 0, y: 0 });
  });

  it("pinch and pan keep the source point under moving fingers", () => {
    const fitted = { x: 0, y: 80, width: 390, height: 219.375 };
    const start = { zoom: 2, center: { x: 0.3, y: 0.6 } };
    const finger = { x: 120, y: 170 }, moved = { x: 160, y: 200 };
    const source = sourcePoint(finger, viewportFrame(start, fitted), true);
    const next = navigateViewport(start, 1.8, finger, moved, fitted);
    const after = sourcePoint(moved, viewportFrame(next, fitted), true);
    expect(next.zoom).toBeCloseTo(3.6, 4);
    expect(after.x).toBeCloseTo(source.x, 4); expect(after.y).toBeCloseTo(source.y, 4);
    const panned = navigateViewport(start, 1, finger, moved, fitted);
    expect(viewportFrame(panned, fitted).x - viewportFrame(start, fitted).x).toBeCloseTo(40, 4);
    expect(viewportFrame(panned, fitted).y - viewportFrame(start, fitted).y).toBeCloseTo(30, 4);
  });

  it("zoom limits, fit and offscreen coordinates", () => {
    const fitted = { x: 0, y: 50, width: 400, height: 225 }, center = { x: 200, y: 162.5 };
    expect(navigateViewport(DEFAULT_VIEWPORT, 100, center, center, fitted).zoom).toBe(8);
    const out = navigateViewport(DEFAULT_VIEWPORT, 0.01, center, center, fitted);
    expect(out.zoom).toBe(0.25);
    expect(sourcePoint({ x: 0, y: 0 }, viewportFrame(out, fitted), true).x).toBeLessThan(0);
    expect(viewportFrame(DEFAULT_VIEWPORT, fitted)).toEqual(fitted);
    expect(navigateViewport(DEFAULT_VIEWPORT, NaN, center, center, fitted)).toEqual(DEFAULT_VIEWPORT);
  });

  it("adding a second finger rolls back the corner and the remaining finger cannot place", () => {
    const state = new FieldPlacementTouchState();
    const a = { x: 100, y: 100 }, b = { x: 200, y: 100 };
    expect(state.update([a])).toEqual<TouchAction[]>([{ type: "beginCorner", location: a }]);
    expect(state.update([b])).toEqual<TouchAction[]>([{ type: "moveCorner", location: b }]);
    expect(state.update([a, b])).toEqual<TouchAction[]>([{ type: "cancelCorner" }, { type: "beginNavigation" }]);
    expect(state.update([{ x: 80, y: 120 }, { x: 240, y: 120 }])).toEqual<TouchAction[]>([{ type: "navigate", scale: 1.6, from: { x: 150, y: 100 }, to: { x: 160, y: 120 } }]);
    expect(state.update([b])).toEqual<TouchAction[]>([{ type: "endNavigation" }]);
    expect(state.update([a])).toEqual([]);
    expect(state.update([])).toEqual([]);
    expect(state.update([a])).toEqual<TouchAction[]>([{ type: "beginCorner", location: a }]);
    expect(state.update([])).toEqual<TouchAction[]>([{ type: "endCorner" }]);
  });

  it("direct two-finger start and cancellation never commit a corner", () => {
    const state = new FieldPlacementTouchState();
    expect(state.update([{ x: 0, y: 0 }, { x: 100, y: 0 }])).toEqual<TouchAction[]>([{ type: "beginNavigation" }]);
    expect(state.cancel()).toEqual<TouchAction[]>([{ type: "endNavigation" }]);
    expect(state.update([{ x: 0, y: 0 }])).toEqual<TouchAction[]>([{ type: "beginCorner", location: { x: 0, y: 0 } }]);
    expect(state.cancel()).toEqual<TouchAction[]>([{ type: "cancelCorner" }]);
    expect(state.update([])).toEqual([]);
  });

  it("loupe stays visible and away from the finger at edges and in landscape", () => {
    const size = { width: 112, height: 100 };
    for (const bounds of [{ x: 0, y: 0, width: 390, height: 330 }, { x: 0, y: 0, width: 700, height: 140 }]) {
      for (const x of [bounds.x + 2, bounds.x + bounds.width / 2, bounds.x + bounds.width - 2]) for (const y of [bounds.y + 2, bounds.y + bounds.height / 2, bounds.y + bounds.height - 2]) {
        const finger = { x, y }, center = loupeCenter(finger, bounds, size);
        const rect = { x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height };
        expect(rect.x >= bounds.x && rect.y >= bounds.y && rect.x + rect.width <= bounds.x + bounds.width && rect.y + rect.height <= bounds.y + bounds.height).toBe(true);
        const inflated = { x: rect.x - 30, y: rect.y - 30, width: rect.width + 60, height: rect.height + 60 };
        expect(finger.x >= inflated.x && finger.x <= inflated.x + inflated.width && finger.y >= inflated.y && finger.y <= inflated.y + inflated.height).toBe(false);
      }
    }
  });
});
