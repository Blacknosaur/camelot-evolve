/* Pure display-side motion helpers: exact ports of `PlayerMotion` (SelectedPlayerTracking.swift),
   `PlayerMotion` extensions in PlayerTrackRepair.swift / PlayerTrackBridging.swift and
   `AnnotationCameraMotion` (AnnotationCameraMotion.swift). No DOM, no side effects. */
import type { Point, Rect } from "@/domain/geometry";
import type { AnnotationCameraMotion, CameraTransform, PlayerMotion, PlayerMotionSample, TimeRange } from "@/domain/tracking";
import { IDENTITY_CAMERA_TRANSFORM } from "@/domain/tracking";
import { cameraDeterminant, cameraFromMatrix, cameraMatrix, cameraPoint, feet, lerpRect, lowerBound, mat3Inverse, mat3Multiply, nextDown, nextUp, rectFromFeet, rectMaxX, rectMaxY, rectMidX } from "./geometry";

export const MAXIMUM_BRIDGE_HORIZON = 4;
export const MAXIMUM_HOLD_SECONDS = 1;
const INFERRED_INTERVAL = 1 / 12;

const rangeContains = (range: TimeRange, t: number) => t >= range[0] && t <= range[1];
const rangesOverlap = (a: TimeRange, b: TimeRange) => a[0] <= b[1] && a[1] >= b[0];
const sortRanges = (ranges: TimeRange[]) => ranges.slice().sort((a, b) => a[0] - b[0]);

export const bridgeHorizon = (m: PlayerMotion) => m.gapBridging ?? 0.4;
/** A lost player keeps its last position briefly rather than vanishing on the last confirmed frame. */
export const holdSeconds = (m: PlayerMotion) => (bridgeHorizon(m) > 0.4 ? Math.min(1, bridgeHorizon(m)) : 0);
export const referenceBox = (m: PlayerMotion): Rect | undefined => m.referenceBox ?? m.samples[0]?.box;

/** Raw tracking absent at this time: inside a recorded gap, after a terminal loss, or outside the span. */
export function isMissing(m: PlayerMotion, time: number): boolean {
  const first = m.samples[0], last = m.samples[m.samples.length - 1];
  if (!first || !last) return true;
  if (time < first.time - 0.05 || time > last.time + 0.12) return true;
  if (m.lostAt != null && time >= m.lostAt) return true;
  return m.gaps?.some((g) => rangeContains(g, time)) ?? false;
}

/** Interpolated, stabilised box at `time`, or null where the player is unknown. */
export function boxAt(m: PlayerMotion, time: number): Rect | null {
  const bridged = inferredBox(m, time);
  if (bridged) return bridged;
  const samples = m.samples;
  const first = samples[0], last = samples[samples.length - 1];
  if (!first || !last || time < first.time - 0.05 || time > last.time + 0.12) return null;
  if (m.lostAt != null && !(time < m.lostAt)) return null;
  const gap = m.gaps?.find((g) => rangeContains(g, time));
  if (gap) return interpolatedGap(m, time, gap);
  let low = 0, high = samples.length - 1;
  while (low < high) { const mid = (low + high) >> 1; if (samples[mid]!.time < time) low = mid + 1; else high = mid; }
  if (low === 0) return first.box;
  const a = samples[low - 1]!, b = samples[low]!;
  const t = Math.min(1, Math.max(0, (time - a.time) / Math.max(0.001, b.time - a.time)));
  return lerpRect(stabilisedBox(m, low - 1), stabilisedBox(m, low), t);
}

