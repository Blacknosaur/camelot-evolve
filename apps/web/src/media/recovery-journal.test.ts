import { describe, expect, it } from "vitest";
import { clearJournal, parseJournal, readJournals, writeJournal, type CaptureJournal } from "./recovery-journal";
import { fakeMediaStore } from "./test-fakes";

const journal: CaptureJournal = { recordingID: "R1", projectID: "P1", startedAt: "2026-03-01T10:00:00.000Z", timezone: "Europe/Madrid", mode: "normal", mediaKey: "R1.mp4" };

describe("recovery journal", () => {
  it("parses valid JSON and rejects incomplete records", () => {
    expect(parseJournal(JSON.stringify(journal))).toEqual({ ...journal, promoted: false });
    expect(parseJournal(JSON.stringify({ ...journal, promoted: true, mode: "rolling" }))?.promoted).toBe(true);
    expect(parseJournal("{ not json")).toBeNull();
    expect(parseJournal(JSON.stringify({ recordingID: "R1" }))).toBeNull();
    expect(parseJournal(JSON.stringify({ ...journal, timezone: undefined, mode: undefined }))).toMatchObject({ timezone: "UTC", mode: "normal" });
  });

  it("round-trips through the media store and clears", async () => {
    const store = fakeMediaStore();
    await writeJournal(journal, store);
    await writeJournal({ ...journal, recordingID: "R2", mediaKey: "R2.mp4" }, store);
    await store.write("Recovery", "R2.mp4", new Blob([new Uint8Array(4)]));
    const journals = await readJournals(store);
    expect(journals.map((j) => j.recordingID).sort()).toEqual(["R1", "R2"]);
    await clearJournal("R1", store);
    expect((await readJournals(store)).map((j) => j.recordingID)).toEqual(["R2"]);
    expect(await store.exists("Recovery", "R2.mp4")).toBe(true);
  });
});
