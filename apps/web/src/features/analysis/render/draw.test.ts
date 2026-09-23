import { beforeAll, describe, expect, it } from "vitest";
import type { AnalysisAnnotation, AnalysisDrawingTool, AnnotationEffect } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import { drawAnnotations } from "./draw";
import { drawEditorOverlay } from "./editor-overlay";
import { toolRegistry, toolbarTools } from "./toolRegistry";

/* jsdom has no canvas: a recording fake context checks every tool and effect renders without
   touching the DOM and balances save/restore. Path2D is polyfilled with a no-op recorder. */

class FakePath { addPath() {} moveTo() {} lineTo() {} closePath() {} ellipse() {} rect() {} roundRect() {} quadraticCurveTo() {} arc() {} }

function fakeContext() {
  const calls: string[] = [];
  let depth = 0;
  const gradient = { addColorStop() {} };
  const target: Record<string, unknown> = {
    save() { depth += 1; calls.push("save"); }, restore() { depth -= 1; calls.push("restore"); },
    measureText: (text: string) => ({ width: text.length * 8, actualBoundingBoxAscent: 10, actualBoundingBoxDescent: 3 }),
    createLinearGradient: () => gradient,
    drawImage() { calls.push("drawImage"); },
    get depth() { return depth; },
  };
  return new Proxy(target, {
    get(t, key) {
      if (key in t) return t[key as string];
      return (...args: unknown[]) => { calls.push(`${String(key)}${args.length ? "" : ""}`); };
    },
    set(t, key, value) { t[key as string] = value; return true; },
  }) as unknown as CanvasRenderingContext2D & { depth: number };
}

const mark = (tool: AnalysisDrawingTool, overrides: Partial<AnalysisAnnotation> = {}): AnalysisAnnotation => ({
  id: `M-${tool}`, tool, points: tool === "zone" ? [{ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.2 }, { x: 0.6, y: 0.7 }] : tool === "pen" ? [{ x: 0.1, y: 0.1 }, { x: 0.2, y: 0.3 }, { x: 0.4, y: 0.2 }] : [{ x: 0.2, y: 0.2 }, { x: 0.6, y: 0.6 }],
  color: { red: 1, green: 0.5, blue: 0 }, width: 0.006, text: "Hello\nWorld", start: 0, end: 10, fade: true, keyframes: [], ...overrides,
});

const plane: GroundCalibration = { mode: "plane", points: [{ x: 0.2, y: 0.3 }, { x: 0.8, y: 0.3 }, { x: 0.95, y: 0.9 }, { x: 0.05, y: 0.9 }], lengthMeters: 40.32, widthMeters: 16.5, referenceTime: 0, imageAspectRatio: 16 / 9, fixedCamera: true };

beforeAll(() => { (globalThis as unknown as { Path2D: unknown }).Path2D = FakePath; });

describe("drawAnnotations", () => {
  const size = { width: 1280, height: 720 };
  it("renders every toolbar tool with every offered effect without leaking canvas state", () => {
    for (const tool of [...toolbarTools, "spotlight", "trajectory"] as AnalysisDrawingTool[]) {
      for (const effect of toolRegistry[tool].effects(mark(tool))) {
        const ctx = fakeContext();
        drawAnnotations(ctx, [mark(tool, { effect: effect as AnnotationEffect, showsDistance: true, lineStyle: { pattern: "dashed", start: "arrow", end: "circle" } })], 2, size, { ground: plane });
        expect(ctx.depth, `${tool}/${effect}`).toBe(0);
      }
    }
  });
  it("skips hidden, out-of-range and zoom layers but draws grounded players on a plane", () => {
    const ctx = fakeContext();
    drawAnnotations(ctx, [mark("zoom"), mark("line", { isHidden: true }), mark("line", { start: 5, end: 6 }), mark("player", { grounded: true, effect: "radar" })], 2, size, { ground: plane });
    expect(ctx.depth).toBe(0);
  });
  it("draws loupes from a source and the editor overlay", () => {
    const ctx = fakeContext();
    drawAnnotations(ctx, [mark("loupe", { points: [{ x: 0.5, y: 0.5 }], loupeStyle: { magnification: 2, diameter: 0.2, offset: { x: 0, y: -0.2 } } })], 2, size, { source: {} as CanvasImageSource, editing: true });
    drawEditorOverlay(ctx, { frame: { x: 0, y: 0, ...size }, bounds: { x: 0, y: 0, ...size }, time: 2, ground: null, selected: mark("zoom", { points: [{ x: 0.5, y: 0.5 }], zoomScale: 2 }), detections: [{ x: 0.1, y: 0.1, width: 0.1, height: 0.2 }], selectedPlayer: null, constructionPoints: [{ x: 0.3, y: 0.3 }, { x: 0.5, y: 0.5 }], anchors: [{ id: 0, name: "A", point: { x: 0.4, y: 0.4 }, lastSeen: null, isMissing: true, title: "1 · A" }], correctingAnchor: 0 });
    expect(ctx.depth).toBe(0);
  });
});