function interpolatedGap(m: PlayerMotion, time: number, gap: TimeRange): Rect | null {
  const horizon = Math.min(0.4, bridgeHorizon(m));
  if (gap[1] - gap[0] > horizon) return null;
  const left = findLastIndex(m.samples, (s) => s.time < gap[0]);
  const right = m.samples.findIndex((s) => s.time > gap[1]);
  if (left < 0 || right < 0) return null;
  const a = m.samples[left]!, b = m.samples[right]!;
  if (b.time - a.time > horizon + 0.1) return null;
  if (m.lostAt != null && !(b.time < m.lostAt)) return null;
  if (m.gaps?.some((g) => rangeContains(g, a.time) || rangeContains(g, b.time))) return null;
  if (m.correctionTimes?.some((c) => c > a.time && c <= b.time)) return null;
  const lhs = stabilisedBox(m, left), rhs = stabilisedBox(m, right);
  const inside = (r: Rect) => r.width > 0 && r.height > 0 && r.x > 0 && rectMaxX(r) < 1 && r.y > 0 && rectMaxY(r) < 1;
  if (!inside(lhs) || !inside(rhs)) return null;
  if (Math.max(lhs.width, rhs.width) / Math.min(lhs.width, rhs.width) >= 1.5) return null;
  if (Math.max(lhs.height, rhs.height) / Math.min(lhs.height, rhs.height) >= 1.5) return null;
  if (Math.hypot(rectMidX(rhs) - rectMidX(lhs), rectMaxY(rhs) - rectMaxY(lhs)) > Math.max(0.025, Math.min(lhs.height, rhs.height) * 0.6)) return null;
  return lerpRect(lhs, rhs, (time - a.time) / (b.time - a.time));
}

function inferredBox(m: PlayerMotion, time: number): Rect | null {
  const inferred = m.inferred;
  if (m.gapBridging == null || !inferred || inferred.length === 0 || !isMissing(m, time)) return null;
  const gap = m.gaps?.find((g) => rangeContains(g, time));
  if (gap) {
    const a = findLast(m.samples, (s) => s.time < gap[0]), b = m.samples.find((s) => s.time > gap[1]);
    if (!a || !b || b.time - a.time > bridgeHorizon(m) + 0.1) return null;
  } else {
    const anchor = m.lostAt != null ? findLast(m.samples, (s) => s.time < m.lostAt!) : m.samples[m.samples.length - 1];
    if (!(holdSeconds(m) > 0) || !anchor || !(time > anchor.time) || time - anchor.time > holdSeconds(m) + 0.05) return null;
  }
  const low = lowerBound(inferred, time, (s) => s.time);
  const next = low < inferred.length ? inferred[low] : undefined;
  const previous = low > 0 ? inferred[low - 1] : undefined;
  if (previous && next && next.time - previous.time <= 0.2) {
    return lerpRect(previous.box, next.box, (time - previous.time) / Math.max(0.001, next.time - previous.time));
  }
  if (previous && Math.abs(previous.time - time) <= 0.1) return previous.box;
  if (next && Math.abs(next.time - time) <= 0.1) return next.box;
  return null;
}

/** Centred local linear fit that reduces box wobble without trailing lag. */
function stabilisedBox(m: PlayerMotion, index: number): Rect {
  const samples = m.samples, sample = samples[index]!;
  const amount = Math.min(1, Math.max(0, m.smoothing ?? 0.65));
  if (!(amount > 0) || index <= 0 || index >= samples.length - 1) return sample.box;
  if (m.correctionTimes?.some((c) => Math.abs(c - sample.time) < 1 / 600)) return sample.box;
  if (m.anchors?.some((a) => Math.abs(a - sample.time) < 1 / 600)) return sample.box;
  const radius = 0.1 + amount * 0.22;
  let weight = 0, dtSum = 0, dtSquared = 0;
  const values = [0, 0, 0, 0], slopes = [0, 0, 0, 0];
  for (let n = Math.max(0, index - 24); n <= Math.min(samples.length - 1, index + 24); n++) {
    const candidate = samples[n]!, dt = candidate.time - sample.time;
    if (Math.abs(dt) > radius) continue;
    const lower = Math.min(candidate.time, sample.time), upper = Math.max(candidate.time, sample.time);
    if (m.gaps?.some((g) => g[0] <= upper && g[1] >= lower)) continue;
    if (m.correctionTimes?.some((c) => c > lower && c <= upper)) continue;
    if (m.lostAt != null && !(candidate.time < m.lostAt)) continue;
    const w = Math.exp(-0.5 * Math.pow(dt / (radius * 0.48), 2));
    const b = candidate.box, value = [rectMidX(b), rectMaxY(b), b.width, b.height];
    weight += w; dtSum += w * dt; dtSquared += w * dt * dt;
    for (let k = 0; k < 4; k++) { values[k]! += value[k]! * w; slopes[k]! += value[k]! * (w * dt); }
  }
  const determinant = weight * dtSquared - dtSum * dtSum;
  if (!(determinant > 0.000001)) return sample.box;
  const raw = [rectMidX(sample.box), rectMaxY(sample.box), sample.box.width, sample.box.height];
  const value = raw.map((r, k) => r + ((values[k]! * dtSquared - slopes[k]! * dtSum) / determinant - r) * amount);
  const width = Math.max(0.001, value[2]!), height = Math.max(0.001, value[3]!);
  return { x: value[0]! - width / 2, y: value[1]! - height, width, height };
}

