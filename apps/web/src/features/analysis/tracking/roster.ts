/* Shared roster pass: port of PlayerRosterTracking.swift (`RosterState` and the decode loop). One decode of the clip
   follows every remembered player at once with an exclusive assignment per frame. */
import type { Rect } from "@/domain/geometry";
import type { UUID } from "@/domain/ids";
import { newId } from "@/domain/ids";
import type { AnnotationCameraMotion, CameraTransform, PlayerIdentityMemory, PlayerMotion, PlayerMotionSample, TimeRange } from "@/domain/tracking";
import { DEFAULT_GAP_BRIDGING } from "@/domain/tracking";
import { assignRoster, assignmentFor, associationMargin, crowdOffset, expectationIsOffscreen, isMerged, PlayerRecoveryConfirmation, PlayerTrackingLimits, PlayerTrackingTrajectory, rosterMatches, searchRegion, type RosterAssignmentResult, type RosterExpectation } from "./association";
import { registerBackground } from "./camera-registration";
import type { VisionModels } from "./detector";
import type { FramePixels } from "./frame-pixels";
import { cameraDeterminant, cameraPoint, feet, nextDown, nextUp, offsetRect, overlap, rectFromFeet, rectMaxX, rectMaxY, rectMidX, relativeCamera } from "./geometry";
import { confirmedNumber, emptyMemory, galleryAdd, galleryIsReady, memoryConflicts, memoryIsConfirmed, memoryLearn, memorySimilarity, observe, observation, resumingMemory, voteNumber, type PlayerObservation } from "./identity";
import { boxAt, transformAt } from "./motion";
import { MINIMUM_NUMBER_HEIGHT } from "./selected-tracker";

export const MAXIMUM_IDENTITIES = 48;
export const PLAYERS_PER_KIT = 11;
export const DETECTION_INTERVAL = 1 / 15;

export interface RosterPrior { id: UUID; motion: PlayerMotion; memory?: PlayerIdentityMemory | null }
export interface RosterEntry { id: UUID; motion: PlayerMotion; memory: PlayerIdentityMemory; isNew: boolean }
export interface RosterResult { entries: RosterEntry[]; detectionFrames: number; elapsed: number }

class Identity {
  memory: PlayerIdentityMemory;
  isProvisional: boolean;
  isNew: boolean;
  hits = 0; clearHits = 0;
  firstSeen: number | null = null;
  trajectory = new PlayerTrackingTrajectory();
  previous: Rect | null = null;
  lastSeen: Rect | null = null;
  previousTime: number;
  missingSince: number | null = null;
  confirmation = new PlayerRecoveryConfirmation();
  samples: PlayerMotionSample[] = [];
  gaps: TimeRange[] = [];
  recoveries = 0;
  lastNumberRead = -Infinity; lastPrint = -Infinity;
  recentHeights: number[] = [];
  mergedSince: number | null = null;

  constructor(readonly id: UUID, memory: PlayerIdentityMemory, isProvisional: boolean, isNew: boolean, previousTime: number) {
    this.memory = memory; this.isProvisional = isProvisional; this.isNew = isNew; this.previousTime = previousTime;
  }
  get recovering() { return this.missingSince != null; }
  recoveryAge(time: number) { return this.missingSince != null ? time - this.missingSince : 0; }
  wantsNumberRead(time: number) { return !this.recovering && time - this.lastNumberRead >= 0.8; }
  expectation(time: number): RosterExpectation {
    return { id: this.id, box: this.trajectory.predicted(time) ?? this.previous, memory: this.memory, recovering: this.recovering, recoveryAge: this.recoveryAge(time), alternative: this.recovering ? this.lastSeen : null };
  }
}

export type FocusedSearch = (expected: Rect, known: Rect[]) => Promise<PlayerObservation[]>;

/** Per-pass roster state: every remembered player plus provisional bodies. */
export class RosterState {
  identities: Identity[] = [];
  playersPerKit = PLAYERS_PER_KIT;

