import { describe, expect, it } from "vitest";
import { beginSegment, createRollingBuffer, endEventCapture, isDue, promote, retainedSegments, rotate } from "./rolling-buffer";

describe("rolling buffer retention", () => {
  it("keeps at most the previous and the active segment while nothing is tagged", () => {
    let buffer = beginSegment(createRollingBuffer(5), "S1");
    expect(isDue(buffer, 4.9)).toBe(false);
    expect(isDue(buffer, 5)).toBe(true);
    let rotation = rotate(buffer, "buffer-rotation");
    expect(rotation).toMatchObject({ save: [], discard: [], continues: true });
    buffer = beginSegment(rotation.buffer, "S2");
    rotation = rotate(buffer, "buffer-rotation");
    expect(rotation.discard).toEqual(["S1"]);
    buffer = beginSegment(rotation.buffer, "S3");
    expect(retainedSegments(buffer)).toEqual(["S2", "S3"]);
  });

  it("promotes the context segment and extends the active file to the post-roll", () => {
    let buffer = beginSegment(rotate(beginSegment(createRollingBuffer(5), "S1"), "buffer-rotation").buffer, "S2");
    const promoted = promote(buffer, 2, 12);
    expect(promoted.contextRecordingIDs).toEqual(["S1"]);
    expect(promoted.buffer.deadline).toBe(12);
    buffer = promoted.buffer;
    expect(isDue(buffer, 5)).toBe(false);
    const rotation = rotate(buffer, "buffer-rotation");
    expect(rotation.save).toEqual(["S1", "S2"]);
    expect(rotation.discard).toEqual([]);
    expect(rotation.continues).toBe(true);
    expect(retainedSegments(rotation.buffer)).toEqual([]);
  });

  it("overlapping events keep the latest deadline", () => {
    const buffer = promote(promote(beginSegment(createRollingBuffer(10), "S1"), 3, 13).buffer, 4, 9).buffer;
    expect(buffer.deadline).toBe(13);
  });

  it("end now shortens the file or closes it immediately", () => {
    const buffer = promote(beginSegment(createRollingBuffer(10), "S1"), 3, 13).buffer;
    expect(endEventCapture(buffer, 6, 9).deadline).toBe(9);
    expect(endEventCapture(buffer, 6, null).deadline).toBe(6);
    expect(endEventCapture(beginSegment(createRollingBuffer(10), "S2"), 6, null).deadline).toBe(10);
  });

  it("stopping an untagged buffer discards everything; stopping a promoted one saves it", () => {
    const untagged = beginSegment(rotate(beginSegment(createRollingBuffer(5), "S1"), "buffer-rotation").buffer, "S2");
    expect(rotate(untagged, "user")).toMatchObject({ save: [], discard: ["S1", "S2"], continues: false });
    const tagged = promote(untagged, 1, 6).buffer;
    expect(rotate(tagged, "interruption")).toMatchObject({ save: ["S1", "S2"], discard: [], continues: false });
  });
});