// MARK: - Effect geometry (PlayerTrackRepair.swift)

const complete = (box: Rect) => box.x > 0.012 && rectMaxX(box) < 0.988 && box.y > 0.025 && rectMaxY(box) < 1 - Math.max(0.025, box.height * 0.2);

/** Full-body scale for effects even when the detector rectangle is cropped at an image edge. */
export function effectBodyBox(m: PlayerMotion, time: number): Rect | null {
  const current = boxAt(m, time);
  if (!current) return null;
  const samples = m.samples;
  let low = 0, high = samples.length;
  while (low < high) { const mid = (low + high) >> 1; if (samples[mid]!.time <= time) low = mid + 1; else high = mid; }
  const index = Math.max(0, low - 1), raw = samples[index]!.box;
  const recent: PlayerMotionSample[] = [];
  for (let i = Math.max(0, index - 90); i <= index; i++) {
    const s = samples[i]!;
    if (s.time < time - 2 || !complete(s.box)) continue;
    if (m.gaps?.some((g) => g[0] <= Math.max(time, s.time) && g[1] >= s.time)) continue;
    if (m.correctionTimes?.some((c) => c > s.time && c <= time)) continue;
    recent.push(s);
  }
  const ratios = recent.map((s) => s.box.width / Math.max(0.001, s.box.height)).sort((a, b) => a - b);
  const ref = referenceBox(m);
  const anchor = ref && complete(ref) ? ref : undefined;
  const ratio = anchor ? anchor.width / Math.max(0.001, anchor.height) : ratios.length === 0 ? current.width / Math.max(0.001, current.height) : ratios[ratios.length >> 1]!;
  if (complete(raw)) {
    const width = current.height * ratio;
    return { x: rectMidX(current) - width / 2, y: current.y, width, height: current.height };
  }
  if (recent.length === 0) return null;
  const heights = recent.map((s) => s.box.height).sort((a, b) => a - b), widths = recent.map((s) => s.box.width).sort((a, b) => a - b);
  const fullHeight = heights[Math.floor((heights.length - 1) * 0.75)]!, fullWidth = widths[widths.length >> 1]!;
  const horizontalCrop = raw.x <= 0.012 || rectMaxX(raw) >= 0.988;
  const verticalCrop = raw.y <= 0.025 || rectMaxY(raw) >= 1 - Math.max(0.025, raw.height * 0.2);
  const scale = horizontalCrop ? 1 : Math.min(1.2, Math.max(0.9, current.width / Math.max(0.001, fullWidth)));
  const height = verticalCrop ? Math.max(current.height, fullHeight * scale) : current.height;
  const width = height * ratio;
  const centerX = raw.x <= 0.012 ? rectMaxX(current) - width / 2 : rectMaxX(raw) >= 0.988 ? current.x + width / 2 : rectMidX(current);
  const top = raw.y <= 0.025 ? rectMaxY(current) - height : current.y;
  return { x: centerX - width / 2, y: top, width, height };
}

/** Steadier body height for overhead graphics: centred 0.8 s average of complete bodies. */
export function overheadHeight(m: PlayerMotion, time: number): number | null {
  const body = effectBodyBox(m, time);
  if (!body) return null;
  const radius = 0.8, samples = m.samples;
  const low = lowerBound(samples, time - radius, (s) => s.time);
  const nearby = samples.slice(low, Math.min(samples.length, low + 240)).filter((s) => {
    const lo = Math.min(time, s.time), hi = Math.max(time, s.time);
    return Math.abs(s.time - time) < radius && complete(s.box) && (m.lostAt == null || s.time < m.lostAt) &&
      !(m.gaps?.some((g) => rangesOverlap(g, [lo, hi])) ?? false) && !(m.correctionTimes?.some((c) => c > lo && c <= hi) ?? false);
  });
  if (nearby.length === 0) return body.height;
  const heights = nearby.map((s) => s.box.height).sort((a, b) => a - b), median = heights[heights.length >> 1]!;
  let sum = 0, weight = 0;
  for (const s of nearby) {
    const h = s.box.height;
    if (h < median * 0.5 || h > median * 1.5) continue;
    const w = Math.pow(1 - Math.abs(s.time - time) / radius, 2);
    sum += w * h; weight += w;
  }
  return weight > 0 ? sum / weight : body.height;
}