  constructor(readonly start: number, priors: readonly RosterPrior[]) {
    for (const prior of priors) {
      const memory = resumingMemory(prior.memory, prior.motion.jerseyProfile);
      if (!memoryIsConfirmed(memory)) continue;
      const identity = new Identity(prior.id, memory, false, false, start);
      const box = boxAt(prior.motion, start);
      if (box) identity.previous = box; else identity.missingSince = start - PlayerTrackingLimits.maximumRecoverySeconds - 1;
      this.identities.push(identity);
    }
  }

  get needsCameraRegistration() { return this.identities.some((i) => !i.isProvisional && i.recovering); }
  get wantsNumberReads() { return this.identities.some((i) => !i.isProvisional && i.recovering && confirmedNumber(i.memory.number) != null); }
  get activeBoxes(): Rect[] { return this.identities.flatMap((i) => (i.recovering || !i.previous ? [] : [i.previous])); }

  /** Returns accepted (identity id, observation) pairs. */
  async step(time: number, camera: CameraTransform | null, absolute: CameraTransform | null, input: PlayerObservation[], focused: FocusedSearch = async () => []): Promise<[UUID, PlayerObservation][]> {
    let observations = input;
    const trace = PlayerTrackingLimits.trace;
    if (camera) for (const identity of this.identities) {
      identity.trajectory.applyCamera(camera);
      if (identity.previous) {
        const f = cameraPoint(camera, feet(identity.previous));
        if (f && Math.abs(f.x) < 4 && Math.abs(f.y) < 4) identity.previous = rectFromFeet(f, identity.previous.width, identity.previous.height);
      }
    }
    let expectations = this.identities.map((i) => i.expectation(time));
    const offset = crowdOffset(expectations, observations);
    if (offset) {
      trace?.(`${time.toFixed(3)} ROSTER crowd offset ${offset.x.toFixed(3)},${offset.y.toFixed(3)}`);
      expectations = expectations.map((e) => (e.recovering && !(e.recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds) && e.box ? { ...e, box: offsetRect(e.box, offset.x, offset.y) } : e));
    }
    let result = assignRoster(expectations, observations);
    const searches = this.identities.filter((i) => !i.isProvisional && !assignmentFor(result, i.id) && (i.recovering ? i.recoveryAge(time) < 1 : true))
      .sort((a, b) => b.previousTime - a.previousTime).slice(0, 3);
    let added = false;
    for (const identity of searches) {
      const expectation = expectations.find((e) => e.id === identity.id);
      const expected = expectation?.box;
      if (!expectation || !expected) continue;
      const regions = [expected];
      const alternative = expectation.alternative;
      if (alternative && Math.hypot(rectMidX(alternative) - rectMidX(expected), rectMaxY(alternative) - rectMaxY(expected)) > Math.max(0.02, expected.width)) regions.push(alternative);
      for (const region of regions) {
        const found = await focused(region, observations.map((o) => o.box));
        if (found.length) { observations = [...observations, ...found]; added = true; }
      }
    }
    if (added) result = assignRoster(expectations, observations);
    const accepted: [UUID, PlayerObservation][] = [];
    for (const identity of this.identities) {
      const assignment = assignmentFor(result, identity.id);
      if (!assignment) {
        if (identity.missingSince == null) identity.missingSince = nextUp(identity.previousTime);
        identity.confirmation.accept(null, time);
        continue;
      }
      const o = { ...observations[assignment.observation]! };
      const merged = (!identity.recovering || identity.mergedSince != null) && isMerged(o.box, identity.recentHeights);
      if (merged) {
        if (identity.mergedSince == null) identity.mergedSince = time;
        o.crowded = true;
      } else if (identity.mergedSince != null) {
        if (memoryIsConfirmed(identity.memory) && (memorySimilarity(identity.memory, o) ?? 0) < 0.75) {
          trace?.(`${time.toFixed(3)} ROSTER ${identity.id.slice(0, 8)} body out of merge fails identity: hiding`);
          identity.mergedSince = null; identity.missingSince = nextUp(identity.previousTime);
          continue;
        }
        identity.mergedSince = null;
      }
      const wasRecovering = identity.recovering;
      trace?.(`${time.toFixed(3)} ROSTER ${identity.id.slice(0, 8)} assign score=${assignment.score.toFixed(2)} at ${rectMidX(o.box).toFixed(3)},${rectMaxY(o.box).toFixed(3)} recovering=${wasRecovering ? 1 : 0}`);
      if (wasRecovering) {
        const dormant = identity.recoveryAge(time) > PlayerTrackingLimits.maximumRecoverySeconds;
        if (!identity.confirmation.accept(o.box, time, absolute, dormant ? 3 : 2, dormant ? 0.6 : 0.3)) continue;
        const missing = identity.missingSince;
        if (missing != null && missing >= this.start) identity.gaps.push([missing, nextDown(time)]);
        identity.missingSince = null;
        identity.trajectory = new PlayerTrackingTrajectory();
        if (identity.mergedSince == null || time - (missing ?? time) > 1.5) { identity.recentHeights = []; identity.mergedSince = null; }
        identity.recoveries += 1;
      } else if (o.crowded && !memoryIsConfirmed(identity.memory)) {
        identity.missingSince = nextUp(identity.previousTime);
        continue;
      }
      identity.samples.push({ time, box: o.box });
      if (!merged) { identity.recentHeights.push(o.box.height); if (identity.recentHeights.length > 20) identity.recentHeights.shift(); }
      identity.trajectory.append({ time, box: o.box });
      identity.previous = o.box; identity.lastSeen = o.box; identity.previousTime = time;
      identity.hits += 1;
      if (!o.crowded) identity.clearHits += 1;
      if (identity.firstSeen == null) identity.firstSeen = time;
      if (!wasRecovering) memoryLearn(identity.memory, o, !o.crowded);
      accepted.push([identity.id, o]);
    }
    observations.forEach((o, index) => {
      if (result.claimed.has(index)) return;
      if (this.identities.length >= MAXIMUM_IDENTITIES || !o.jersey || o.crowded) return;
      if (!(o.box.x > 0.005 && rectMaxX(o.box) < 0.995 && o.box.y > 0.005 && rectMaxY(o.box) < 0.995)) return;
      if (this.identities.some((i) => i.previous != null && overlap(i.previous, o.box) > 0.3)) return;
      const identity = new Identity(newId(), emptyMemory(), true, true, time);
      memoryLearn(identity.memory, o, true);
      identity.samples = [{ time, box: o.box }];
      identity.trajectory.append({ time, box: o.box });
      identity.previous = o.box; identity.lastSeen = o.box;
      identity.hits = 1; identity.clearHits = 1; identity.firstSeen = time;
      this.identities.push(identity);
    });
    const dropped = new Set<UUID>();
    for (let index = 0; index < this.identities.length; index++) {
      const identity = this.identities[index]!;
      if (!identity.isProvisional) continue;
      if (identity.recovering && time - (identity.missingSince ?? time) > 0.5) { dropped.add(identity.id); continue; }
      if (!memoryIsConfirmed(identity.memory) && time - (identity.firstSeen ?? time) > 4) { dropped.add(identity.id); continue; }
      const assignment = assignmentFor(result, identity.id);
      if (!memoryIsConfirmed(identity.memory) || identity.clearHits < 6 || time - (identity.firstSeen ?? time) < 0.5 || !assignment || result.contested.has(assignment.observation)) continue;
      const owner = this.returningOwner(identity, time);
      if (owner != null) { trace?.(`${time.toFixed(3)} ROSTER merge body into ${this.identities[owner]!.id.slice(0, 8)}`); this.merge(index, owner); dropped.add(identity.id); continue; }
      if (this.sameKitCount(identity) >= this.playersPerKit) {
        const forced = this.returningOwner(identity, time, true);
        if (forced != null) { trace?.(`${time.toFixed(3)} ROSTER forced merge body into ${this.identities[forced]!.id.slice(0, 8)}`); this.merge(index, forced); }
        dropped.add(identity.id);
        continue;
      }
      identity.isProvisional = false;
    }
    this.identities = this.identities.filter((i) => !dropped.has(i.id));
    return accepted;
  }

