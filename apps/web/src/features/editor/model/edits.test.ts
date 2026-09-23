import { describe, expect, it } from "vitest";
import type { CompositionClip, VideoComposition } from "@/domain";
import { compositionWithEdit, type EditHistory, duplicateClip, insertFreezeFrame, recordHistory, redoHistory, removeClip, reorderClip, setClipRate, splitClip, undoHistory, type EditorDocument } from "./edits";
import { sequenceDuration, segmentsForClips } from "./sequence";

const clip = (over: Partial<CompositionClip> = {}): CompositionClip => ({ id: crypto.randomUUID(), recordingID: "R", startSeconds: 0, endSeconds: 10, rate: 1, annotations: [], ...over });

describe("clip edits", () => {
  it("splits at a source time and refuses edges and holds", () => {
    const [a] = [clip()];
    const split = splitClip([a], a.id, 4)!;
    expect(split.clips.map((c) => [c.startSeconds, c.endSeconds])).toEqual([[0, 4], [4, 10]]);
    expect(split.clips[1]!.id).toBe(split.trailingID);
    expect(splitClip([a], a.id, 0.05)).toBeNull();
    expect(splitClip([clip({ freezeDuration: 2 })], a.id, 5)).toBeNull();
  });

  it("reorders, removes and keeps a selectable clip", () => {
    const clips = [clip({ startSeconds: 0 }), clip({ startSeconds: 1 }), clip({ startSeconds: 2 })];
    expect(reorderClip(clips, clips[0]!.id, 2)!.map((c) => c.startSeconds)).toEqual([1, 2, 0]);
    expect(reorderClip(clips, clips[1]!.id, 1)).toBeNull();
    const removed = removeClip(clips, clips[2]!.id)!;
    expect(removed.clips).toHaveLength(2);
    expect(removed.selectedClipID).toBe(clips[1]!.id);
    expect(removeClip([clips[0]!], clips[0]!.id)).toBeNull();
  });

  it("clamps speed to 0.25–4 and changes output duration", () => {
    const a = clip();
    expect(setClipRate([a], a.id, 8)![0]!.rate).toBe(4);
    expect(setClipRate([a], a.id, 0.1)![0]!.rate).toBe(0.25);
    expect(sequenceDuration(segmentsForClips(setClipRate([a], a.id, 0.25)!))).toBe(40);
    expect(setClipRate([a], a.id, 1)).toBeNull();
  });

  it("inserts a freeze frame that splits its parent and repeats clips", () => {
    const a = clip();
    const frozen = insertFreezeFrame([a], a.id, 4, 5, 10)!;
    expect(frozen.clips).toHaveLength(3);
    expect(frozen.clips[1]!.freezeDuration).toBe(5);
    expect(frozen.clips[1]!.startSeconds).toBe(4);
    expect(sequenceDuration(segmentsForClips(frozen.clips))).toBeCloseTo(15, 5);
    const atStart = insertFreezeFrame([a], a.id, 0, 2)!;
    expect(atStart.clips).toHaveLength(2);
    const doubled = duplicateClip([a], a.id)!;
    expect(doubled.clips.map((c) => c.startSeconds)).toEqual([0, 0]);
    expect(doubled.clips[1]!.id).not.toBe(a.id);
  });

  it("undo/redo is bounded and restores documents", () => {
    const doc = (n: number): EditorDocument => ({ clips: [clip({ startSeconds: n })], selectedClipID: "x", aspectRatio: "original", deletedEventIDs: [] });
    let history: EditHistory = { undo: [], redo: [] };
    for (let i = 0; i < 25; i += 1) history = recordHistory(history, doc(i));
    expect(history.undo).toHaveLength(20);
    const undone = undoHistory(history, doc(99))!;
    expect(undone.document.clips[0]!.startSeconds).toBe(24);
    expect(undone.history.redo[0]!.clips[0]!.startSeconds).toBe(99);
    const redone = redoHistory(undone.history, undone.document)!;
    expect(redone.document.clips[0]!.startSeconds).toBe(99);
    expect(redoHistory({ undo: [], redo: [] }, doc(0))).toBeNull();
  });

  it("invalidates rendered media only when footage or crop changes", () => {
    const a = clip();
    const saved: VideoComposition = { id: "C", projectID: "P", name: "Edit", kind: "custom", createdAt: "", clips: [a], aspectRatio: "original", uploadState: "uploaded", uploadedBytes: 100, shareURL: "https://x", pendingDeletion: false, serverVersion: 1, needsSync: false, mutationID: "m" };
    const renamed = compositionWithEdit(saved, [a], "original", "New name");
    expect(renamed.shareURL).toBe("https://x");
    expect(renamed.uploadState).toBe("uploaded");
    const cropped = compositionWithEdit(saved, [a], "9:16", "Edit");
    expect(cropped.shareURL).toBeNull();
    expect(cropped.uploadState).toBe("local");
    expect(compositionWithEdit(saved, [{ ...a, rate: 2 }], "original", "Edit").uploadedBytes).toBe(0);
  });
});
