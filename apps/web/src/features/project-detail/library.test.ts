import { describe, expect, it } from "vitest";
import type { MatchEvent, Recording } from "@/domain";
import { presetClips } from "./library";

const recording = (id: string, createdAt: string, duration: number): Recording => ({
  id, projectID: "P", localPath: `${id}.mp4`, name: "", createdAt, duration, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
  segmentIndex: 0, endedReason: "user", recordedAt: createdAt, timezoneIdentifier: "UTC", utcOffsetSeconds: 0, serverVersion: null, needsSync: false, mutationID: "M",
});
const goal = (recordingID: string | null, offset: number, kind = "Goal"): MatchEvent => ({ id: `${kind}${offset}`, projectID: "P", kind, note: "", occurredAt: "", recordingID, offsetSeconds: offset, preRollSeconds: 15, postRollSeconds: 5, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: false, mutationID: "M" });

describe("presetClips", () => {
  const a = recording("A", "2026-01-01T10:00:00Z", 100);
  const b = recording("B", "2026-01-01T11:00:00Z", 50);

  it("full match covers every recording oldest first", () => {
    const clips = presetClips("full", [b, a], []);
    expect(clips.map((c) => [c.recordingID, c.startSeconds, c.endSeconds])).toEqual([["A", 0, 100], ["B", 0, 50]]);
  });

  it("goals summary clamps pre/post roll to the recording", () => {
    const clips = presetClips("goals", [a], [goal("A", 10), goal("A", 98), goal("A", 50, "Shot"), goal(null, 20)]);
    expect(clips.map((c) => [c.startSeconds, c.endSeconds])).toEqual([[0, 15], [83, 100]]);
  });

  it("custom starts from the oldest recording", () => {
    expect(presetClips("custom", [b, a], []).map((c) => c.recordingID)).toEqual(["A"]);
    expect(presetClips("custom", [], [])).toEqual([]);
  });
});