/** Floor contact estimate: local fit of the lower-foot envelope, no extrapolation across gaps. */
export function groundPoint(m: PlayerMotion, time: number): Point | null {
  const current = effectBodyBox(m, time);
  if (!current) return null;
  const fallback: Point = { x: rectMidX(current), y: rectMaxY(current) };
  if (rectMaxY(current) >= 0.985 || current.y <= 0.012 || current.x <= 0.012 || rectMaxX(current) >= 0.988) return fallback;
  const radius = 0.18, samples = m.samples;
  const lower = lowerBound(samples, time - radius, (s) => s.time);
  const nearby = samples.slice(lower, Math.min(samples.length, lower + 64)).filter((s) => {
    const lo = Math.min(time, s.time), hi = Math.max(time, s.time);
    return Math.abs(s.time - time) <= radius && (m.lostAt == null || s.time < m.lostAt) &&
      !(m.gaps?.some((g) => rangesOverlap(g, [lo, hi])) ?? false) && !(m.correctionTimes?.some((c) => c > lo && c <= hi) ?? false);
  });
  if (nearby.length < 3) return fallback;
  const meanTime = nearby.reduce((a, s) => a + s.time, 0) / nearby.length;
  const meanY = nearby.reduce((a, s) => a + rectMaxY(s.box), 0) / nearby.length;
  const denominator = nearby.reduce((a, s) => a + Math.pow(s.time - meanTime, 2), 0);
  if (!(denominator > 0.00001)) return fallback;
  const slope = nearby.reduce((a, s) => a + (s.time - meanTime) * (rectMaxY(s.box) - meanY), 0) / denominator;
  const intercepts = nearby.map((s) => rectMaxY(s.box) - slope * (s.time - time)).sort((a, b) => a - b);
  const footY = intercepts[Math.min(intercepts.length - 1, Math.floor((intercepts.length - 1) * 0.75))]!;
  const adjustment = Math.min(current.height * 0.08, Math.max(-current.height * 0.04, footY - rectMaxY(current)));
  return { x: rectMidX(current), y: rectMaxY(current) + adjustment };
}

// MARK: - Missing intervals, placement and bridging (PlayerTrackBridging.swift)

export function missingIntervals(m: PlayerMotion, range: TimeRange): TimeRange[] {
  const first = m.samples[0], last = m.samples[m.samples.length - 1];
  if (!first || !last) return [range];
  const intervals: TimeRange[] = [];
  if (first.time - range[0] > 0.12) intervals.push([range[0], nextDown(first.time)]);
  for (const gap of m.gaps ?? []) if (gap[1] >= range[0] && gap[0] <= range[1]) intervals.push([Math.max(range[0], gap[0]), Math.min(range[1], gap[1])]);
  const tail = Math.min(m.lostAt ?? Infinity, last.time);
  if (range[1] - tail > 0.12) intervals.push([Math.max(range[0], nextUp(tail)), range[1]]);
  return sortRanges(intervals);
}
export const nextMissing = (m: PlayerMotion, time: number, range: TimeRange) => missingIntervals(m, range).find((i) => i[0] > time + 0.02)?.[0] ?? null;
export const previousMissing = (m: PlayerMotion, time: number, range: TimeRange) => findLast(missingIntervals(m, range), (i) => i[0] < time - 0.02)?.[0] ?? null;

