import { describe, expect, it } from "vitest";
import type { CompositionClip, MatchEvent } from "@/domain";
import { makeSnapshot, snapshotEnd, snapshotStart } from "./geometry";
import { clipLabel, eventSnapshotInSegment, joinContinuousWindows, outputTimeAt, segmentContaining, segmentDuration, segmentEnd, segmentsForClips, sequenceDuration, sequenceEvents, sourceTimeAt, type SequenceSegment } from "./sequence";

const segment = (over: Partial<SequenceSegment>): SequenceSegment => ({ id: crypto.randomUUID(), recordingID: "R", sourceStart: 0, sourceEnd: 10, rate: 1, start: 0, freezeDuration: null, ...over });
const clip = (over: Partial<CompositionClip>): CompositionClip => ({ id: crypto.randomUUID(), recordingID: "R", startSeconds: 0, endSeconds: 10, rate: 1, annotations: [], ...over });
const event = (over: Partial<MatchEvent>): MatchEvent => ({ id: crypto.randomUUID(), projectID: "P", kind: "Goal", note: "", occurredAt: "", recordingID: "R", offsetSeconds: 0, preRollSeconds: 0, postRollSeconds: 0, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: false, mutationID: "", ...over });

describe("sequence segments", () => {
  it("honour rate and freeze durations", () => {
    const fast = segment({ sourceStart: 8, sourceEnd: 20, rate: 2, start: 30 });
    expect(segmentDuration(fast)).toBe(6);
    expect(sourceTimeAt(fast, 33)).toBe(14);
    expect(outputTimeAt(fast, 14)).toBe(33);
    expect(sourceTimeAt(fast, 100)).toBe(20);
    const held = segment({ sourceStart: 4, sourceEnd: 4.02, start: 10, freezeDuration: 5 });
    expect(segmentDuration(held)).toBe(5);
    expect(sourceTimeAt(held, 12)).toBe(4);
    expect(segmentEnd(held)).toBe(15);
  });

  it("lays clips end to end with sub-second trims", () => {
    const segments = segmentsForClips([clip({ startSeconds: 0.25, endSeconds: 0.75 }), clip({ startSeconds: 100, endSeconds: 7300, rate: 4 }), clip({ freezeDuration: 3, startSeconds: 1, endSeconds: 1.02 })]);
    expect(segments.map((s) => s.start)).toEqual([0, 0.5, 0.5 + 1800]);
    expect(sequenceDuration(segments)).toBe(0.5 + 1800 + 3);
    expect(segmentContaining(0.5, segments)?.id).toBe(segments[1]!.id);
    expect(segmentContaining(99999, segments)?.id).toBe(segments[2]!.id);
    expect(segmentContaining(-1, segments)?.id).toBe(segments[0]!.id);
    expect(segmentContaining(0, [])).toBeNull();
  });
});

describe("event occurrences", () => {
  it("map speed and output offset", () => {
    const source = makeSnapshot({ offset: 12, preRoll: 4, postRoll: 6, kind: "Goal" });
    const s = segment({ sourceStart: 8, sourceEnd: 20, rate: 2, start: 30 });
    const mapped = eventSnapshotInSegment(s, source)!;
    expect(mapped.offset).toBe(32);
    expect(snapshotStart(mapped)).toBe(30);
    expect(snapshotEnd(mapped)).toBe(35);
    expect(mapped.id).toEqual({ eventID: source.id.eventID, clipID: s.id });
  });

  it("keep split windows visible on both sides of a cut and repeated clips separate", () => {
    const source = makeSnapshot({ offset: 12, preRoll: 4, postRoll: 6, kind: "Goal" });
    const before = eventSnapshotInSegment(segment({ sourceEnd: 10 }), source)!;
    const after = eventSnapshotInSegment(segment({ sourceStart: 10, sourceEnd: 20, start: 10 }), source)!;
    expect([snapshotStart(before), snapshotEnd(before)]).toEqual([8, 10]);
    expect([snapshotStart(after), snapshotEnd(after)]).toEqual([10, 18]);
    expect(before.id.clipID).not.toBe(after.id.clipID);
    const shot = makeSnapshot({ offset: 2, preRoll: 1, postRoll: 1, kind: "Shot" });
    const first = eventSnapshotInSegment(segment({ sourceEnd: 4 }), shot)!;
    const repeat = eventSnapshotInSegment(segment({ sourceEnd: 4, start: 4 }), shot)!;
    expect(repeat.offset - first.offset).toBe(4);
    expect(eventSnapshotInSegment(segment({ sourceStart: 5, sourceEnd: 8 }), shot)).toBeNull();
    expect(eventSnapshotInSegment(segment({ freezeDuration: 5 }), shot)).toBeNull();
  });

  it("join multiple cuts into one list entry while distinct events stay distinct", () => {
    const goal = event({ kind: "Goal", offsetSeconds: 10, preRollSeconds: 8, postRollSeconds: 8 });
    const shot = event({ kind: "Shot", offsetSeconds: 10, preRollSeconds: 8, postRollSeconds: 8 });
    const clips = [0, 1, 2, 3].map((i) => clip({ startSeconds: i * 5, endSeconds: (i + 1) * 5 }));
    const joined = sequenceEvents(clips, [goal, shot]);
    expect(joined).toHaveLength(2);
    expect(joined.map(clipLabel)).toEqual(["Clips 1–4", "Clips 1–4"]);
    expect(joined.map((e) => snapshotStart(e.snapshot))).toEqual([2, 2]);
    expect(joined.map((e) => snapshotEnd(e.snapshot))).toEqual([18, 18]);
    expect(joined[0]!.snapshot.id.clipID).toBe(clips[2]!.id);
  });

  it("do not bridge missing footage, repeats or speed changes", () => {
    const source = makeSnapshot({ offset: 10, preRoll: 8, postRoll: 8, kind: "Goal" });
    const before = eventSnapshotInSegment(segment({ sourceEnd: 10 }), source)!;
    for (const second of [segment({ sourceStart: 10, sourceEnd: 20, start: 15 }), segment({ sourceStart: 12, sourceEnd: 20, start: 10 }), segment({ sourceEnd: 10, start: 10 }), segment({ sourceStart: 10, sourceEnd: 20, rate: 2, start: 10 })]) {
      const after = eventSnapshotInSegment(second, source)!;
      const e = (snapshot: typeof before) => ({ event: event({}), firstClip: 1, lastClip: 1, snapshot });
      expect(joinContinuousWindows([e(before), e(after)])).toHaveLength(2);
    }
  });

  it("orders occurrences by output position across recordings", () => {
    const a = event({ recordingID: "A", offsetSeconds: 5, preRollSeconds: 1, postRollSeconds: 1 });
    const b = event({ recordingID: "B", offsetSeconds: 5, preRollSeconds: 1, postRollSeconds: 1, kind: "Shot" });
    const clips = [clip({ recordingID: "B" }), clip({ recordingID: "A" })];
    expect(sequenceEvents(clips, [a, b]).map((e) => e.event.kind)).toEqual(["Shot", "Goal"]);
  });
});
