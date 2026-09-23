import { describe, expect, it } from "vitest";
import type { CompositionClip } from "@/domain/records";
import { createAnalysisEngine } from "./engine";
import { newAnnotation } from "./annotation";

const clip = (): CompositionClip => ({ id: "C", recordingID: "R", startSeconds: 0, endSeconds: 10, rate: 1, annotations: [] });

describe("AnalysisEngine", () => {
  it("inserts, selects and undoes/redoes", () => {
    const engine = createAnalysisEngine(clip());
    const mark = engine.getState().insertMark(newAnnotation("arrow", [{ x: 0.1, y: 0.1 }, { x: 0.5, y: 0.5 }], 1, 5), 1);
    expect(engine.getState().clip.annotations).toHaveLength(1);
    expect(engine.getState().selectedID).toBe(mark.id);
    expect(engine.getState().tool).toBe("select");
    engine.getState().undo();
    expect(engine.getState().clip.annotations).toHaveLength(0);
    expect(engine.getState().selectedID).toBeNull();
    engine.getState().redo();
    expect(engine.getState().clip.annotations).toHaveLength(1);
  });
  it("applies zoom defaults and player ring defaults", () => {
    const engine = createAnalysisEngine(clip());
    const zoom = engine.getState().insertMark(newAnnotation("zoom", [{ x: 0.5, y: 0.5 }], 1, 3), 1);
    expect(zoom.zoomScale).toBe(2); expect(zoom.zoomRamp).toBe(0.35);
    const player = engine.getState().insertMark(newAnnotation("player", [{ x: 0.1, y: 0.1 }, { x: 0.2, y: 0.4 }], 1, 3), 1);
    expect(player.effect).toBe("radar");
  });
  it("respects locks for layer operations and records one undo per change", () => {
    const engine = createAnalysisEngine(clip());
    const mark = engine.getState().insertMark(newAnnotation("line", [{ x: 0, y: 0 }, { x: 1, y: 1 }], 1, 5), 1);
    engine.getState().toggleLocked(mark.id);
    engine.getState().updateSelected((m) => ({ ...m, width: 0.02 }));
    expect(engine.getState().clip.annotations[0]!.width).toBe(0.006);
    engine.getState().deleteLayer(mark.id);
    expect(engine.getState().clip.annotations).toHaveLength(1);
    engine.getState().toggleLocked(mark.id);
    engine.getState().deleteLayer(mark.id);
    expect(engine.getState().clip.annotations).toHaveLength(0);
    expect(engine.getState().undoStack).toHaveLength(4);
  });
  it("adds, steps and deletes keyframes", () => {
    const engine = createAnalysisEngine(clip());
    engine.getState().insertMark(newAnnotation("rectangle", [{ x: 0.1, y: 0.1 }, { x: 0.3, y: 0.3 }], 1, 5), 1);
    expect(engine.getState().setMotionMode("keyframes", 2)).toBe("done");
    expect(engine.getState().clip.annotations[0]!.keyframes.map((k) => k.time)).toEqual([1, 2]);
    engine.getState().addKeyframe(4);
    expect(engine.getState().clip.annotations[0]!.keyframes).toHaveLength(3);
    expect(engine.getState().selectedKeyframe).toBeTruthy();
    expect(engine.getState().stepKeyframe(-1, 4)?.time).toBe(2);
    engine.getState().deleteKeyframe(2);
    expect(engine.getState().clip.annotations[0]!.keyframes).toHaveLength(2);
  });
  it("reorders, duplicates and renames layers", () => {
    const engine = createAnalysisEngine(clip());
    const a = engine.getState().insertMark(newAnnotation("line", [{ x: 0, y: 0 }, { x: 1, y: 1 }], 1, 5), 1);
    const b = engine.getState().insertMark(newAnnotation("arrow", [{ x: 0, y: 0 }, { x: 1, y: 1 }], 1, 5), 1);
    engine.getState().reorder(a.id, 1);
    expect(engine.getState().clip.annotations.map((m) => m.id)).toEqual([b.id, a.id]);
    engine.getState().duplicate();
    expect(engine.getState().clip.annotations).toHaveLength(3);
    expect(engine.getState().clip.annotations[2]!.points[0]!.x).toBeCloseTo(0.025);
    engine.getState().rename(a.id, "Press");
    expect(engine.getState().clip.annotations.find((m) => m.id === a.id)!.layerName).toBe("Press");
  });
  it("builds polygons from construction points", () => {
    const engine = createAnalysisEngine(clip());
    engine.getState().chooseTool("zone");
    engine.getState().appendConstructionPoint({ x: 0.1, y: 0.1 });
    engine.getState().appendConstructionPoint({ x: 0.5, y: 0.1 });
    expect(engine.getState().finishConstruction(1)).toBeNull();
    engine.getState().appendConstructionPoint({ x: 0.5, y: 0.5 });
    const result = engine.getState().finishConstruction(1);
    expect(result?.mark.tool).toBe("zone");
    expect(result?.mark.end).toBe(7);
    expect(engine.getState().constructionPoints).toEqual([]);
  });
  it("clamps timeline edits to the clip", () => {
    const engine = createAnalysisEngine(clip());
    const mark = engine.getState().insertMark(newAnnotation("line", [{ x: 0, y: 0 }, { x: 1, y: 1 }], 1, 5), 1);
    engine.getState().applyTimelineEdit(mark.id, { kind: "move", delta: 20 });
    const moved = engine.getState().clip.annotations[0]!;
    expect(moved.end).toBe(10); expect(moved.start).toBe(6);
  });
});