/** Insert a hand-placed position; returns a new motion (the gap splits around it, a loss becomes a gap). */
export function placeSample(motion: PlayerMotion, box: Rect, time: number): PlayerMotion {
  const tolerance = 1 / 60;
  const m: PlayerMotion = { ...motion, samples: motion.samples.map((s) => ({ ...s })) };
  const existing = m.samples.findIndex((s) => Math.abs(s.time - time) < tolerance);
  if (existing >= 0) m.samples[existing]!.box = box;
  else {
    const index = m.samples.findIndex((s) => s.time > time);
    m.samples.splice(index < 0 ? m.samples.length : index, 0, { time, box });
  }
  const intervals: TimeRange[] = [];
  for (const gap of m.gaps ?? []) {
    if (!rangeContains(gap, time)) { intervals.push(gap); continue; }
    if (gap[0] < time - tolerance) intervals.push([gap[0], nextDown(time)]);
    if (gap[1] > time + tolerance) intervals.push([nextUp(time), gap[1]]);
  }
  if (m.lostAt != null && time >= m.lostAt) {
    const previous = findLast(m.samples, (s) => s.time < m.lostAt!);
    if (previous && time - previous.time > tolerance) intervals.push([Math.max(m.lostAt, nextUp(previous.time)), nextDown(time)]);
    m.lostAt = undefined;
  } else {
    const neighbours = m.samples.filter((s) => Math.abs(s.time - time) >= tolerance);
    const previous = findLast(neighbours, (s) => s.time < time), next = neighbours.find((s) => s.time > time);
    if (previous && time - previous.time > 0.12 && !intervals.some((i) => rangeContains(i, nextUp(previous.time)))) intervals.push([nextUp(previous.time), nextDown(time)]);
    if (next && next.time - time > 0.12 && !intervals.some((i) => rangeContains(i, nextDown(next.time)))) intervals.push([nextUp(time), nextDown(next.time)]);
  }
  m.gaps = intervals.length === 0 ? undefined : sortRanges(intervals);
  const placed = (m.anchors ?? []).filter((a) => Math.abs(a - time) >= tolerance);
  placed.push(time);
  m.anchors = placed.sort((a, b) => a - b);
  m.inferred = undefined;
  return m;
}

/** Recompute display-only bridged positions, camera-aware when a clip camera track exists. */
export function bridged(motion: PlayerMotion, camera: AnnotationCameraMotion | undefined | null): PlayerMotion {
  const filled: PlayerMotionSample[] = [];
  const carried = (sample: PlayerMotionSample, time: number): PlayerMotionSample | null => {
    const from = camera ? transformAt(camera, sample.time) : null, to = camera ? transformAt(camera, time) : null;
    if (!camera || !from || !to || Math.abs(cameraDeterminant(from)) <= 0.00001) return { time, box: sample.box };
    const inverse = mat3Inverse(cameraMatrix(from));
    if (!inverse) return { time, box: sample.box };
    const relative = cameraFromMatrix(mat3Multiply(cameraMatrix(to), inverse));
    const f = cameraPoint(relative, feet(sample.box));
    if (!f || Math.abs(f.x) >= 3 || Math.abs(f.y) >= 3) return null;
    return { time, box: rectFromFeet(f, sample.box.width, sample.box.height) };
  };
  for (const gap of motion.gaps ?? []) {
    const a = findLast(motion.samples, (s) => s.time < gap[0]), b = motion.samples.find((s) => s.time > gap[1]);
    if (!a || !b || b.time - a.time > MAXIMUM_BRIDGE_HORIZON + 0.1) continue;
    if (motion.lostAt != null && !(b.time < motion.lostAt)) continue;
    if (motion.correctionTimes?.some((c) => c > a.time && c <= b.time)) continue;
    for (let time = a.time + INFERRED_INTERVAL; time < b.time; time += INFERRED_INTERVAL) {
      const fromA = carried(a, time), fromB = carried(b, time);
      if (!fromA || !fromB) continue;
      const t = (time - a.time) / (b.time - a.time);
      const width = fromA.box.width + (fromB.box.width - fromA.box.width) * t;
      const height = fromA.box.height + (fromB.box.height - fromA.box.height) * t;
      const x = rectMidX(fromA.box) + (rectMidX(fromB.box) - rectMidX(fromA.box)) * t;
      const y = rectMaxY(fromA.box) + (rectMaxY(fromB.box) - rectMaxY(fromA.box)) * t;
      filled.push({ time, box: { x: x - width / 2, y: y - height, width, height } });
    }
  }
  if (motion.lostAt != null) {
    const last = findLast(motion.samples, (s) => s.time < motion.lostAt!);
    if (last) for (let time = last.time + INFERRED_INTERVAL; time <= last.time + MAXIMUM_HOLD_SECONDS + 0.001; time += INFERRED_INTERVAL) {
      const held = carried(last, time);
      if (held) filled.push(held);
    }
  }
  return { ...motion, inferred: filled.length === 0 ? undefined : filled.sort((a, b) => a.time - b.time) };
}

