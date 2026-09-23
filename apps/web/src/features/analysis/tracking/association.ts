/* Frame-to-frame identity decisions: exact ports of PlayerTrackingLimits, PlayerTrackingTrajectory,
   PlayerIdentityAssociation, PlayerRecoveryConfirmation (PlayerTrackingIdentity.swift), PlayerPresence and
   PlayerRosterAssociation (PlayerRoster.swift), PlayerTrackRejoinConfirmation and PlayerTrackingSearch
   (PlayerTrackRepair.swift). Pure functions and small mutable state classes; no pixels here. */
import type { Point, Rect } from "@/domain/geometry";
import type { UUID } from "@/domain/ids";
import type { CameraTransform, PlayerIdentityMemory, PlayerJerseyProfile, PlayerJerseySignature, PlayerMotion, PlayerMotionSample } from "@/domain/tracking";
import { MAXIMUM_RECOVERY_SECONDS } from "@/domain/tracking";
import { cameraDeterminant, cameraFromMatrix, cameraMatrix, cameraPoint, feet, mat3Inverse, mat3Multiply, offsetRect, overlap, rectFromFeet, rectMaxY, rectMidX, rectsEqual, rectsIntersect } from "./geometry";
import { boxAt } from "./motion";
import { galleryGate, galleryIsReady, galleryPrintSimilarity, memoryIsConfirmed, memorySimilarity, profileIsConfirmed, profileSimilarity, type PlayerObservation } from "./identity";

export const PlayerTrackingLimits = {
  maximumRecoverySeconds: MAXIMUM_RECOVERY_SECONDS,
  minimumGateWidth: 0.03,
  minimumGateHeight: 0.06,
  mergedHeightRatio: 1.35,
  /** Diagnostic hook: one line per tracking decision. */
  trace: null as ((line: string) => void) | null,
};

/** A body suddenly this much taller than the player's recent height is two bodies in one box. */
export function isMerged(box: Rect, recentHeights: readonly number[]): boolean {
  if (recentHeights.length < 8) return false;
  const sorted = recentHeights.slice().sort((a, b) => a - b);
  return box.height > sorted[sorted.length >> 1]! * PlayerTrackingLimits.mergedHeightRatio;
}

// MARK: - Trajectory

/** Recent confirmed feet (not extrapolated output) fitted linearly for prediction. */
export class PlayerTrackingTrajectory {
  samples: PlayerMotionSample[] = [];

  append(sample: PlayerMotionSample): void {
    const last = this.samples[this.samples.length - 1];
    if (last && sample.time <= last.time) return;
    if (last && sample.time - last.time > 0.25) this.samples = [];
    this.samples.push(sample);
    this.samples = this.samples.filter((s) => s.time >= sample.time - 0.7).slice(-24);
  }

  /** Re-express recent feet in the current frame after a camera move. */
  applyCamera(transform: CameraTransform): void {
    const next: PlayerMotionSample[] = [];
    for (const sample of this.samples) {
      const f = cameraPoint(transform, feet(sample.box));
      if (!f || Math.abs(f.x) >= 4 || Math.abs(f.y) >= 4) continue;
      next.push({ time: sample.time, box: rectFromFeet(f, sample.box.width, sample.box.height) });
    }
    this.samples = next;
  }

  predicted(time: number, cameraVelocity: Point = { x: 0, y: 0 }, playerVelocity?: Point): Rect | null {
    const last = this.samples[this.samples.length - 1];
    if (!last) return null;
    const first = this.samples[0]!;
    if (this.samples.length < 3 || last.time - first.time <= 0.06) return last.box;
    const meanT = this.samples.reduce((a, s) => a + s.time, 0) / this.samples.length;
    let denominator = 0, dx = 0, dy = 0;
    for (const s of this.samples) { const dt = s.time - meanT; denominator += dt * dt; dx += dt * rectMidX(s.box); dy += dt * rectMaxY(s.box); }
    if (!(denominator > 0.00001)) return last.box;
    const horizon = Math.min(PlayerTrackingLimits.maximumRecoverySeconds, Math.max(0, time - last.time));
    const maximum = Math.max(0.04, last.box.height * 2);
    const clampV = (v: number) => Math.min(maximum, Math.max(-maximum, v));
    const vx = clampV(playerVelocity ? playerVelocity.x : dx / denominator - cameraVelocity.x);
    const vy = clampV(playerVelocity ? playerVelocity.y : dy / denominator - cameraVelocity.y);
    return offsetRect(last.box, vx * horizon, vy * horizon);
  }
}

