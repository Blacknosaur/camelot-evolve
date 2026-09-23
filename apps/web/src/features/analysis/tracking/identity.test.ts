/* Port of PlayerTrackingIdentityTests.swift. */
import { describe, expect, it } from "vitest";
import type { Rect } from "@/domain/geometry";
import type { PlayerMotion } from "@/domain/tracking";
import { chooseCandidate, PlayerRecoveryConfirmation, PlayerTrackingLimits, PlayerTrackingTrajectory } from "./association";
import { emptyProfile, profileLearn, resumingProfile, signatureFromColors, signatureSimilarity, type RGB } from "./identity";
import { bound, continuing } from "./motion";
import { offsetRect, rectMaxY, rectMidX } from "./geometry";
import type { CompositionClip } from "@/domain/records";
import { storePlayerTrack } from "./library";

const box = (x: number): Rect => ({ x, y: 0.5, width: 0.1, height: 0.2 });
const signature = (color: RGB) => signatureFromColors(Array.from({ length: 120 }, () => color));
const profileFor = (color: RGB) => { const p = emptyProfile(); profileLearn(p, signature(color), true); return p; };

describe("PlayerTrackingIdentity", () => {
  it("dormant recovery requires three fresh matches and rejects same-kit ambiguity", () => {
    const confirmation = new PlayerRecoveryConfirmation();
    const target = box(0.4), blue = signature([0.08, 0.18, 0.78]);
    expect(confirmation.accept(target, 4, null, 3, 0.6)).toBe(false);
    expect(confirmation.accept(target, 4.4, null, 3, 0.6)).toBe(false);
    expect(confirmation.accept(target, 4.8, null, 3, 0.6)).toBe(true);
    expect(confirmation.accept(target, 5.2, null, 3, 0.6)).toBe(false);
    expect(confirmation.accept(null, 5.6)).toBe(false);
    expect(confirmation.accept(target, 6, null, 3, 0.6)).toBe(false);
    const profile = emptyProfile(); profileLearn(profile, blue, true); profileLearn(profile, blue, true);
    const candidates = [{ box: offsetRect(target, -0.02, 0), jersey: blue }, { box: offsetRect(target, 0.02, 0), jersey: blue }];
    expect(chooseCandidate(candidates, target, null, profile, true, 4)).toBeNull();
  });

  it("camera-aligned player velocity overrides an accelerating screen trajectory", () => {
    const trajectory = new PlayerTrackingTrajectory();
    for (let index = 0; index <= 6; index++) { const time = index * 0.1; trajectory.append({ time, box: box(0.1 + time * time * 0.3) }); }
    const still = trajectory.samples[trajectory.samples.length - 1]!.box;
    expect(trajectory.predicted(1.5, { x: 0, y: 0 }, { x: 0, y: 0 })).toEqual(still);
    const velocity = { x: 0.02, y: 0.01 };
    expect(trajectory.predicted(9, { x: 0, y: 0 }, velocity)).toEqual(trajectory.predicted(3.1, { x: 0, y: 0 }, velocity));
  });

  it("jersey signatures distinguish primary colours, stripes and shadow", () => {
    const green = signature([0.08, 0.72, 0.18]), blue = signature([0.08, 0.18, 0.78]), white = signature([0.92, 0.92, 0.92]);
    const striped = signatureFromColors([...Array.from({ length: 60 }, (): RGB => [0.85, 0.08, 0.08]), ...Array.from({ length: 60 }, (): RGB => [0.92, 0.92, 0.92])]);
    const shadow = signature([0.01, 0.08, 0.015]);
    expect(signatureSimilarity(green, green)).toBeGreaterThan(0.99);
    expect(signatureSimilarity(green, blue)).toBeLessThan(0.5);
    expect(signatureSimilarity(green, white)).toBeLessThan(0.5);
    expect(signatureSimilarity(green, striped)).toBeLessThan(0.8);
    expect(signatureSimilarity(green, shadow)).toBeLessThan(0.9);
    expect(signatureSimilarity(white, striped)).toBeGreaterThan(0.4);
  });

  it("profile learns only clear anchored examples and is bounded", () => {
    const anchor = signature([0.06, 0.65, 0.16]), nearby = signature([0.08, 0.6, 0.2]), mismatch = signature([0.08, 0.16, 0.78]);
    const profile = emptyProfile();
    profileLearn(profile, anchor, false);
    expect(profile.examples).toHaveLength(0);
    profileLearn(profile, anchor, true);
    expect(profile.examples).toEqual([anchor]);
    profileLearn(profile, mismatch, true);
    expect(profile.examples).toEqual([anchor]);
    profileLearn(profile, nearby, true);
    expect(profile.examples).toHaveLength(2);
    for (let i = 0; i < 20; i++) profileLearn(profile, nearby, true);
    expect(profile.examples.length).toBeLessThanOrEqual(8);
    expect(profile.examples[0]).toEqual(anchor);
  });

  it("association rejects jersey mismatch and same-kit ambiguity", () => {
    const expected: Rect = { x: 0.45, y: 0.5, width: 0.1, height: 0.2 };
    const green = signature([0.08, 0.72, 0.18]), blue = signature([0.08, 0.18, 0.78]);
    const profile = emptyProfile(); profileLearn(profile, green, true);
    expect(chooseCandidate([{ box: expected, jersey: blue }], expected, null, profile, false)).toBeNull();
    const left = offsetRect(expected, -0.025, 0), right = offsetRect(expected, 0.025, 0);
    expect(chooseCandidate([{ box: left, jersey: green }, { box: right, jersey: green }], expected, null, profile, false)).toBeNull();
    const directionExpected = offsetRect(expected, 0.08, 0);
    const directional = chooseCandidate([{ box: left, jersey: green }, { box: directionExpected, jersey: green }], directionExpected, null, profile, false);
    expect(directional?.candidate.box).toEqual(directionExpected);
  });

  it("trajectory prediction favours the established direction and resets after a gap", () => {
    const trajectory = new PlayerTrackingTrajectory();
    trajectory.append({ time: 0, box: box(0.1) }); trajectory.append({ time: 0.1, box: box(0.2) }); trajectory.append({ time: 0.2, box: box(0.3) });
    const predicted = trajectory.predicted(0.3)!;
    expect(rectMidX(predicted)).toBeGreaterThan(0.3);
    const compensated = trajectory.predicted(0.3, { x: 0.8, y: 0 })!;
    expect(rectMidX(compensated)).toBeLessThan(rectMidX(predicted));
    trajectory.append({ time: 0.6, box: box(0.8) });
    expect(trajectory.samples).toHaveLength(1);
    expect(rectMidX(trajectory.predicted(0.7)!)).toBeCloseTo(0.85, 4);
  });

  it("trajectory prediction is bounded at the maximum recovery horizon", () => {
    const trajectory = new PlayerTrackingTrajectory();
    trajectory.append({ time: 0, box: box(0.1) }); trajectory.append({ time: 0.1, box: box(0.2) }); trajectory.append({ time: 0.2, box: box(0.3) });
    const capped = trajectory.predicted(3)!, atLimit = trajectory.predicted(0.2 + PlayerTrackingLimits.maximumRecoverySeconds)!;
    expect(rectMidX(capped)).toBeCloseTo(rectMidX(atLimit), 4);
    expect(rectMaxY(capped)).toBeCloseTo(rectMaxY(atLimit), 4);
  });

  it("trajectory retains recent confirmed motion during a recovery gap", () => {
    const trajectory = new PlayerTrackingTrajectory();
    trajectory.append({ time: 1, box: box(0.1) }); trajectory.append({ time: 1.1, box: box(0.2) }); trajectory.append({ time: 1.2, box: box(0.3) });
    const predicted = trajectory.predicted(2)!;
    expect(rectMidX(predicted)).toBeGreaterThan(rectMidX(box(0.3)));
    expect(rectMidX(predicted)).toBeCloseTo(rectMidX(trajectory.predicted(1.2 + 0.8)!), 4);
  });

  it("recovery does not trust an unconfirmed seed jersey", () => {
    const target = box(0.4), blue = signature([0.08, 0.18, 0.78]);
    const profile = emptyProfile(); profileLearn(profile, blue, true);
    const candidates = [{ box: target, jersey: blue }];
    expect(chooseCandidate(candidates, target, null, profile, true)).not.toBeNull();
    expect(chooseCandidate([{ box: target, jersey: blue, crowded: true }], target, null, profile, true)).toBeNull();
    const weaker = signature([0.3, 0.3, 0.6]);
    expect(chooseCandidate([{ box: target, jersey: weaker }], target, null, profile, true)).toBeNull();
    expect(resumingProfile(profile).examples).toHaveLength(0);
    profileLearn(profile, blue, true);
    expect(resumingProfile(profile)).toEqual(profile);
    expect(chooseCandidate(candidates, target, null, profile, true)).not.toBeNull();
  });

  it("recovery uses a clear jersey to separate overlapping opponents but not teammates", () => {
    const target = box(0.4), blue = signature([0.08, 0.18, 0.78]), white = signature([0.92, 0.92, 0.92]);
    const profile = emptyProfile(); profileLearn(profile, blue, true); profileLearn(profile, blue, true);
    const selected = { box: target, jersey: blue, crowded: true };
    const opponent = { box: offsetRect(target, 0.025, 0), jersey: white, crowded: true };
    expect(chooseCandidate([selected, opponent], target, null, profile, true)?.candidate.box).toEqual(target);
    const teammate = { box: opponent.box, jersey: blue, crowded: true };
    expect(chooseCandidate([selected, teammate], target, null, profile, true)).toBeNull();
  });

  it("recovery confirmation compensates for a fast camera pan", () => {
    const confirmation = new PlayerRecoveryConfirmation();
    const target = box(0.4);
    expect(confirmation.accept(target, 1, { values: [1, 0, 0, 0, 1, 0, 0, 0, 1] })).toBe(false);
    expect(confirmation.accept(offsetRect(target, -0.2, 0), 1.15, { values: [1, 0, -0.2, 0, 1, 0, 0, 0, 1] })).toBe(true);
  });

  it("recovery requires two timely consistent observations", () => {
    const confirmation = new PlayerRecoveryConfirmation();
    const candidate = box(0.4);
    expect(confirmation.accept(candidate, 1)).toBe(false);
    expect(confirmation.accept(candidate, 1.01)).toBe(false);
    expect(confirmation.accept(candidate, 1.06)).toBe(true);
    expect(confirmation.accept(candidate, 1.19)).toBe(false);
    const late = new PlayerRecoveryConfirmation();
    expect(late.accept(candidate, 2)).toBe(false);
    expect(late.accept(candidate, 2.31)).toBe(false);
  });

  it("legacy and new profiles round-trip and track operations preserve identity", () => {
    const id = "A", otherID = "B";
    const profile = profileFor([0.08, 0.18, 0.78]);
    const first: PlayerMotion = { samples: [{ time: 0, box: box(0.1) }], trackID: id, jerseyProfile: profile };
    const other: PlayerMotion = { samples: [{ time: 0, box: box(0.7) }], trackID: otherID, jerseyProfile: profileFor([0.08, 0.72, 0.18]) };
    const legacy = JSON.parse(JSON.stringify(first)) as PlayerMotion;
    delete legacy.jerseyProfile;
    expect(legacy.jerseyProfile).toBeUndefined();
    expect(JSON.parse(JSON.stringify(first))).toEqual(first);
    const updatedProfile = { examples: profile.examples.slice() };
    profileLearn(updatedProfile, signature([0.09, 0.62, 0.2]), true);
    const continuation: PlayerMotion = { samples: [{ time: 1, box: box(0.2) }], trackID: id, jerseyProfile: updatedProfile };
    expect(continuing(first, continuation, 1).jerseyProfile).toEqual(updatedProfile);
    expect(continuing(first, { samples: [{ time: 1, box: box(0.2) }], trackID: id }, 1).jerseyProfile).toEqual(profile);
    expect(bound(first, 0)?.jerseyProfile).toEqual(profile);

    const mark = (tool: "text" | "spotlight" | "zone", playerMotion?: PlayerMotion, linkedPlayers?: PlayerMotion[]) => ({
      id: crypto.randomUUID(), tool, points: [{ x: 0.1, y: 0.2 }], color: { red: 1, green: 1, blue: 0 }, width: 0.01, text: "", start: 0, end: 2, fade: false, keyframes: [], playerMotion, linkedPlayers,
    });
    let clip: CompositionClip = { id: "C", recordingID: "R", startSeconds: 0, endSeconds: 2, rate: 1, annotations: [mark("text", first), mark("spotlight", first), mark("zone", undefined, [first, other]), mark("text", other)] };
    clip = storePlayerTrack(clip, first); clip = storePlayerTrack(clip, other);
    clip = storePlayerTrack(clip, continuing(first, continuation, 1));
    expect(clip.trackingLibrary?.players).toHaveLength(2);
    expect(clip.trackingLibrary?.players.find((p) => p.id === id)?.motion.jerseyProfile).toEqual(updatedProfile);
    expect(clip.trackingLibrary?.players.find((p) => p.id === otherID)?.motion.jerseyProfile).toEqual(other.jerseyProfile);
    expect(clip.annotations[0]!.playerMotion?.jerseyProfile).toEqual(updatedProfile);
    expect(clip.annotations[1]!.playerMotion?.jerseyProfile).toEqual(updatedProfile);
    expect(clip.annotations[2]!.linkedPlayers?.[0]?.jerseyProfile).toEqual(updatedProfile);
    expect(clip.annotations[2]!.linkedPlayers?.[1]?.jerseyProfile).toEqual(other.jerseyProfile);
    expect(clip.annotations[3]!.playerMotion?.jerseyProfile).toEqual(other.jerseyProfile);
  });
});
