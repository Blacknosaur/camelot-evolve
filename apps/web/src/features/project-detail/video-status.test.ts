import { describe, expect, it } from "vitest";
import type { MatchEvent, Recording, VideoComposition } from "@/domain";
import { compositionIsEditable, compositionStats, compositionStatus, recordingDeletionMessage, recordingStatus, recordingSubtitle, remoteMediaURL, uploadProgressLabel } from "./video-status";

const recording = (id: string, overrides: Partial<Recording> = {}): Recording => ({
  id, projectID: "P", localPath: `${id}.mp4`, name: "", createdAt: "2026-01-01T00:00:00Z", duration: 120, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
  segmentIndex: 0, endedReason: "user", recordedAt: "2026-01-01T00:00:00Z", timezoneIdentifier: "UTC", utcOffsetSeconds: 0, serverVersion: null, needsSync: false, mutationID: "M", ...overrides,
});
const local = (r: Recording) => r.localPath !== "";

describe("recordingStatus", () => {
  it("reports on-device, synced and progress states", () => {
    expect(recordingStatus(recording("A"), { hasLocalVideo: true }).text).toBe("On device");
    expect(recordingStatus(recording("A", { uploadState: "uploaded" }), { hasLocalVideo: true })).toMatchObject({ text: "Synced", icon: "CloudCheck" });
    expect(recordingStatus(recording("A", { uploadState: "uploading", uploadedBytes: 50 }), { hasLocalVideo: true, localBytes: 200 }).text).toBe("Uploading 25%");
    expect(recordingStatus(recording("A", { uploadState: "uploading", uploadedBytes: 50 }), { hasLocalVideo: true }).text).toBe("Uploading");
  });
  it("distinguishes cloud-only from unavailable", () => {
    expect(recordingStatus(recording("A", { localPath: "", shareURL: "http://localhost:3000/api/watch/abc" }), { hasLocalVideo: false }).text).toBe("In the cloud");
    expect(recordingStatus(recording("A", { localPath: "" }), { hasLocalVideo: false })).toMatchObject({ text: "Unavailable", icon: "Warning" });
  });
});

describe("remoteMediaURL", () => {
  it("rewrites the watch path to the public media path", () => {
    expect(remoteMediaURL({ shareURL: "http://localhost:3000/api/watch/tok" })).toBe("http://localhost:3000/api/public/media/tok");
    expect(remoteMediaURL({ shareURL: null })).toBeNull();
    expect(remoteMediaURL({ shareURL: "not a url" })).toBeNull();
  });
});

describe("uploadProgressLabel", () => {
  it("caps at 100 and falls back to the prefix", () => {
    expect(uploadProgressLabel(300, 200, "Uploading")).toBe("Uploading 100%");
    expect(uploadProgressLabel(0, 200, "Paused")).toBe("Paused");
  });
});

describe("recordingSubtitle", () => {
  const date = () => "Today, 10:00";
  it("labels imports and captures when unnamed", () => {
    expect(recordingSubtitle(recording("A", { endedReason: "import" }), date)).toBe("Imported video");
    expect(recordingSubtitle(recording("A"), date)).toBe("Recorded with Camelot");
    expect(recordingSubtitle(recording("A", { name: "Final" }), date)).toBe("Today, 10:00");
  });
});

describe("compositionStatus", () => {
  const base: Pick<VideoComposition, "uploadState" | "uploadedBytes"> = { uploadState: "local", uploadedBytes: 0 };
  it("describes render and share state with the clip count", () => {
    expect(compositionStatus(base, 1, null).text).toBe("Ready to render · 1 clip");
    expect(compositionStatus(base, 3, 1000).text).toBe("Rendered · 3 clips");
    expect(compositionStatus({ ...base, uploadState: "uploaded" }, 2, 1000)).toMatchObject({ text: "Shared · 2 clips", icon: "Link" });
    expect(compositionStatus({ ...base, uploadState: "uploading", uploadedBytes: 500 }, 2, 1000).text).toBe("Uploading 50%");
    expect(compositionStatus({ ...base, uploadState: "failed" }, 2, 1000).text).toBe("Waiting · 2 clips");
  });
});

describe("compositionStats", () => {
  const a = recording("A", { duration: 100 });
  const events: MatchEvent[] = [
    { id: "1", projectID: "P", kind: "Goal", note: "", occurredAt: "", recordingID: "A", offsetSeconds: 12, preRollSeconds: 15, postRollSeconds: 5, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: false, mutationID: "M" },
    { id: "2", projectID: "P", kind: "Shot", note: "", occurredAt: "", recordingID: "A", offsetSeconds: 50, preRollSeconds: 10, postRollSeconds: 10, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: false, mutationID: "M" },
  ];
  const clips = [{ id: "C", recordingID: "A", startSeconds: 10, endSeconds: 20, rate: 2, annotations: [] }];
  it("sums playback duration, counts events inside clips and picks a thumbnail frame", () => {
    const stats = compositionStats({ clips }, events, [a], local);
    expect(stats.duration).toBe(5);
    expect(stats.eventCount).toBe(1);
    expect(stats.clipCount).toBe(1);
    expect(stats.thumbnail.recording?.id).toBe("A");
    expect(stats.thumbnail.seconds).toBeCloseTo(10.25);
  });
  it("is editable only when every source is local", () => {
    expect(compositionIsEditable(clips, [a], local)).toBe(true);
    expect(compositionIsEditable(clips, [recording("A", { localPath: "" })], local)).toBe(false);
    expect(compositionIsEditable([], [a], local)).toBe(false);
  });
});

describe("recordingDeletionMessage", () => {
  it("pluralises dependent edits", () => {
    expect(recordingDeletionMessage(0)).not.toContain("video edit");
    expect(recordingDeletionMessage(1)).toContain("1 video edit that");
    expect(recordingDeletionMessage(2)).toContain("2 video edits that");
  });
});
