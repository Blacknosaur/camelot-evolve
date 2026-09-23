import { describe, expect, it } from "vitest";
import { reconcileLibrary, recoverRecordings } from "./library";
import type { VideoProbe } from "./probe";
import { writeJournal } from "./recovery-journal";
import { fakeMediaStore, fakeRecording, fakeRecordingStore, fileAt } from "./test-fakes";

const NOW = 1_800_000_000_000;
const OLD = NOW - 60 * 60 * 1000;
const goodProbe: VideoProbe = { duration: 12.5, width: 1920, height: 1080, rotation: 0, mimeType: "video/mp4", codec: "avc", frameRate: 30, hasAudio: true };

describe("reconcileLibrary", () => {
  it("blanks localPath for missing files, deletes old orphans, keeps fresh ones and partial exports go", async () => {
    const store = fakeMediaStore();
    fileAt("Recordings/A.mp4", 100, OLD, store);
    fileAt("Recordings/ORPHAN.mp4", 50, OLD, store);
    fileAt("Recordings/FRESH.mp4", 50, NOW - 1000, store);
    fileAt("Recordings/notes.txt", 5, OLD, store);
    fileAt("Exports/X.partial.mp4", 5, OLD, store);
    fileAt("Exports/Y.mp4", 7, OLD, store);
    const recordings = fakeRecordingStore([fakeRecording({ id: "A", localPath: "A.mp4" }), fakeRecording({ id: "B", localPath: "B.mp4" }), fakeRecording({ id: "C", localPath: "" })]);

    const result = await reconcileLibrary({ store, recordings, now: () => NOW });

    expect(result.missing).toEqual(["B"]);
    expect(recordings.rows.get("B")?.localPath).toBe("");
    expect(recordings.rows.get("A")?.localPath).toBe("A.mp4");
    expect(result.deletedOrphans).toEqual(["ORPHAN.mp4"]);
    expect(await store.exists("Recordings", "FRESH.mp4")).toBe(true);
    expect(await store.exists("Recordings", "notes.txt")).toBe(true);
    expect(result.deletedPartialExports).toEqual(["X.partial.mp4"]);
    expect(await store.exists("Exports", "Y.mp4")).toBe(true);
    expect(result.usage.Recordings).toBe(155);
    expect(result.usage.Exports).toBe(7);
  });
});

describe("recoverRecordings", () => {
  it("promotes journalled media into Recordings and clears the journal", async () => {
    const store = fakeMediaStore();
    await writeJournal({ recordingID: "R1", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "Europe/Madrid", mode: "normal", mediaKey: "R1.mp4" }, store);
    fileAt("Recovery/R1.mp4", 400, OLD, store);
    const recordings = fakeRecordingStore([fakeRecording({ id: "A", projectID: "P" })]);

    const recovered = await recoverRecordings({ store, recordings, probe: async () => goodProbe });

    expect(recovered).toHaveLength(1);
    expect(recovered[0]).toMatchObject({ id: "R1", projectID: "P", localPath: "R1.mp4", duration: 12.5, endedReason: "crash", segmentIndex: 1, timezoneIdentifier: "Europe/Madrid", recordedAt: "2026-03-01T10:00:00.000Z", width: 1920 });
    expect(await store.exists("Recordings", "R1.mp4")).toBe(true);
    expect(await store.list("Recovery")).toEqual([]);
    expect(recordings.rows.has("R1")).toBe(true);
  });

  it("discards unpromoted rolling clips, empty files and unreadable media", async () => {
    const store = fakeMediaStore();
    await writeJournal({ recordingID: "ROLL", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "UTC", mode: "rolling", mediaKey: "ROLL.mp4" }, store);
    fileAt("Recovery/ROLL.mp4", 400, OLD, store);
    await writeJournal({ recordingID: "EMPTY", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "UTC", mode: "normal", mediaKey: "EMPTY.mp4" }, store);
    fileAt("Recovery/EMPTY.mp4", 0, OLD, store);
    await writeJournal({ recordingID: "BAD", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "UTC", mode: "normal", mediaKey: "BAD.mp4" }, store);
    fileAt("Recovery/BAD.mp4", 40, OLD, store);
    const recordings = fakeRecordingStore();

    const recovered = await recoverRecordings({ store, recordings, probe: async () => { throw new Error("corrupt"); } });

    expect(recovered).toEqual([]);
    expect(store.files.size).toBe(0);
  });

  it("keeps promoted rolling clips and skips journals whose recording already exists", async () => {
    const store = fakeMediaStore();
    await writeJournal({ recordingID: "ROLL", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "UTC", mode: "rolling", mediaKey: "ROLL.mp4", promoted: true }, store);
    fileAt("Recovery/ROLL.mp4", 400, OLD, store);
    await writeJournal({ recordingID: "A", projectID: "P", startedAt: "2026-03-01T10:00:00.000Z", timezone: "UTC", mode: "normal", mediaKey: "A.mp4" }, store);
    fileAt("Recordings/A.mp4", 400, OLD, store);
    const recordings = fakeRecordingStore([fakeRecording({ id: "A" })]);

    const recovered = await recoverRecordings({ store, recordings, probe: async () => goodProbe });

    expect(recovered.map((r) => r.id)).toEqual(["ROLL"]);
    expect(await store.list("Recovery")).toEqual([]);
    expect(await store.exists("Recordings", "A.mp4")).toBe(true);
  });
});