// MARK: - Repair splicing (AnalysisTrackingLibrary.swift extension)

export function correctionTime(m: PlayerMotion): number | null {
  if (m.lostAt == null) return null;
  return findLast(m.samples, (s) => s.time < m.lostAt!)?.time ?? m.samples[0]?.time ?? m.lostAt;
}

export function repairEnd(m: PlayerMotion, start: number, end: number): number {
  const later = (m.correctionTimes ?? []).filter((c) => c > start + 1 / 60);
  return Math.min(end, later.length ? Math.min(...later) : end);
}

/** Splice only the completed repair, never truncate the saved future. */
export function continuing(self: PlayerMotion, motion: PlayerMotion, start: number): PlayerMotion {
  const boundary = repairEnd(self, start, Infinity);
  const replacement = motion.samples.filter((s) => s.time >= start && s.time < boundary);
  const finish = replacement[replacement.length - 1]?.time;
  if (finish == null) return self;
  const range: TimeRange = [start, finish];
  const before = self.samples.filter((s) => s.time < start), after = self.samples.filter((s) => s.time > finish);
  const result: PlayerMotion = { ...self, samples: [...before, ...replacement, ...after] };
  const unavailable: TimeRange[] = [...(self.gaps ?? [])];
  const lastTime = self.samples[self.samples.length - 1]?.time;
  if (self.lostAt != null && lastTime != null && self.lostAt <= lastTime) unavailable.push([self.lostAt, lastTime]);
  let intervals: TimeRange[] = unavailable.flatMap((gap) => {
    if (!rangesOverlap(gap, range)) return [gap];
    const pieces: TimeRange[] = [];
    if (gap[0] < start) pieces.push([gap[0], nextDown(start)]);
    if (gap[1] > finish) pieces.push([nextUp(finish), gap[1]]);
    return pieces;
  });
  for (const gap of motion.gaps ?? []) {
    const lower = Math.max(start, gap[0]), upper = Math.min(finish, gap[1]);
    if (lower <= upper) intervals.push([lower, upper]);
  }
  const last = before[before.length - 1]?.time;
  if (last != null && start - last > 0.12) {
    const lower = self.lostAt != null && self.lostAt > last && self.lostAt < start ? self.lostAt : nextUp(last);
    intervals.push([lower, nextDown(start)]);
  }
  const next = after[0]?.time;
  if (next != null && next - finish > 0.12) intervals.push([nextUp(finish), nextDown(next)]);
  const hasConfirmedFuture = after.some((s) => (self.lostAt == null || s.time < self.lostAt) && !(self.gaps?.some((g) => rangeContains(g, s.time)) ?? false));
  result.lostAt = hasConfirmedFuture ? self.lostAt : motion.lostAt;
  if (!hasConfirmedFuture && result.lostAt == null && after.length > 0) result.lostAt = nextUp(finish);
  intervals = sortRanges(intervals);
  result.gaps = intervals;
  const anchors = (self.correctionTimes ?? (self.samples[0] ? [self.samples[0].time] : [])).filter((a) => Math.abs(a - start) >= 1 / 60);
  anchors.push(start);
  result.correctionTimes = anchors.sort((a, b) => a - b);
  result.recoveryCount = (self.recoveryCount ?? 0) + (motion.recoveryCount ?? 0);
  result.jerseyProfile = motion.jerseyProfile ?? self.jerseyProfile;
  result.identity = motion.identity ?? self.identity;
  const placed = (self.anchors ?? []).filter((a) => !rangeContains(range, a));
  result.anchors = placed.length === 0 ? undefined : placed;
  result.inferred = undefined;
  result.gapBridging = self.gapBridging ?? motion.gapBridging;
  return result;
}

