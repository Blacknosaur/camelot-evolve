/* Single selected-player tracking: port of `SelectedPlayerTracking.run` / `trackBackward` (SelectedPlayerTracking.swift).
   Frames arrive as RGBA `FramePixels` (≤1280 px, display orientation); detection, prints and numbers come through
   the `VisionModels` interfaces so the loop is model-agnostic. Runs inside the vision worker. */
import type { Point, Rect } from "@/domain/geometry";
import type { CameraTransform, PlayerIdentityMemory, PlayerJerseyProfile, PlayerMotion, TimeRange } from "@/domain/tracking";
import { DEFAULT_GAP_BRIDGING } from "@/domain/tracking";
import type { VisionModels } from "./detector";
import { grayFor, registerBackground } from "./camera-registration";
import { feet, cameraPoint, offsetRect, overlap, nextUp, nextDown, rectMidX, rectMidY, rectMaxY } from "./geometry";
import { memoryLearn, memorySimilarity, memoryIsConfirmed, observe, profileIsConfirmed, profileLearn, profileSimilarity, resumingMemory, resumingProfile, sampleSignature, type PlayerObservation } from "./identity";
import { boxAt, repairEnd } from "./motion";
import { OpticalTracker } from "./optical-tracker";
import { chooseCandidate, isMerged, PlayerPresence, PlayerRecoveryConfirmation, PlayerTrackRejoinConfirmation, PlayerTrackingLimits, PlayerTrackingTrajectory, searchRegion, type AssociationCandidate } from "./association";
import type { FramePixels } from "./frame-pixels";

export const MINIMUM_NUMBER_HEIGHT = 0.08;

export interface SelectedTrackingOptions {
  seed: Rect;
  start: number;
  end: number;
  allowRecovery?: boolean;
  prior?: PlayerMotion | null;
  models: VisionModels;
  progress?: (fraction: number) => void;
  signal?: AbortSignal;
}

