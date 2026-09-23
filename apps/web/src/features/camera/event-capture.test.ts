import { describe, expect, it } from "vitest";
import { addEvent, advance, emptyEventCapture, endNow, endOffset, finishSegment, remaining, selectedEvent, type PendingEvent } from "./event-capture";

const event = (id: string, offset: number, postRoll = 10, recordingID = "R1"): PendingEvent => ({ id, recordingID, kind: "Shot", offsetSeconds: offset, postRollSeconds: postRoll });

describe("event capture countdown", () => {
  it("counts down on the movie clock and expires at the post-roll", () => {
    let state = addEvent(emptyEventCapture, event("A", 12));
    expect(remaining(state, state.active[0]!)).toBe(10);
    state = advance(state, "R1", 18);
    expect(remaining(state, state.active[0]!)).toBe(4);
    state = advance(state, "R1", 22);
    expect(state.active).toHaveLength(0);
  });

  it("ignores offsets from another recording and never runs backwards", () => {
    let state = addEvent(emptyEventCapture, event("A", 12));
    state = advance(state, "R2", 50);
    expect(remaining(state, state.active[0]!)).toBe(10);
    state = advance(state, "R1", 15);
    state = advance(state, "R1", 13);
    expect(state.offset).toBe(15);
  });

  it("keeps separate deadlines for overlapping windows and selects the newest", () => {
    let state = addEvent(emptyEventCapture, event("A", 10, 10));
    state = addEvent(state, event("B", 14, 5));
    expect(selectedEvent(state)?.id).toBe("B");
    expect(endOffset(state, "R1")).toBe(20);
    state = advance(state, "R1", 19.5);
    expect(state.active.map((e) => e.id)).toEqual(["A"]);
    expect(selectedEvent(state)?.id).toBe("A");
  });

  it("end now shortens only that event and leaves the others pending", () => {
    let state = addEvent(emptyEventCapture, event("A", 10, 10));
    state = addEvent(state, event("B", 12, 10));
    const result = endNow(state, "A", "R1", 15);
    expect(result?.shortened).toEqual({ id: "A", postRollSeconds: 5 });
    expect(result?.state.active.map((e) => e.id)).toEqual(["B"]);
    expect(endNow(state, "missing", "R1", 15)).toBeNull();
  });

  it("finishing a segment closes its windows at the file end without shortening completed ones", () => {
    let state = addEvent(emptyEventCapture, event("A", 2, 10));
    state = addEvent(state, event("B", 30, 4, "R2"));
    const result = finishSegment(state, "R1", 8);
    expect(result.shortened).toEqual([{ id: "A", postRollSeconds: 6 }]);
    expect(result.state.active.map((e) => e.id)).toEqual(["B"]);
    expect(finishSegment(addEvent(emptyEventCapture, event("C", 0, 5)), "R1", 20).shortened).toEqual([]);
  });
});