  /** Confirmed roster players wearing the same kit as `body`. */
  sameKitCount(body: Identity): number {
    const anchor = body.memory.jersey.examples[0];
    if (!anchor) return 0;
    const kit = body.memory.kitColor;
    const o = observation(body.previous ?? { x: 0, y: 0, width: 0, height: 0 }, { jersey: anchor, kitColor: kit && kit.length === 3 ? [kit[0]!, kit[1]!, kit[2]!] : undefined });
    return this.identities.filter((i) => !i.isProvisional && i.id !== body.id && memoryIsConfirmed(i.memory) && (memorySimilarity(i.memory, o) ?? 0) >= 0.8).length;
  }

  private returningOwner(body: Identity, time: number, forced = false): number | null {
    const box = body.previous, anchor = body.memory.jersey.examples[0];
    if (!box || !anchor) return null;
    const o = observation(box, { jersey: anchor, shorts: body.memory.shorts.examples[0], number: confirmedNumber(body.memory.number) ?? undefined, chroma: body.memory.chroma?.examples[0], print: body.memory.gallery?.prints[body.memory.gallery.prints.length - 1] });
    const ranked: { index: number; score: number }[] = [];
    this.identities.forEach((identity, index) => {
      if (identity.isProvisional || !identity.recovering || !memoryIsConfirmed(identity.memory)) return;
      const missing = identity.missingSince;
      if (missing == null || !((body.firstSeen ?? time) > missing)) return;
      const current = identity.expectation(time);
      if (current.box && body.previous) {
        const age = Math.max(0, time - missing);
        const distance = Math.hypot(rectMidX(body.previous) - rectMidX(current.box), rectMaxY(body.previous) - rectMaxY(current.box));
        if (!(distance <= 0.05 + 0.2 * Math.min(age, 6) || expectationIsOffscreen(current))) return;
      }
      const dormant: RosterExpectation = { id: identity.id, box: current.box, memory: identity.memory, recovering: true, recoveryAge: Math.max(current.recoveryAge, PlayerTrackingLimits.maximumRecoverySeconds + 1) };
      const match = rosterMatches(dormant, [o])[0];
      if (match) ranked.push({ index, score: match.score });
      else if (forced && !memoryConflicts(identity.memory, o)) {
        const similarity = memorySimilarity(identity.memory, o);
        if (similarity != null && similarity >= 0.7) {
          const distance = current.box ? Math.hypot(rectMidX(current.box) - rectMidX(box), rectMaxY(current.box) - rectMaxY(box)) : 1;
          ranked.push({ index, score: similarity * 0.3 + Math.max(0, 1 - distance) * 0.2 + Math.min(1, current.recoveryAge / 10) * 0.05 });
        }
      }
    });
    ranked.sort((a, b) => b.score - a.score);
    const best = ranked[0];
    if (best) {
      const owner = this.identities[best.index]!;
      const expectation: RosterExpectation = { id: owner.id, box: owner.expectation(time).box, memory: owner.memory, recovering: true, recoveryAge: Math.max(owner.recoveryAge(time), PlayerTrackingLimits.maximumRecoverySeconds + 1) };
      for (const rival of this.identities) {
        if (!rival.isProvisional || rival.id === body.id) continue;
        const rivalBox = rival.previous, rivalAnchor = rival.memory.jersey.examples[0], missing = owner.missingSince;
        if (!rivalBox || !rivalAnchor || missing == null || !((rival.firstSeen ?? time) > missing)) continue;
        const rivalObservation = observation(rivalBox, { jersey: rivalAnchor, shorts: rival.memory.shorts.examples[0], number: confirmedNumber(rival.memory.number) ?? undefined, chroma: rival.memory.chroma?.examples[0], print: rival.memory.gallery?.prints[rival.memory.gallery.prints.length - 1] });
        const match = rosterMatches(expectation, [rivalObservation])[0];
        if (match && match.score >= best.score - 0.05) return null;
      }
    }
    if (!forced && ranked.length === 0) {
      const candidates = this.identities.map((identity, index) => ({ identity, index })).filter(({ identity }) => {
        if (identity.isProvisional || !identity.recovering || !memoryIsConfirmed(identity.memory)) return false;
        const missing = identity.missingSince;
        if (missing == null || !((body.firstSeen ?? time) > missing) || memoryConflicts(identity.memory, o) || (memorySimilarity(identity.memory, o) ?? 0) < 0.75) return false;
        const current = identity.expectation(time), first = body.samples[0]?.box;
        if (!current.box || !first) return true;
        const age = Math.max(0, (body.firstSeen ?? time) - missing);
        const distance = Math.hypot(rectMidX(first) - rectMidX(current.box), rectMaxY(first) - rectMaxY(current.box));
        return distance <= 0.05 + 0.2 * Math.min(age, 6) || expectationIsOffscreen(current);
      });
      return candidates.length === 1 ? candidates[0]!.index : null;
    }
    if (forced) {
      if (best) return best.index;
      const missing = this.identities.map((identity, index) => ({ identity, index })).filter(({ identity }) =>
        !identity.isProvisional && identity.recovering && memoryIsConfirmed(identity.memory) && identity.missingSince != null && (body.firstSeen ?? time) > identity.missingSince &&
        !memoryConflicts(identity.memory, o) && (memorySimilarity(identity.memory, o) ?? 0) >= 0.7);
      const distance = (identity: Identity) => { const b = identity.expectation(time).box; return b ? Math.hypot(rectMidX(b) - rectMidX(box), rectMaxY(b) - rectMaxY(box)) : 2; };
      let nearest: { identity: Identity; index: number } | null = null;
      for (const candidate of missing) if (!nearest || distance(candidate.identity) < distance(nearest.identity)) nearest = candidate;
      return nearest?.index ?? null;
    }
    if (!best) return null;
    if (ranked.length > 1 && best.score - ranked[1]!.score < associationMargin(true, true)) return null;
    return best.index;
  }