/** Follows the selected region frame by frame. `frames` yields decoded frames in ascending time. */
export async function runSelectedTracking(frames: AsyncIterable<FramePixels>, options: SelectedTrackingOptions): Promise<PlayerMotion> {
  const { seed, start, models, signal } = options;
  const allowRecovery = options.allowRecovery ?? true;
  const prior = options.prior ?? null;
  const end = prior ? repairEnd(prior, start, options.end) : options.end;
  const progress = options.progress ?? (() => {});
  const trace = PlayerTrackingLimits.trace;
  const tracker = new OpticalTracker(seed);
  const { detector, numbers, printer } = models;
  let lastNumberRead = -Infinity, lastPrint = -Infinity, leftFrame = false;
  let recentHeights: number[] = [];
  let mergedSince: number | null = null;

  const result: PlayerMotion = { samples: [{ time: start, box: seed }], correctionTimes: [start], gapBridging: DEFAULT_GAP_BRIDGING };
  const rejoin = new PlayerTrackRejoinConfirmation(start);
  const profile: PlayerJerseyProfile = resumingProfile(prior?.jerseyProfile);
  const memory: PlayerIdentityMemory = resumingMemory(prior?.identity, prior?.jerseyProfile);
  let trajectory = new PlayerTrackingTrajectory();
  if (prior) {
    const last = [...prior.samples].reverse().find((s) => s.time < start);
    if (last && start - last.time <= 0.25 && overlap(last.box, seed) > 0.3) {
      const gapEnd = Math.max(-Infinity, ...(prior.gaps ?? []).filter((g) => g[0] < start).map((g) => g[1]));
      const loss = prior.lostAt ?? Infinity;
      const boundary = Math.max(gapEnd, loss < start ? loss : -Infinity);
      for (const sample of prior.samples) if (sample.time < start && sample.time > boundary && sample.time >= start - 0.7 && boxAt(prior, sample.time)) trajectory.append(sample);
    }
  }
  trajectory.append({ time: start, box: seed });
  const recovery = new PlayerRecoveryConfirmation();
  let previous = seed, lastReport = start, lastDetection = start - 1, previousTime = start;
  let missingSince: number | null = null;
  let lastGoodBuffer: FramePixels | null = null;
  type CameraReference = { buffer: FramePixels; time: number; box: Rect };
  // A holder object keeps TypeScript from narrowing these to `null` across the loop's back edge.
  const refs: { camera: CameraReference | null; next: CameraReference | null } = { camera: null, next: null };
  let recoveryPlayerVelocity: Point | null = null;
  let firstFrame = true;
  const gaps: TimeRange[] = [];

  for await (const buffer of frames) {
    if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
    const seconds = buffer.time;
    if (seconds - lastReport >= 0.15) { lastReport = seconds; progress(Math.min(1, (seconds - start) / Math.max(0.01, end - start))); }
    if (firstFrame) {
      firstFrame = false;
      if (profile.examples.length === 0) { const jersey = sampleSignature(buffer, seed); if (jersey) profileLearn(profile, jersey, true); }
      if (memory.jersey.examples.length === 0) memoryLearn(memory, observe(buffer, seed, []), true);
    }
    const gray = grayFor(buffer);
    const opticalObservation = missingSince == null ? tracker.track(gray) : null;
    let predicted = trajectory.predicted(seconds) ?? previous;
    let box = opticalObservation?.box ?? predicted;
    const displacement = Math.hypot(rectMidX(box) - rectMidX(previous), rectMidY(box) - rectMidY(previous));
    let reliable = (opticalObservation?.confidence ?? 0) >= 0.35 && box.width > 0.003 && box.height > 0.008 &&
      displacement < Math.max(0.035, previous.height * 0.7) && box.width / previous.width < 1.5 && box.height / previous.height < 1.5 && missingSince == null;
    if (missingSince == null && profile.examples.length > 0) {
      const shirt = sampleSignature(buffer, box);
      if (shirt && profileSimilarity(profile, shirt) < 0.45) { trace?.(`${seconds.toFixed(3)} optical jersey mismatch ${profileSimilarity(profile, shirt).toFixed(2)}`); reliable = false; }
    }
    if (!reliable && !opticalObservation && missingSince == null) trace?.(`${seconds.toFixed(3)} no optical observation`);
    else if (!reliable && missingSince == null && opticalObservation) trace?.(`${seconds.toFixed(3)} optical unreliable conf=${opticalObservation.confidence.toFixed(2)} disp=${displacement.toFixed(3)}`);
    if (reliable && missingSince == null && mergedSince == null && isMerged(box, recentHeights)) { mergedSince = seconds; trace?.(`${seconds.toFixed(3)} optical box merged h=${box.height.toFixed(3)}`); }
    const neededRecovery = !reliable;
    const recoveryAge = missingSince != null ? seconds - missingSince : 0;
    const dormant = recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds;
    let recoveryCamera: CameraTransform | null = null;
    if (neededRecovery && !allowRecovery) { result.lostAt = seconds; break; }
    const detectionDue = seconds - lastDetection >= (dormant ? 0.4 : neededRecovery || !profileIsConfirmed(profile) ? 0.12 : 0.3);
    if (neededRecovery && detectionDue && lastGoodBuffer) {
      const camera = registerBackground(lastGoodBuffer, buffer);
      const center = camera ? cameraPoint(camera, feet(previous)) : null;
      if (camera && center) {
        recoveryCamera = camera;
        const reference = refs.camera;
        if (!recoveryPlayerVelocity && reference && previousTime - reference.time >= 0.2) {
          const pastCamera = registerBackground(reference.buffer, lastGoodBuffer);
          const past = pastCamera ? cameraPoint(pastCamera, feet(reference.box)) : null;
          if (past) { const dt = previousTime - reference.time; recoveryPlayerVelocity = { x: (rectMidX(previous) - past.x) / dt, y: (rectMaxY(previous) - past.y) / dt }; }
        }
        const moving = recoveryPlayerVelocity ? trajectory.predicted(seconds, { x: 0, y: 0 }, recoveryPlayerVelocity) : null;
        const movedFeet = moving ? cameraPoint(camera, feet(moving)) : null;
        if (movedFeet) predicted = offsetRect(previous, movedFeet.x - rectMidX(previous), movedFeet.y - rectMaxY(previous));
        else if (Math.hypot(center.x - rectMidX(previous), center.y - rectMaxY(previous)) > Math.max(0.002, previous.width * 0.25)) predicted = offsetRect(previous, center.x - rectMidX(previous), center.y - rectMaxY(previous));
      }
    }
    if (detectionDue) {
      lastDetection = seconds;
      let detected = await detector.playerBoxes(buffer);
      let observations: PlayerObservation[] = [];
      const identities = async (boxes: Rect[]): Promise<AssociationCandidate[]> => {
        observations = boxes.map((b) => observe(buffer, b, boxes));
        const galleryReady = memory.gallery != null && memory.gallery.prints.length >= 3;
        if (galleryReady && dormant && !leftFrame) {
          for (const o of observations) if (!o.crowded && !o.print) o.print = (await printer.print(buffer, o.box)) ?? undefined;
        } else if (galleryReady) {
          const near = observations.map((o, i) => i).sort((a, b) => distanceToPredicted(observations[a]!.box) - distanceToPredicted(observations[b]!.box)).slice(0, 4);
          for (const index of near) observations[index]!.print = (await printer.print(buffer, observations[index]!.box)) ?? undefined;
        }
        for (const o of observations) o.time = seconds;
        return observations.map((o, tag) => ({ box: o.box, jersey: o.jersey, crowded: o.crowded, tag }));
      };
      const distanceToPredicted = (b: Rect) => Math.hypot(rectMidX(b) - rectMidX(predicted), rectMaxY(b) - rectMaxY(predicted));
      const appearance = (candidate: AssociationCandidate) => memorySimilarity(memory, observations[candidate.tag ?? 0]!);
      let candidates = await identities(detected);
      let match = chooseCandidate(candidates, predicted, reliable ? box : null, profile, neededRecovery, recoveryAge, appearance);
      if (!match) {
        const region = searchRegion(predicted);
        if (region) {
          const focused = await detector.playerBoxes(buffer, region);
          for (const candidate of focused) if (!detected.some((d) => overlap(d, candidate) > 0.5)) detected = [...detected, candidate];
          candidates = await identities(detected);
          match = chooseCandidate(candidates, predicted, reliable ? box : null, profile, neededRecovery, recoveryAge, appearance);
        }
      }
      if (match) {
        const tag = match.candidate.tag ?? 0;
        trace?.(`${seconds.toFixed(3)} match score=${match.score.toFixed(2)} crowded=${match.candidate.crowded ? 1 : 0} confirmed=${profileIsConfirmed(profile) ? 1 : 0} recovering=${neededRecovery ? 1 : 0}`);
        const merged = (!neededRecovery || mergedSince != null) && isMerged(match.candidate.box, recentHeights);
        if (merged && mergedSince == null) { mergedSince = seconds; trace?.(`${seconds.toFixed(3)} merged box: following without learning`); }
        if (!merged && mergedSince != null && memoryIsConfirmed(memory) && (memorySimilarity(memory, observations[tag]!) ?? 0) < 0.75) {
          trace?.(`${seconds.toFixed(3)} body out of the merge fails identity: hiding`);
          mergedSince = null; reliable = false;
        } else if (match.candidate.crowded && !profileIsConfirmed(profile)) {
          reliable = false;
        } else if (!neededRecovery || recovery.accept(match.candidate.box, seconds, recoveryCamera, dormant ? 3 : 2, dormant ? 0.6 : 0.3)) {
          box = match.candidate.box; tracker.reseed(box);
          tracker.track(gray); // The detector box belongs to this frame: prime the template before a fast pan.
          reliable = true;
          if (!merged && mergedSince != null) mergedSince = null;
          if (!neededRecovery && mergedSince == null && seconds - start >= 0.15 && match.candidate.jersey) {
            profileLearn(profile, match.candidate.jersey, !match.candidate.crowded);
            const o = observations[tag]!;
            if (!o.crowded && box.height >= MINIMUM_NUMBER_HEIGHT && seconds - lastNumberRead >= 0.8) { lastNumberRead = seconds; o.number = (await numbers.read(buffer, box)) ?? undefined; }
            if (!o.crowded && seconds - lastPrint >= 0.5 && !o.print) { lastPrint = seconds; o.print = (await printer.print(buffer, box)) ?? undefined; }
            memoryLearn(memory, o, !match.candidate.crowded);
          }
        }
      } else {
        const index = neededRecovery && dormant && !leftFrame && profileIsConfirmed(profile)
          ? PlayerPresence.findAnywhere(observations, memory, 0.85, 0.1, (candidate) => Math.hypot(rectMidX(candidate) - rectMidX(predicted), rectMaxY(candidate) - rectMaxY(predicted)) <= 0.12 + 0.3 * Math.min(recoveryAge, 6))
          : null;
        if (index != null) {
          const found = observations[index]!;
          trace?.(`${seconds.toFixed(3)} present-anywhere candidate at ${rectMidX(found.box).toFixed(3)},${rectMaxY(found.box).toFixed(3)}`);
          if (recovery.accept(found.box, seconds, recoveryCamera, 3, 0.6)) { box = found.box; tracker.reseed(box); tracker.track(gray); reliable = true; }
        } else {
          trace?.(`${seconds.toFixed(3)} no match among ${candidates.length} candidates (recovering=${neededRecovery ? 1 : 0})`);
          recovery.accept(null, seconds);
          if (candidates.some((c) => overlap(c.box, box) > 0.25)) reliable = false;
        }
      }
    }
    if (!reliable) {
      rejoin.reset();
      if (missingSince == null) { missingSince = nextUp(previousTime); leftFrame = PlayerPresence.leftFrame(previous); }
      if (!allowRecovery) { result.lostAt = missingSince; break; }
      continue;
    }
    if (missingSince != null) {
      gaps.push([missingSince, nextDown(seconds)]);
      const missing = missingSince;
      missingSince = null;
      trajectory = new PlayerTrackingTrajectory();
      if (mergedSince == null || seconds - missing > 1.5) { recentHeights = []; mergedSince = null; }
      refs.camera = null; refs.next = null;
    }
    if (neededRecovery) result.recoveryCount = (result.recoveryCount ?? 0) + 1;
    if (seconds > start + 0.001) result.samples.push({ time: seconds, box });
    if (mergedSince == null && (seconds - start >= 0.15 || seconds === start)) { recentHeights.push(box.height); if (recentHeights.length > 30) recentHeights.shift(); }
    trajectory.append({ time: seconds, box });
    previous = box; previousTime = seconds;
    if (prior && rejoin.accept(box, seconds, prior)) break;
    lastGoodBuffer = buffer;
    recoveryPlayerVelocity = null;
    if (!refs.next || seconds - refs.next.time >= 0.35) { refs.camera = refs.next; refs.next = { buffer, time: seconds, box }; }
  }
  tracker.finish();
  if (missingSince != null) result.lostAt = missingSince;
  if (gaps.length) result.gaps = gaps;
  result.jerseyProfile = profile.examples.length === 0 ? prior?.jerseyProfile : profile;
  result.identity = memory.jersey.examples.length === 0 ? prior?.identity : memory;
  progress(1);
  return result;
}