// MARK: - Single-player association

export interface AssociationCandidate {
  box: Rect;
  jersey?: PlayerJerseySignature;
  crowded?: boolean;
  /** Caller-owned index so richer roster observations can be looked up. */
  tag?: number;
}
export interface AssociationMatch { candidate: AssociationCandidate; score: number }
export type AppearanceScorer = (candidate: AssociationCandidate) => number | null;

export const minimumScore = (recovering: boolean) => (recovering ? 0.58 : 0.45);
export const associationMargin = (recovering: boolean, dormant: boolean) => (dormant ? 0.16 : recovering ? 0.12 : 0.08);

export function chooseCandidate(candidates: readonly AssociationCandidate[], expected: Rect, optical: Rect | null, profile: PlayerJerseyProfile,
  recovering: boolean, recoveryAge = 0, appearance?: AppearanceScorer): AssociationMatch | null {
  const dormant = recovering && recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds;
  const ranked = rankCandidates(candidates, expected, optical, profile, recovering, recoveryAge, appearance);
  const best = ranked[0];
  if (!best || best.score < minimumScore(recovering)) return null;
  if (ranked.length > 1 && best.score - ranked[1]!.score < associationMargin(recovering, dormant)) return null;
  return best;
}

/** Every candidate passing the identity gates, best first. */
export function rankCandidates(candidates: readonly AssociationCandidate[], expected: Rect, optical: Rect | null, profile: PlayerJerseyProfile,
  recovering: boolean, recoveryAge = 0, appearance?: AppearanceScorer): AssociationMatch[] {
  const dormant = recovering && recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds;
  const similarity: AppearanceScorer = appearance ?? ((c) => (c.jersey ? profileSimilarity(profile, c.jersey) : null));
  const unitWidth = Math.max(PlayerTrackingLimits.minimumGateWidth, expected.width);
  const unitHeight = Math.max(PlayerTrackingLimits.minimumGateHeight, expected.height);
  const matches: AssociationMatch[] = [];
  for (const candidate of candidates) {
    const box = candidate.box;
    const dx = Math.abs(rectMidX(box) - rectMidX(expected)) / unitWidth;
    const dy = Math.abs(rectMaxY(box) - rectMaxY(expected)) / unitHeight;
    if (!(dx < (dormant ? 3 : recovering ? 2 : 1.3)) || !(dy < (dormant ? 1.6 : recovering ? 1.2 : 0.8))) continue;
    const ratio = box.height / expected.height;
    if (!(ratio > 0.55) || !(ratio < 1.8)) continue;
    const look = similarity(candidate);
    const hasProfile = profile.examples.length > 0;
    if (hasProfile && (look ?? 0) < (dormant ? 0.82 : recovering ? 0.74 : 0.6)) continue;
    if (recovering) {
      if (!(profileIsConfirmed(profile) || (!candidate.crowded && (look ?? 0) >= 0.9))) continue;
      if (candidate.crowded) {
        const neighbours = candidates.filter((o) => !rectsEqual(o.box, box) && overlap(o.box, box) > 0.25);
        if (look == null || look < 0.82 || neighbours.length === 0) continue;
        const separable = neighbours.every((other) => { const s = similarity(other); return s != null && s < 0.55 && look - s > 0.3; });
        if (!separable) continue;
      }
    }
    const spatial = Math.max(0, 1 - Math.hypot(dx, dy) / (dormant ? 3.3 : recovering ? 2.2 : 1.5));
    const opticalOverlap = optical ? overlap(optical, box) : 0;
    const score = hasProfile ? (look ?? 0) * 0.45 + spatial * 0.4 + opticalOverlap * 0.15 : spatial * 0.6 + opticalOverlap * 0.4;
    matches.push({ candidate, score });
  }
  return matches.sort((a, b) => b.score - a.score);
}

// MARK: - Recovery confirmation

/** Reacquisition requires agreement in two detector observations, not one same-colour body passing by. */
export class PlayerRecoveryConfirmation {
  private pending: { time: number; box: Rect; camera?: CameraTransform | null } | null = null;
  private confirmations = 0;