  private merge(index: number, ownerIndex: number): void {
    const body = this.identities[index]!, owner = this.identities[ownerIndex]!;
    const first = body.samples[0]?.time;
    if (owner.missingSince != null && first != null && first > owner.missingSince && owner.missingSince >= this.start) owner.gaps.push([owner.missingSince, nextDown(first)]);
    owner.missingSince = null;
    owner.samples = [...owner.samples, ...body.samples].sort((a, b) => a.time - b.time);
    owner.trajectory = body.trajectory;
    owner.previous = body.previous; owner.lastSeen = body.lastSeen; owner.previousTime = body.previousTime;
    owner.hits += body.hits; owner.clearHits += body.clearHits; owner.recoveries += 1;
    owner.confirmation = new PlayerRecoveryConfirmation();
  }

  finish(): RosterEntry[] {
    return this.identities.flatMap((identity) => {
      if (identity.isProvisional || identity.samples.length < 2) return [];
      const lastTime = identity.samples[identity.samples.length - 1]?.time ?? this.start;
      const motion: PlayerMotion = { samples: identity.samples, trackID: identity.id, jerseyProfile: identity.memory.jersey, gapBridging: DEFAULT_GAP_BRIDGING };
      if (identity.missingSince != null && identity.missingSince > lastTime) motion.lostAt = identity.missingSince;
      if (identity.gaps.length) motion.gaps = identity.gaps;
      if (identity.recoveries > 0) motion.recoveryCount = identity.recoveries;
      return [{ id: identity.id, motion, memory: identity.memory, isNew: identity.isNew }];
    });
  }
}

