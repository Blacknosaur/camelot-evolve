import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CompositionClip } from "@/domain";
import { SequencePlayer } from "./sequence-player";

const clip = (over: Partial<CompositionClip>): CompositionClip => ({ id: crypto.randomUUID(), recordingID: "A", startSeconds: 0, endSeconds: 10, rate: 1, annotations: [], ...over });
const sources = [{ recordingID: "A", url: "blob:a", duration: 100 }, { recordingID: "B", url: "blob:b", duration: 50 }];

describe("SequencePlayer", () => {
  beforeEach(() => {
    vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
    vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
    vi.spyOn(HTMLMediaElement.prototype, "play").mockImplementation(() => Promise.resolve());
  });
  afterEach(() => vi.restoreAllMocks());

  it("creates one element per distinct recording and reports duration across rate and holds", () => {
    const clips = [clip({ recordingID: "A", endSeconds: 8, rate: 2 }), clip({ recordingID: "B", startSeconds: 5, endSeconds: 10 }), clip({ recordingID: "A", startSeconds: 3, endSeconds: 3.02, freezeDuration: 4 })];
    const player = new SequencePlayer(sources, clips);
    expect(player.elements.size).toBe(2);
    expect(player.duration).toBeCloseTo(4 + 5 + 4, 5);
    expect(player.state.isReady).toBe(false);
    player.dispose();
    expect(player.elements.size).toBe(0);
  });

  it("maps output time to the clip and source time when seeking", () => {
    const fast = clip({ recordingID: "A", startSeconds: 8, endSeconds: 20, rate: 2 });
    const held = clip({ recordingID: "B", startSeconds: 4, endSeconds: 4.02, freezeDuration: 5 });
    const player = new SequencePlayer(sources, [fast, held]);
    const seen: string[] = [];
    player.subscribe((s) => seen.push(`${s.activeClipID === fast.id ? "fast" : "held"}@${s.outputTime.toFixed(2)}`));
    player.seek(3);
    expect(player.state).toMatchObject({ activeClipID: fast.id, activeRecordingID: "A", outputTime: 3, sourceTime: 14, isPlaying: false });
    player.seek(8);
    expect(player.state).toMatchObject({ activeClipID: held.id, activeRecordingID: "B", sourceTime: 4 });
    player.seek(500);
    expect(player.state.outputTime).toBe(11);
    expect(player.outputTimeFor(fast.id, 14)).toBe(3);
    expect(seen.at(-1)).toBe("held@11.00");
    player.dispose();
  });

  it("steps by source frames scaled by the clip rate and by output time on holds", () => {
    const fast = clip({ recordingID: "A", startSeconds: 0, endSeconds: 20, rate: 2 });
    const held = clip({ recordingID: "B", startSeconds: 4, endSeconds: 4.02, freezeDuration: 5 });
    const player = new SequencePlayer(sources, [fast, held]);
    player.seek(1);
    player.step(1, 30);
    expect(player.currentTime).toBeCloseTo(1 + 1 / 60, 6);
    player.seek(12);
    player.step(-1, 30);
    expect(player.currentTime).toBeCloseTo(12 - 1 / 30, 6);
    player.dispose();
  });

  it("delivers frame callbacks on every seek and can be unsubscribed", () => {
    const player = new SequencePlayer(sources, [clip({})]);
    const samples: number[] = [];
    const stop = player.onTime((s) => samples.push(s.outputTime));
    player.seek(2); player.seek(4);
    stop();
    player.seek(6);
    expect(samples).toEqual([2, 4]);
    player.dispose();
  });

  it("keeps the same element when a source URL is unchanged and swaps it otherwise", () => {
    const player = new SequencePlayer(sources, [clip({})]);
    const before = player.elements.get("A");
    player.setSources([{ recordingID: "A", url: "blob:a", duration: 100 }]);
    expect(player.elements.get("A")).toBe(before);
    expect(player.elements.has("B")).toBe(false);
    player.setSources([{ recordingID: "A", url: "blob:a2", duration: 100 }]);
    expect(player.elements.get("A")).not.toBe(before);
    player.dispose();
  });
});