  accept(box: Rect | null, time: number, camera: CameraTransform | null = null, requiredObservations = 2, maximumInterval = 0.3): boolean {
    if (!box) { this.pending = null; this.confirmations = 0; return false; }
    const previous = this.pending;
    this.pending = { time, box, camera };
    if (!previous || time - previous.time < 0.04 || time - previous.time > maximumInterval) { this.confirmations = 1; return false; }
    let f = feet(previous.box);
    if (camera && previous.camera && Math.abs(cameraDeterminant(previous.camera)) > 0.00001) {
      const inverse = mat3Inverse(cameraMatrix(previous.camera));
      const mapped = inverse ? cameraPoint(cameraFromMatrix(mat3Multiply(cameraMatrix(camera), inverse)), f) : null;
      if (mapped) f = mapped;
    }
    const confirmed = Math.abs(rectMidX(box) - f.x) < Math.max(PlayerTrackingLimits.minimumGateWidth, box.width, previous.box.width) * 0.8 &&
      Math.abs(rectMaxY(box) - f.y) < Math.max(PlayerTrackingLimits.minimumGateHeight, box.height, previous.box.height) * 0.5;
    this.confirmations = confirmed ? this.confirmations + 1 : 1;
    if (this.confirmations >= requiredObservations) { this.pending = null; this.confirmations = 0; return true; }
    return false;
  }
}

// MARK: - Presence

export const PlayerPresence = {
  /** Whether a last confirmed box was touching an edge. */
  leftFrame(box: Rect): boolean { return box.x < 0.02 || box.x + box.width > 0.98 || rectMaxY(box) > 0.97 || box.y < 0.01; },

  /** The single lone body matching every remembered cue clearly better than any other. */
  findAnywhere(observations: readonly PlayerObservation[], memory: PlayerIdentityMemory, minimum = 0.85, margin = 0.1, plausible: (box: Rect) => boolean = () => true): number | null {
    if (!memoryIsConfirmed(memory) || !(memory.chroma && profileIsConfirmed(memory.chroma)) || !memory.gallery || !galleryIsReady(memory.gallery)) return null;
    const gallery = memory.gallery;
    const ranked: [number, number][] = [];
    observations.forEach((o, index) => {
      if (o.crowded || !plausible(o.box)) return;
      const similarity = memorySimilarity(memory, o);
      if (similarity == null || similarity < minimum || !o.print) return;
      const likeness = galleryPrintSimilarity(gallery, o.print);
      if (likeness == null || likeness < galleryGate(gallery)) return;
      ranked.push([index, similarity]);
    });
    ranked.sort((a, b) => b[1] - a[1]);
    const best = ranked[0];
    if (!best || (ranked.length > 1 && best[1] - ranked[1]![1] < margin)) return null;
    return best[0];
  },
};

// MARK: - Roster association

export interface RosterExpectation {
  id: UUID;
  /** Predicted position in the current frame; null when only appearance is known. */
  box: Rect | null;
  memory: PlayerIdentityMemory;
  recovering: boolean;
  recoveryAge: number;
  /** Where the player was last seen on screen (during a pan, the camera-following hypothesis). */
  alternative?: Rect | null;
}
export const expectationIsDormant = (e: RosterExpectation) => e.recovering && e.recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds;
export const expectationIsOffscreen = (e: RosterExpectation) => !e.box || rectMidX(e.box) < 0.01 || rectMidX(e.box) > 0.99 || rectMaxY(e.box) < 0.02 || e.box.y > 0.98;

export interface RosterAssignment { id: UUID; observation: number; score: number }
export interface RosterAssignmentResult {
  assignments: RosterAssignment[];
  ambiguous: Set<UUID>;
  claimed: Set<number>;
  contested: Set<number>;
}
export const assignmentFor = (r: RosterAssignmentResult, id: UUID) => r.assignments.find((a) => a.id === id) ?? null;