export interface RosterTrackingOptions {
  start: number;
  end: number;
  priors: readonly RosterPrior[];
  camera?: AnnotationCameraMotion | null;
  models: VisionModels;
  progress?: (fraction: number) => void;
  signal?: AbortSignal;
}

/** One decode of the clip, every player at once. `frames` yields ≤1280 px RGBA frames in ascending time. */
export async function runRosterTracking(frames: AsyncIterable<FramePixels>, options: RosterTrackingOptions): Promise<RosterResult> {
  const began = performance.now();
  const { start, end, camera, models, signal } = options;
  const progress = options.progress ?? (() => {});
  const { detector, numbers, printer } = models;
  const roster = new RosterState(start, options.priors);
  let lastBuffer: FramePixels | null = null, lastTime = start, lastDetection = start - 1, lastReport = start, detectionFrames = 0;
  for await (const buffer of frames) {
    if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
    const seconds = buffer.time;
    if (seconds - lastReport >= 0.15) { lastReport = seconds; progress(Math.min(1, (seconds - start) / Math.max(0.01, end - start))); }
    if (seconds - lastDetection < DETECTION_INTERVAL - 0.002) continue;
    let step: CameraTransform | null = null, absolute: CameraTransform | null = null;
    const current = camera ? transformAt(camera, seconds) : null;
    if (camera && current) {
      absolute = current;
      const previous = lastBuffer && lastBuffer !== buffer ? transformAt(camera, lastTime) : null;
      if (previous && Math.abs(cameraDeterminant(previous)) > 0.00001) step = relativeCamera(previous, current);
    } else if (lastBuffer) {
      step = registerBackground(lastBuffer, buffer);
    }
    const boxes = await detector.playerBoxes(buffer);
    const observations = boxes.map((box) => ({ ...observe(buffer, box, boxes), time: seconds }));
    if (roster.identities.some((i) => !i.isProvisional && i.recovering && i.memory.gallery && galleryIsReady(i.memory.gallery))) {
      const active = roster.activeBoxes;
      let printed = 0;
      for (const o of observations) {
        if (printed >= 4) break;
        if (o.crowded || active.some((a) => overlap(a, o.box) > 0.3)) continue;
        printed += 1;
        o.print = (await printer.print(buffer, o.box)) ?? undefined;
      }
    }
    const focused: FocusedSearch = async (expected, known) => {
      const region = searchRegion(expected);
      if (!region) return [];
      const found = await detector.playerBoxes(buffer, region);
      const fresh = found.filter((candidate) => !known.some((k) => overlap(k, candidate) > 0.5));
      return fresh.map((box) => ({ ...observe(buffer, box, [...known, ...fresh]), time: seconds }));
    };
    let reads = 0;
    if (roster.wantsNumberReads) {
      const active = roster.activeBoxes;
      for (const o of observations) {
        if (reads >= 3) break;
        if (o.crowded || o.box.height < MINIMUM_NUMBER_HEIGHT || active.some((a) => overlap(a, o.box) > 0.3)) continue;
        reads += 1;
        o.number = (await numbers.read(buffer, o.box)) ?? undefined;
      }
    }
    const accepted = await roster.step(seconds, step, absolute, observations, focused);
    let printsLearned = 0;
    for (const [id, o] of accepted) {
      if (printsLearned >= 3) break;
      const identity = roster.identities.find((i) => i.id === id);
      if (!identity || o.crowded || identity.isProvisional || seconds - identity.lastPrint < 1) continue;
      printsLearned += 1;
      identity.lastPrint = seconds;
      const print = await printer.print(buffer, o.box);
      if (print) { const gallery = identity.memory.gallery ?? { prints: [], times: [] }; galleryAdd(gallery, print, seconds); identity.memory.gallery = gallery; }
    }
    for (const [id, o] of accepted) {
      if (reads >= 4) break;
      const identity = roster.identities.find((i) => i.id === id);
      if (!identity || !identity.wantsNumberRead(seconds) || o.crowded || o.box.height < MINIMUM_NUMBER_HEIGHT) continue;
      reads += 1;
      identity.lastNumberRead = seconds;
      const text = await numbers.read(buffer, o.box);
      if (text) voteNumber(identity.memory.number, text);
    }
    detectionFrames += 1;
    lastBuffer = buffer; lastTime = seconds; lastDetection = seconds;
  }
  progress(1);
  return { entries: roster.finish(), detectionFrames, elapsed: (performance.now() - began) / 1000 };
}

export type { RosterAssignmentResult };