/** Follow a player backwards from `start` down to `end`: frames are replayed in a mirrored time base. `frames` must
    yield frames strictly before `start`, newest first (the caller decodes short chunks and reverses them). */
export async function runBackwardTracking(frames: AsyncIterable<FramePixels>, options: Omit<SelectedTrackingOptions, "allowRecovery">): Promise<PlayerMotion> {
  const { start, end, prior } = options;
  const seedMemory: PlayerMotion = { samples: [], identity: prior?.identity, jerseyProfile: prior?.jerseyProfile };
  const mirrored = (async function* () { for await (const frame of frames) yield { ...frame, time: start - frame.time }; })();
  const backward = await runSelectedTracking(mirrored, { ...options, start: 0, end: start - end, allowRecovery: true, prior: seedMemory });
  const result: PlayerMotion = { ...backward };
  result.samples = backward.samples.map((s) => ({ time: start - s.time, box: s.box })).reverse();
  result.gaps = backward.gaps?.map((g): TimeRange => [start - g[1], start - g[0]]).sort((a, b) => a[0] - b[0]);
  result.inferred = undefined;
  result.correctionTimes = [start];
  if (backward.lostAt != null) {
    const earliest = start - backward.lostAt;
    result.samples = result.samples.filter((s) => s.time >= earliest);
    result.gaps = result.gaps?.filter((g) => g[0] >= earliest);
    result.lostAt = undefined;
  }
  result.jerseyProfile = backward.jerseyProfile ?? prior?.jerseyProfile;
  result.identity = backward.identity ?? prior?.identity;
  return result;
}