/** One exclusive assignment for every remembered player in a frame. */
export function assignRoster(expectations: readonly RosterExpectation[], observations: readonly PlayerObservation[]): RosterAssignmentResult {
  const result: RosterAssignmentResult = { assignments: [], ambiguous: new Set(), claimed: new Set(), contested: new Set() };
  const pairs: { row: number; column: number; score: number }[] = [];
  const owners = new Map<number, number>();
  expectations.forEach((expectation, row) => {
    for (const match of rosterMatches(expectation, observations)) {
      pairs.push({ row, column: match.column, score: match.score });
      owners.set(match.column, (owners.get(match.column) ?? 0) + 1);
    }
  });
  result.claimed = new Set(owners.keys());
  result.contested = new Set([...owners].filter(([, count]) => count > 1).map(([column]) => column));
  pairs.sort((a, b) => b.score - a.score);
  const takenRows = new Set<number>(), takenColumns = new Set<number>();
  for (const phase of [false, true]) {
    const rows = new Set(expectations.map((_, i) => i).filter((i) => expectations[i]!.recovering === phase));
    const blockedRows = new Set<number>(), blockedColumns = new Set<number>();
    for (const pair of pairs) {
      if (!rows.has(pair.row)) continue;
      if (takenRows.has(pair.row) || takenColumns.has(pair.column) || blockedRows.has(pair.row) || blockedColumns.has(pair.column)) continue;
      const expectation = expectations[pair.row]!;
      const margin = associationMargin(expectation.recovering, expectationIsDormant(expectation));
      const rowRunner = Math.max(0, ...pairs.filter((p) => p.row === pair.row && p.column !== pair.column && !takenColumns.has(p.column)).map((p) => p.score));
      const columnRunner = Math.max(0, ...pairs.filter((p) => p.column === pair.column && p.row !== pair.row && rows.has(p.row) && !takenRows.has(p.row)).map((p) => p.score));
      if (pair.score - rowRunner >= margin && pair.score - columnRunner >= margin) {
        takenRows.add(pair.row); takenColumns.add(pair.column);
        result.assignments.push({ id: expectation.id, observation: pair.column, score: pair.score });
      } else {
        blockedRows.add(pair.row); blockedColumns.add(pair.column);
        result.ambiguous.add(expectation.id);
      }
    }
  }
  return result;
}

/** Robust mode of the common displacement when several players dropped out together (a blurred pan). */
export function crowdOffset(expectations: readonly RosterExpectation[], observations: readonly PlayerObservation[]): Point | null {
  const recovering = expectations.map((e, row) => ({ row, e })).filter(({ e }) => e.recovering && !expectationIsDormant(e) && e.box);
  if (recovering.length < 3) return null;
  const vectors: { row: number; offset: Point }[] = [];
  for (const { row, e } of recovering) {
    const box = e.box!;
    for (const o of observations) {
      if (o.crowded) continue;
      const ratio = o.box.height / Math.max(0.001, box.height);
      if (!(ratio > 0.7 && ratio < 1.4)) continue;
      const similarity = memorySimilarity(e.memory, o);
      if (similarity == null || similarity < 0.7) continue;
      const offset = { x: rectMidX(o.box) - rectMidX(box), y: rectMaxY(o.box) - rectMaxY(box) };
      if (Math.hypot(offset.x, offset.y) >= 0.35) continue;
      vectors.push({ row, offset });
    }
  }
  if (vectors.length < 3) return null;
  const support = (centre: Point) => vectors.filter((v) => Math.hypot(v.offset.x - centre.x, v.offset.y - centre.y) < 0.03);
  let best: typeof vectors = [];
  for (const v of vectors) { const s = support(v.offset); if (new Set(s.map((x) => x.row)).size > new Set(best.map((x) => x.row)).size) best = s; }
  const voters = new Set(best.map((v) => v.row)).size;
  if (voters < Math.max(4, Math.ceil(recovering.length * 0.6))) return null;
  const mean = { x: best.reduce((a, v) => a + v.offset.x, 0) / best.length, y: best.reduce((a, v) => a + v.offset.y, 0) / best.length };
  const longest = Math.max(0, ...recovering.map(({ e }) => e.recoveryAge));
  const magnitude = Math.hypot(mean.x, mean.y);
  return magnitude > 0.015 && magnitude <= 0.08 + 0.2 * longest ? mean : null;
}