/** Join a backward pass in front of this track. */
export function prepending(self: PlayerMotion, earlier: PlayerMotion, start: number): PlayerMotion {
  const before = earlier.samples.filter((s) => s.time < start), after = self.samples.filter((s) => s.time >= start);
  const result: PlayerMotion = { ...self, samples: [...before, ...after] };
  const intervals: TimeRange[] = [...(earlier.gaps ?? []).filter((g) => g[1] < start), ...(self.gaps ?? []).filter((g) => g[0] >= start)];
  const first = after[0]?.time, last = before[before.length - 1]?.time;
  if (first != null && last != null && first - last > 0.12) intervals.push([nextUp(last), nextDown(first)]);
  result.gaps = intervals.length === 0 ? undefined : sortRanges(intervals);
  const anchors = (self.correctionTimes ?? []).filter((a) => a >= start);
  anchors.push(start);
  result.correctionTimes = Array.from(new Set(anchors)).sort((a, b) => a - b);
  const placed = (self.anchors ?? []).filter((a) => a >= start);
  result.anchors = placed.length === 0 ? undefined : placed;
  result.inferred = undefined;
  result.recoveryCount = (self.recoveryCount ?? 0) + (earlier.recoveryCount ?? 0);
  result.jerseyProfile = self.jerseyProfile ?? earlier.jerseyProfile;
  result.identity = earlier.identity ?? self.identity;
  return result;
}

/** A drawing's copy of a track, bound at `time` (its reference box becomes the box at that time). */
export function bound(m: PlayerMotion, time: number, smoothing?: number): PlayerMotion | null {
  const result: PlayerMotion = { ...m, smoothing: smoothing ?? m.smoothing };
  const box = boxAt(result, time);
  if (!box) return null;
  result.referenceBox = box;
  return result;
}

// MARK: - Camera motion (AnnotationCameraMotion.swift)

export function coveredDuration(c: AnnotationCameraMotion): number {
  const last = c.samples[c.samples.length - 1]?.time ?? 0, first = c.samples[0]?.time ?? 0;
  return Math.max(0, Math.min(last, c.lostAt ?? Infinity) - first);
}
export const covers = (c: AnnotationCameraMotion, range: TimeRange) => transformAt(c, range[0]) !== null && transformAt(c, range[1]) !== null;

function rawTransform(c: AnnotationCameraMotion, time: number): CameraTransform | null {
  const samples = c.samples, first = samples[0], last = samples[samples.length - 1];
  if (!first || !last || time < first.time - 0.05 || time > last.time + 0.15) return null;
  if (c.lostAt != null && !(time < c.lostAt)) return null;
  let low = 0, high = samples.length - 1;
  while (low < high) { const mid = (low + high) >> 1; if (samples[mid]!.time < time) low = mid + 1; else high = mid; }
  if (low === 0) return first.transform;
  const a = samples[low - 1]!, b = samples[low]!;
  const fraction = Math.min(1, Math.max(0, (time - a.time) / Math.max(0.001, b.time - a.time)));
  return { values: a.transform.values.map((v, i) => v + ((b.transform.values[i] ?? v) - v) * fraction) };
}

/** Camera pose at `time`, relative to `referenceTime` when one is set. */
export function transformAt(c: AnnotationCameraMotion, time: number): CameraTransform | null {
  const current = rawTransform(c, time);
  if (!current) return null;
  if (c.referenceTime == null) return current;
  const reference = rawTransform(c, c.referenceTime);
  if (!reference || Math.abs(cameraDeterminant(reference)) <= 0.00001) return null;
  const inverse = mat3Inverse(cameraMatrix(reference));
  return inverse ? cameraFromMatrix(mat3Multiply(cameraMatrix(current), inverse)) : null;
}

/** Maps points through the camera at `time`; null unless every point maps. */
export function projectPoints(c: AnnotationCameraMotion, points: readonly Point[], time: number): Point[] | null {
  const transform = transformAt(c, time);
  if (!transform) return null;
  const mapped: Point[] = [];
  for (const p of points) { const q = cameraPoint(transform, p); if (!q) return null; mapped.push(q); }
  return mapped;
}

export const identityTransform = (): CameraTransform => ({ values: IDENTITY_CAMERA_TRANSFORM.values.slice() });

// MARK: - Small array helpers

export function findLast<T>(items: readonly T[], predicate: (item: T) => boolean): T | undefined {
  for (let i = items.length - 1; i >= 0; i--) if (predicate(items[i]!)) return items[i];
  return undefined;
}
export function findLastIndex<T>(items: readonly T[], predicate: (item: T) => boolean): number {
  for (let i = items.length - 1; i >= 0; i--) if (predicate(items[i]!)) return i;
  return -1;
}
