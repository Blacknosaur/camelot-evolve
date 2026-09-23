import { describe, expect, it } from "vitest";
import type { MatchEvent, Recording, VideoComposition } from "@/domain";
import { filterProjects, projectPreview, projectSubtitle, projectSummary, sortProjects, toDateTimeLocal } from "./project-summary";

const recording = (id: string, createdAt: string, duration = 60, localPath = `${id}.mp4`): Recording => ({
  id, projectID: "P", localPath, name: "", createdAt, duration, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
  segmentIndex: 0, endedReason: "user", recordedAt: createdAt, timezoneIdentifier: "UTC", utcOffsetSeconds: 0, serverVersion: null, needsSync: false, mutationID: "M",
});
const composition = (id: string, createdAt: string, recordingID: string, start = 10): VideoComposition => ({
  id, projectID: "P", name: "Edit", kind: "custom", createdAt, aspectRatio: "original", uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false,
  clips: [{ id: "C", recordingID, startSeconds: start, endSeconds: start + 5, rate: 1, annotations: [] }], serverVersion: null, needsSync: false, mutationID: "M",
});
const event = (id: string, pendingDeletion = false): MatchEvent => ({ id, projectID: "P", kind: "Goal", note: "", occurredAt: "2026-01-01T00:00:00Z", recordingID: null, offsetSeconds: 0, preRollSeconds: 15, postRollSeconds: 5, colorHex: "", contextRecordingIDs: [], pendingDeletion, serverVersion: null, needsSync: false, mutationID: "M" });
const local = (r: Recording) => r.localPath !== "";

describe("projectSummary", () => {
  it("counts live records only", () => {
    const summary = projectSummary([recording("A", "2026-01-02"), { ...recording("B", "2026-01-01"), pendingDeletion: true }], [composition("E", "2026-01-03", "A")], [event("1"), event("2", true)], local);
    expect(summary.videoCount).toBe(1);
    expect(summary.highlightCount).toBe(1);
    expect(summary.eventCount).toBe(1);
  });
});

describe("projectPreview", () => {
  it("prefers the newest edit when it is newer than the newest video", () => {
    const a = recording("A", "2026-01-02", 60);
    const preview = projectPreview([a], [composition("E", "2026-01-03", "A", 10)], local);
    expect(preview.recording?.id).toBe("A");
    expect(preview.seconds).toBeCloseTo(10.25);
  });
  it("falls back to the latest available video at its midpoint capped at one second", () => {
    const a = recording("A", "2026-01-05", 60);
    const missing = recording("Z", "2026-01-09", 60, "");
    const preview = projectPreview([missing, a], [composition("E", "2026-01-01", "A")], local);
    expect(preview.recording?.id).toBe("A");
    expect(preview.seconds).toBe(1);
  });
  it("returns nothing without local video", () => {
    expect(projectPreview([recording("A", "2026-01-01", 60, "")], [], local)).toEqual({ recording: null, seconds: 0 });
  });
});

describe("projectSubtitle", () => {
  const now = new Date(2026, 8, 17, 12, 0);
  it("includes the opponent for matches", () => {
    expect(projectSubtitle({ opponent: "Rovers", scheduledAt: new Date(2026, 8, 17, 14, 30).toISOString() }, now)).toMatch(/^vs Rovers · Today, /);
  });
  it("shows only the date for training sessions", () => {
    expect(projectSubtitle({ opponent: "", scheduledAt: new Date(2026, 8, 16, 9, 0).toISOString() }, now)).toMatch(/^Yesterday, /);
  });
});

describe("filterProjects / sortProjects", () => {
  const projects = [
    { name: "Weekend Match", opponent: "Rovers", scheduledAt: "2026-01-01T00:00:00Z" },
    { name: "Training", opponent: "", scheduledAt: "2026-02-01T00:00:00Z" },
  ];
  it("matches name or opponent case-insensitively", () => {
    expect(filterProjects(projects, "rov").map((p) => p.name)).toEqual(["Weekend Match"]);
    expect(filterProjects(projects, "TRAIN").map((p) => p.name)).toEqual(["Training"]);
    expect(filterProjects(projects, "  ")).toHaveLength(2);
  });
  it("sorts newest scheduled first", () => {
    expect(sortProjects(projects).map((p) => p.name)).toEqual(["Training", "Weekend Match"]);
  });
});

describe("toDateTimeLocal", () => {
  it("formats for a datetime-local input", () => {
    expect(toDateTimeLocal(new Date(2026, 0, 5, 9, 7).toISOString())).toBe("2026-01-05T09:07");
    expect(toDateTimeLocal("garbage")).toBe("");
  });
});