/** Gate-passing observations for one identity, best first. */
export function rosterMatches(expectation: RosterExpectation, observations: readonly PlayerObservation[]): { column: number; score: number }[] {
  const memory = expectation.memory;
  const appearance: AppearanceScorer = (candidate) => { const o = observations[candidate.tag ?? 0]; return o ? memorySimilarity(memory, o) : null; };
  const candidates: AssociationCandidate[] = observations.map((o, tag) => ({ box: o.box, jersey: o.jersey, crowded: o.crowded, tag }));
  const box = expectation.box;
  if (box && !expectationIsDormant(expectation)) {
    const minimum = minimumScore(expectation.recovering);
    const ranked = (expected: Rect) => rankCandidates(candidates, expected, null, memory.jersey, expectation.recovering, expectation.recoveryAge, appearance)
      .filter((m) => m.score >= minimum).map((m) => ({ column: m.candidate.tag ?? 0, score: m.score }));
    const primary = ranked(box);
    const alternative = expectation.alternative;
    if (!expectation.recovering || !alternative || Math.hypot(rectMidX(alternative) - rectMidX(box), rectMaxY(alternative) - rectMaxY(box)) <= Math.max(0.02, box.width)) return primary;
    const secondary = ranked(alternative);
    if (primary[0] && secondary[0] && primary[0].column !== secondary[0].column) return [];
    const merged = new Map<number, number>();
    for (const m of [...primary, ...secondary]) merged.set(m.column, Math.max(merged.get(m.column) ?? 0, m.score));
    return [...merged].map(([column, score]) => ({ column, score })).sort((a, b) => b.score - a.score);
  }
  if (!expectation.recovering || !memoryIsConfirmed(memory)) return [];
  const anchor = box ? { x: Math.min(1, Math.max(0, rectMidX(box))), y: Math.min(1, Math.max(0, rectMaxY(box))) } : null;
  const reach = expectationIsOffscreen(expectation) ? 0.4 : Math.min(1.2, 0.3 + Math.max(0, expectation.recoveryAge - 3) * 0.3);
  const matches: { column: number; score: number }[] = [];
  for (const candidate of candidates) {
    if (candidate.crowded) continue;
    const similarity = appearance(candidate);
    if (similarity == null || similarity < 0.82) continue;
    let spatial = 0.5;
    if (anchor && box) {
      const distance = Math.hypot(rectMidX(candidate.box) - anchor.x, rectMaxY(candidate.box) - anchor.y);
      const ratio = candidate.box.height / Math.max(0.001, box.height);
      if (distance > reach || !(ratio > 0.5) || !(ratio < 2)) continue;
      spatial = 1 - distance / reach;
    }
    matches.push({ column: candidate.tag ?? 0, score: similarity * 0.6 + spatial * 0.4 });
  }
  return matches.sort((a, b) => b.score - a.score);
}

// MARK: - Repair rejoin and focused search

/** Sustained agreement before handing an earlier repair back to saved tracking. */
export class PlayerTrackRejoinConfirmation {
  private matchingSince: number | null = null;
  private previousTime: number | null = null;
  constructor(readonly start: number) {}
  reset(): void { this.matchingSince = null; this.previousTime = null; }
  accept(box: Rect, time: number, saved: PlayerMotion): boolean {
    const old = time >= this.start + 0.5 ? boxAt(saved, time) : null;
    if (!old || overlap(old, box) < 0.65 || Math.abs(rectMaxY(old) - rectMaxY(box)) > Math.max(0.003, old.height * 0.15)) { this.reset(); return false; }
    if (this.previousTime != null && time - this.previousTime > 0.15) this.matchingSince = null;
    if (this.matchingSince == null) this.matchingSince = time;
    this.previousTime = time;
    return time - this.matchingSince >= 0.35;
  }
}

/** Square-ish crop keeping context around a small player; clamped, not intersected, to preserve scale. */
export function searchRegion(box: Rect): Rect | null {
  const midX = rectMidX(box), midY = box.y + box.height / 2;
  if (!(box.width > 0) || !(box.height > 0) || !Number.isFinite(midX) || !Number.isFinite(midY)) return null;
  if (!rectsIntersect(box, { x: -0.1, y: -0.1, width: 1.2, height: 1.2 })) return null;
  const width = Math.min(1, Math.max(0.18, box.width * 8)), height = Math.min(1, Math.max(0.28, box.height * 5));
  return { x: Math.min(1 - width, Math.max(0, midX - width / 2)), y: Math.min(1 - height, Math.max(0, midY - height / 2)), width, height };
}
