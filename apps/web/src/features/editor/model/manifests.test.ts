import { describe, expect, it } from "vitest";
import type { MatchEvent, Recording } from "@/domain";
import { clipsForEvents, eventWindowClip, fullMatchClips, goalsSummaryClips, mergeOverlapping } from "./manifests";

const recording = (over: Partial<Recording>): Recording => ({ id: crypto.randomUUID(), projectID: "P", localPath: "x.mp4", name: "", createdAt: "2026-01-01T00:00:00Z", duration: 7200, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, segmentIndex: 0, endedReason: "user", recordedAt: "", timezoneIdentifier: "UTC", utcOffsetSeconds: 0, serverVersion: null, needsSync: false, mutationID: "", ...over });
const event = (over: Partial<MatchEvent>): MatchEvent => ({ id: crypto.randomUUID(), projectID: "P", kind: "Goal", note: "", occurredAt: "", recordingID: null, offsetSeconds: 0, preRollSeconds: 15, postRollSeconds: 5, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: false, mutationID: "", ...over });

describe("manifests", () => {
  it("full match covers every recording in capture order", () => {
    const first = recording({ segmentIndex: 0, duration: 3000 });
    const second = recording({ segmentIndex: 1, duration: 2800.4 });
    const gone = recording({ segmentIndex: 2, pendingDeletion: true });
    const clips = fullMatchClips([second, gone, first]);
    expect(clips.map((c) => c.recordingID)).toEqual([first.id, second.id]);
    expect(clips[1]!.endSeconds).toBe(2800.4);
    expect(fullMatchClips([recording({ duration: 0 })])[0]!.endSeconds).toBe(0.1);
  });

  it("goal windows clamp to the recording and merge overlaps", () => {
    const r = recording({ duration: 100 });
    const early = event({ recordingID: r.id, offsetSeconds: 5 });
    const late = event({ recordingID: r.id, offsetSeconds: 98 });
    const overlapping = event({ recordingID: r.id, offsetSeconds: 12 });
    const shot = event({ recordingID: r.id, offsetSeconds: 50, kind: "Shot" });
    const clips = goalsSummaryClips([r], [late, overlapping, early, shot]);
    expect(clips.map((c) => [c.startSeconds, c.endSeconds])).toEqual([[0, 17], [83, 100]]);
  });

  it("event windows include preceding context segments", () => {
    const context = recording({ segmentIndex: 0, duration: 10 });
    const active = recording({ segmentIndex: 1, duration: 8 });
    const goal = event({ recordingID: active.id, offsetSeconds: 2, preRollSeconds: 6, postRollSeconds: 5, contextRecordingIDs: [context.id] });
    const clips = clipsForEvents([goal], [context, active]);
    expect(clips.map((c) => [c.recordingID, c.startSeconds, c.endSeconds])).toEqual([[context.id, 4, 10], [active.id, 0, 7]]);
    expect(eventWindowClip(active, goal)).toMatchObject({ recordingID: active.id, startSeconds: 0, endSeconds: 7 });
  });

  it("merges only adjacent ranges of the same recording", () => {
    const a = { id: "1", recordingID: "A", startSeconds: 0, endSeconds: 5, rate: 1, annotations: [] };
    const b = { ...a, id: "2", startSeconds: 5, endSeconds: 9 };
    const c = { ...a, id: "3", recordingID: "B", startSeconds: 0, endSeconds: 1 };
    expect(mergeOverlapping([a, b, c]).map((x) => [x.recordingID, x.startSeconds, x.endSeconds])).toEqual([["A", 0, 9], ["B", 0, 1]]);
  });
});
