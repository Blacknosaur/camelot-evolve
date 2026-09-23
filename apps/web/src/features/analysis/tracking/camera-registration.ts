/* Camera compensation: port of CameraFeatureRegistration.swift plus the parts of CameraMotionTracking
   (AnnotationCameraMotion.swift) that Vision provided on iOS. Vision's translational/homographic
   registration requests are replaced by a coarse block-matching translation seed; sparse normalized
   patch correspondences with RANSAC consensus verify every proposal, exactly as on iOS. Hot loops may be
   swapped for the WASM kernels in @/wasm when they are available. */
import type { Point } from "@/domain/geometry";
import type { AnnotationCameraMotion, CameraTransform } from "@/domain/tracking";
import { cameraFromMatrix, cameraIsFinite, cameraMatrix, cameraPoint, IDENTITY3, mat3Determinant, mat3Inverse, mat3Multiply, mat3Scale, type Mat3 } from "./geometry";
import { toGray, type FramePixels } from "./frame-pixels";
import { visionKernels } from "@/wasm/camelot-vision";

export interface Match { source: Point; target: Point }

/** Down-scaled luma image with normalized 5×5 (stride 2) patches. */
export class GrayImage {
  constructor(readonly width: number, readonly height: number, readonly values: Float32Array) {}

  static from(frame: FramePixels, maximumWidth = 640): GrayImage {
    const gray = toGray(frame, Math.min(maximumWidth, frame.width));
    return new GrayImage(gray.width, gray.height, gray.values);
  }

  /** Top `fraction` of the image (stands, fences, field edge) for background registration. */
  cropTop(fraction: number): GrayImage {
    const height = Math.max(2, Math.floor(this.height * fraction));
    return new GrayImage(this.width, height, this.values.subarray(0, this.width * height));
  }

  patch(x: number, y: number): Float32Array | null {
    if (x < 5 || y < 5 || x >= this.width - 5 || y >= this.height - 5) return null;
    const patch = new Float32Array(25);
    let index = 0, mean = 0;
    for (let dy = -4; dy <= 4; dy += 2) for (let dx = -4; dx <= 4; dx += 2) { const v = this.values[(y + dy) * this.width + x + dx]!; patch[index++] = v; mean += v; }
    mean /= 25;
    let norm = 0;
    for (let i = 0; i < 25; i++) { patch[i]! -= mean; norm += patch[i]! * patch[i]!; }
    norm = Math.sqrt(norm);
    if (norm <= 0.14) return null;
    for (let i = 0; i < 25; i++) patch[i]! /= norm;
    return patch;
  }

  /** Harris-style corners with equal spatial quotas (8×6 cells, 3 per cell), skipping the very bottom. */
  corners(): Point[] {
    const kernels = visionKernels();
    if (kernels) {
      const flat = kernels.corners(this.values, this.width, this.height);
      const result: Point[] = [];
      for (let i = 0; i + 1 < flat.length; i += 2) result.push({ x: flat[i]!, y: flat[i + 1]! });
      return result;
    }
    const result: Point[] = [], { width, height, values } = this;
    for (let row = 0; row < 6; row++) for (let column = 0; column < 8; column++) {
      const candidates: [number, number, number][] = [];
      const minX = Math.max(8, Math.floor((column * width) / 8)), maxX = Math.min(width - 8, Math.floor(((column + 1) * width) / 8));
      const minY = Math.max(8, Math.floor((row * height * 9) / 60)), maxY = Math.min(height - 8, Math.floor(((row + 1) * height * 9) / 60));
      for (let y = minY; y < maxY; y += 3) for (let x = minX; x < maxX; x += 3) {
        let xx = 0, yy = 0, xy = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
          const i = (y + dy) * width + x + dx;
          const gx = values[i + 1]! - values[i - 1]!, gy = values[i + width]! - values[i - width]!;
          xx += gx * gx; yy += gy * gy; xy += gx * gy;
        }
        const strength = (xx + yy - Math.sqrt((xx - yy) * (xx - yy) + 4 * xy * xy)) / 2;
        if (strength > 0.012) candidates.push([strength, x, y]);
      }
      candidates.sort((a, b) => b[0] - a[0]);
      const chosen: Point[] = [];
      for (const [, x, y] of candidates) {
        if (chosen.every((p) => Math.hypot(p.x - x, p.y - y) > 16)) { chosen.push({ x, y }); if (chosen.length === 3) break; }
      }
      result.push(...chosen);
    }
    return result;
  }

  /** Normalized cross-correlation search around `near`; coarse stride 2 then a 3×3 refinement and sub-pixel offset. */
  locate(patch: Float32Array, near: Point, radius: number): { point: Point; score: number } | null {
    const cx = Math.round(near.x), cy = Math.round(near.y);
    if (!(cx > -radius && cy > -radius && cx < this.width + radius && cy < this.height + radius)) return null;
    const { width, values } = this;
    const score = (x: number, y: number): number => {
      if (x < 5 || y < 5 || x >= width - 5 || y >= this.height - 5) return -1;
      let sum = 0, squares = 0, product = 0, index = 0;
      for (let dy = -4; dy <= 4; dy += 2) for (let dx = -4; dx <= 4; dx += 2) {
        const value = values[(y + dy) * width + x + dx]!;
        sum += value; squares += value * value; product += patch[index++]! * value;
      }
      const variance = squares - (sum * sum) / 25;
      return variance > 0.0196 ? product / Math.sqrt(variance) : -1;
    };
    let best: [number, number, number] = [cx, cy, -1];
    const scores: [number, number, number][] = [];
    for (let y = cy - radius; y <= cy + radius; y += 2) for (let x = cx - radius; x <= cx + radius; x += 2) {
      const value = score(x, y); scores.push([x, y, value]);
      if (value > best[2]) best = [x, y, value];
    }
    const coarse = best;
    for (let y = coarse[1] - 1; y <= coarse[1] + 1; y++) for (let x = coarse[0] - 1; x <= coarse[0] + 1; x++) { const value = score(x, y); if (value > best[2]) best = [x, y, value]; }
    let other = -1;
    for (const s of scores) if (Math.hypot(s[0] - best[0], s[1] - best[1]) > 4 && s[2] > other) other = s[2];
    if (!(best[2] > 0.84) || !(best[2] - other > 0.035)) return null;
    const offset = (left: number, right: number) => {
      if (best[2] > 0.9999) return 0;
      const denominator = left - 2 * best[2] + right;
      if (!(denominator < -0.0001)) return 0;
      return Math.min(0.5, Math.max(-0.5, (left - right) / (2 * denominator)));
    };
    return { point: { x: best[0] + offset(score(best[0] - 1, best[1]), score(best[0] + 1, best[1])), y: best[1] + offset(score(best[0], best[1] - 1), score(best[0], best[1] + 1)) }, score: best[2] };
  }
}

const grayCache = new WeakMap<FramePixels, GrayImage>();
/** 640-wide luma of a frame, computed once per FramePixels instance. */
export function grayFor(frame: FramePixels): GrayImage {
  let gray = grayCache.get(frame);
  if (!gray) { gray = GrayImage.from(frame); grayCache.set(frame, gray); }
  return gray;
}

/** One decoded frame owned by a camera pass; features are computed lazily and reused while it is the anchor. */
export class RegistrationFrame {
  private cachedFeatures: { point: Point; patch: Float32Array }[] | null = null;
  constructor(readonly gray: GrayImage, readonly time: number) {}
  static from(frame: FramePixels): RegistrationFrame { return new RegistrationFrame(grayFor(frame), frame.time); }
  get features() {
    this.cachedFeatures ??= this.gray.corners().flatMap((point) => { const patch = this.gray.patch(point.x, point.y); return patch ? [{ point, patch }] : []; });
    return this.cachedFeatures;
  }
}

/** Sparse correspondences seeded by `initial`, verified both ways, fitted by consensus. */
export function registerFeatures(previous: RegistrationFrame, current: RegistrationFrame, initial: CameraTransform): CameraTransform | null {
  const a = previous.gray, b = current.gray;
  if (a.width !== b.width || a.height !== b.height) return null;
  const matches: Match[] = [];
  for (const { point, patch } of previous.features) {
    const source = { x: point.x / a.width, y: point.y / a.height };
    const guess = cameraPoint(initial, source);
    if (!guess) continue;
    const target = b.locate(patch, { x: guess.x * b.width, y: guess.y * b.height }, 12);
    if (!target) continue;
    const backPatch = b.patch(Math.round(target.point.x), Math.round(target.point.y));
    if (!backPatch) continue;
    const back = a.locate(backPatch, point, 4);
    if (!back || Math.hypot(back.point.x - point.x, back.point.y - point.y) >= 1.5) continue;
    matches.push({ source, target: { x: target.point.x / b.width, y: target.point.y / b.height } });
  }
  return consensus(matches, a.width, a.height);
}

export function consensus(matches: readonly Match[], width: number, height: number): CameraTransform | null {
  if (matches.length < 12) return null;
  const residual = (t: CameraTransform, m: Match) => { const p = cameraPoint(t, m.source); return p ? Math.hypot((p.x - m.target.x) * width, (p.y - m.target.y) * height) : Infinity; };
  let best: Match[] = [], bestError = Infinity;
  let random = 0x43414d455241n;
  for (let iteration = 0; iteration < 160; iteration++) {
    const indices = new Set<number>();
    while (indices.size < 4) { random = (random * 6364136223846793005n + 1n) & 0xffffffffffffffffn; indices.add(Number((random >> 32n) % BigInt(matches.length))); }
    const candidate = fitHomography([...indices].sort((x, y) => x - y).map((i) => matches[i]!));
    if (!candidate) continue;
    const inliers = matches.filter((m) => residual(candidate, m) < 1.6);
    const error = inliers.reduce((sum, m) => sum + residual(candidate, m), 0);
    if (inliers.length > best.length || (inliers.length === best.length && error < bestError)) { best = inliers; bestError = error; }
  }
  if (best.length < 12 || best.length < matches.length / 2) return null;
  const xs = best.map((m) => m.source.x), ys = best.map((m) => m.source.y);
  if (!(Math.max(...xs) - Math.min(...xs) > 0.3) || !(Math.max(...ys) - Math.min(...ys) > 0.12)) return null;
  const cells = new Set(best.map((m) => Math.floor(m.source.x * 4) + 4 * Math.floor(m.source.y * 4)));
  if (cells.size < 5) return null;
  const fitted = fitHomography(best);
  return fitted && plausibleCamera(fitted) ? fitted : null;
}

const RECTANGLE: Point[] = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];

export function plausibleCamera(transform: CameraTransform): boolean {
  const matrix = cameraMatrix(transform), det = mat3Determinant(matrix);
  if (!cameraIsFinite(transform) || !(det > 0.35) || !(det < 3)) return false;
  return RECTANGLE.every((point) => {
    const z = matrix[6] * point.x + matrix[7] * point.y + matrix[8];
    const moved = cameraPoint(transform, point);
    return z > 0.2 && moved != null && Math.hypot(moved.x - point.x, moved.y - point.y) < 0.65;
  });
}

/** Small normalized least-squares homography (h33 = 1) with pivoting. */
export function fitHomography(matches: readonly Match[]): CameraTransform | null {
  const system: number[][] = Array.from({ length: 8 }, () => new Array<number>(9).fill(0));
  for (const m of matches) {
    const x = m.source.x, y = m.source.y, u = m.target.x, v = m.target.y;
    for (const [row, value] of [[[x, y, 1, 0, 0, 0, -u * x, -u * y], u], [[0, 0, 0, x, y, 1, -v * x, -v * y], v]] as [number[], number][]) {
      for (let i = 0; i < 8; i++) { for (let j = 0; j < 8; j++) system[i]![j]! += row[i]! * row[j]!; system[i]![8]! += row[i]! * value; }
    }
  }
  const solved = solveNormalEquations(system, 1e-10, false);
  return solved ? { values: [...solved, 1] } : null;
}

/** Gauss-Jordan elimination of an 8×9 augmented system; `relative` scales the pivot threshold by the largest coefficient. */
export function solveNormalEquations(system: number[][], threshold: number, relative: boolean): number[] | null {
  const matrix = system.map((row) => row.slice());
  const scale = relative ? Math.max(...matrix.flatMap((row) => row.slice(0, 8).map(Math.abs))) || 1 : 1;
  for (let column = 0; column < 8; column++) {
    let pivot = column;
    for (let r = column + 1; r < 8; r++) if (Math.abs(matrix[r]![column]!) > Math.abs(matrix[pivot]![column]!)) pivot = r;
    if (!(Math.abs(matrix[pivot]![column]!) > threshold * scale)) return null;
    [matrix[column], matrix[pivot]] = [matrix[pivot]!, matrix[column]!];
    const divisor = matrix[column]![column]!;
    for (let j = column; j <= 8; j++) matrix[column]![j]! /= divisor;
    for (let r = 0; r < 8; r++) {
      if (r === column) continue;
      const factor = matrix[r]![column]!;
      if (factor === 0) continue;
      for (let j = column; j <= 8; j++) matrix[r]![j]! -= factor * matrix[column]![j]!;
    }
  }
  const result = matrix.map((row) => row[8]!);
  return result.every(Number.isFinite) ? result : null;
}

// MARK: - Translation seed (replaces VNTranslationalImageRegistrationRequest)

/** Coarse-to-fine block matching of the whole image; returns the shift of `previous` content in `current`, in pixels. */
export function estimateTranslation(previous: GrayImage, current: GrayImage, maximumFraction = 0.35): Point | null {
  if (previous.width !== current.width || previous.height !== current.height) return null;
  const kernels = visionKernels();
  if (kernels) {
    const result = kernels.translation(previous.values, current.values, previous.width, previous.height, maximumFraction);
    return result ? { x: result[0]!, y: result[1]! } : null;
  }
  const step = Math.max(1, Math.floor(previous.width / 80));
  const sad = (dx: number, dy: number) => {
    let sum = 0, count = 0;
    for (let y = 8; y < previous.height - 8; y += step) for (let x = 8; x < previous.width - 8; x += step) {
      const tx = x + dx, ty = y + dy;
      if (tx < 0 || ty < 0 || tx >= current.width || ty >= current.height) continue;
      sum += Math.abs(previous.values[y * previous.width + x]! - current.values[ty * current.width + tx]!); count++;
    }
    return count > 0 ? sum / count : Infinity;
  };
  const radiusX = Math.floor(previous.width * maximumFraction), radiusY = Math.floor(previous.height * maximumFraction);
  let best: [number, number, number] = [0, 0, sad(0, 0)];
  const coarse = Math.max(1, Math.floor(previous.width / 80));
  for (let dy = -radiusY; dy <= radiusY; dy += coarse * 2) for (let dx = -radiusX; dx <= radiusX; dx += coarse * 2) {
    const value = sad(dx, dy); if (value < best[2]) best = [dx, dy, value];
  }
  for (let refine = coarse; refine >= 1; refine = Math.floor(refine / 2)) {
    const centre = best;
    for (let dy = centre[1] - refine * 2; dy <= centre[1] + refine * 2; dy += refine) for (let dx = centre[0] - refine * 2; dx <= centre[0] + refine * 2; dx += refine) {
      const value = sad(dx, dy); if (value < best[2]) best = [dx, dy, value];
    }
    if (refine === 1) break;
  }
  if (!Number.isFinite(best[2])) return null;
  return { x: best[0], y: best[1] };
}

/** Textured image locations must agree after the warp; matrix shape alone is not trusted. */
export function imagesAgree(previous: GrayImage, current: GrayImage, transform: CameraTransform): boolean {
  const width = 160, height = 90;
  const sample = (image: GrayImage, x: number, y: number) => {
    const sx = Math.min(image.width - 1, Math.floor(((x + 0.5) / width) * image.width)), sy = Math.min(image.height - 1, Math.floor(((y + 0.5) / height) * image.height));
    return image.values[sy * image.width + sx]!;
  };
  let checked = 0, agreeing = 0;
  for (let y = 2; y < height - 2; y += 2) for (let x = 2; x < width - 2; x += 2) {
    const reference = sample(previous, x, y);
    const horizontal = Math.abs(reference - sample(previous, x + 1, y)), vertical = Math.abs(reference - sample(previous, x, y + 1));
    if (!(Math.max(horizontal, vertical) > 0.055) || !(reference > 0.15)) continue;
    const point = cameraPoint(transform, { x: (x + 0.5) / width, y: (y + 0.5) / height });
    if (!point) continue;
    const targetX = Math.floor(point.x * width), targetY = Math.floor(point.y * height);
    if (targetX < 1 || targetY < 1 || targetX >= width - 1 || targetY >= height - 1) continue;
    let difference = 1;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) difference = Math.min(difference, Math.abs(reference - sample(current, targetX + dx, targetY + dy)));
    checked++;
    if (difference < 0.12) agreeing++;
  }
  return checked >= 20 && agreeing / checked >= 0.7;
}

/** Editing camera pass: translation seed, then independently verified sparse scene matches. */
export function registerScene(previous: RegistrationFrame, current: RegistrationFrame): CameraTransform | null {
  if (previous.gray.width !== current.gray.width || previous.gray.height !== current.gray.height) return null;
  const translation = estimateTranslation(previous.gray, current.gray);
  if (!translation) return null;
  const initial: CameraTransform = { values: [1, 0, translation.x / current.gray.width, 0, 1, translation.y / current.gray.height, 0, 0, 1] };
  const refined = registerFeatures(previous, current, initial);
  if (refined) return refined;
  // Translation is only a search initializer; retry from identity for roll/zoom the seed missed.
  const fallback = registerFeatures(previous, current, { values: IDENTITY3.slice() });
  return fallback && plausibleCamera(fallback) ? fallback : null;
}

/** Lightweight recovery warp preferring the upper scene (stands, field edge) over moving players. */
export function registerBackground(previous: FramePixels, current: FramePixels): CameraTransform | null {
  const fraction = 0.62;
  const fullPrevious = grayFor(previous);
  const a = fullPrevious.cropTop(fraction), b = grayFor(current).cropTop(fraction);
  if (a.width !== b.width || a.height !== b.height) return null;
  const translation = estimateTranslation(a, b, 0.6);
  if (!translation || Math.abs(translation.x) >= a.width * 0.6 || Math.abs(translation.y) >= a.height * 0.6) return null;
  const translated: CameraTransform = { values: [1, 0, translation.x / a.width, 0, 1, translation.y / a.height, 0, 0, 1] };
  if (!imagesAgree(a, b, translated)) return null;
  let cropped = translated;
  const projective = registerFeatures(new RegistrationFrame(a, previous.time), new RegistrationFrame(b, current.time), translated);
  if (projective) {
    const centre = cameraPoint(projective, { x: 0.5, y: 0.5 }), shifted = cameraPoint(translated, { x: 0.5, y: 0.5 });
    if (centre && shifted && Math.hypot(centre.x - shifted.x, centre.y - shifted.y) < 0.003 && imagesAgree(a, b, projective)) cropped = projective;
  }
  const scale: Mat3 = [1, 0, 0, 0, a.height / fullPrevious.height, 0, 0, 0, 1];
  const inverse = mat3Inverse(scale);
  if (!inverse) return null;
  return cameraFromMatrix(mat3Multiply(mat3Multiply(scale, cameraMatrix(cropped)), inverse));
}

// MARK: - Whole-range camera pass (CameraMotionTracking.track)

export interface CameraFrameInput { pixels: FramePixels; time: number; duration: number; isLast: boolean }

/** Integrates per-frame scene registration into absolute poses, re-anchoring every second to limit drift. */
export async function trackCameraMotion(frames: AsyncIterable<CameraFrameInput>, start: number, end: number, fallbackFrameDuration: number,
  progress: (fraction: number) => void, signal?: AbortSignal): Promise<AnnotationCameraMotion> {
  let previous: RegistrationFrame | null = null, anchor: RegistrationFrame | null = null;
  let anchorTime = start, anchorTransform: Mat3 = IDENTITY3, accumulated: Mat3 = IDENTITY3;
  let lastTime = start - 1, lastFrameEnd = start;
  const motion: AnnotationCameraMotion = { samples: [{ time: start, transform: { values: IDENTITY3.slice() } }] };
  let sawFrame = false;
  for await (const frame of frames) {
    if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
    const time = frame.time;
    const frameEnd = time + (Number.isFinite(frame.duration) && frame.duration > 0 ? frame.duration : fallbackFrameDuration);
    if (!(time - lastTime >= 0.045 || frame.isLast || frameEnd >= end - 1 / 600)) continue;
    const current = RegistrationFrame.from(frame.pixels);
    if (previous) {
      const direct = anchor ? registerScene(anchor, current) : null;
      if (direct) accumulated = mat3Multiply(cameraMatrix(direct), anchorTransform);
      else {
        const step = registerScene(previous, current);
        if (!step) { motion.lostAt = time; break; }
        accumulated = mat3Multiply(cameraMatrix(step), accumulated);
        anchor = current; anchorTransform = accumulated; anchorTime = time;
      }
      if (!(Math.abs(accumulated[8]) > 0.00001)) { motion.lostAt = time; break; }
      accumulated = mat3Scale(accumulated, 1 / accumulated[8]);
      motion.samples.push({ time, transform: cameraFromMatrix(accumulated) });
    }
    if (!anchor || time - anchorTime >= 1) { anchor = current; anchorTransform = accumulated; anchorTime = time; }
    previous = current; lastTime = time; lastFrameEnd = frameEnd; sawFrame = true;
    progress(Math.min(1, (time - start) / Math.max(0.01, end - start)));
  }
  const last = motion.samples[motion.samples.length - 1];
  if (motion.lostAt == null && last && sawFrame && end - lastFrameEnd <= Math.max(0.05, fallbackFrameDuration * 1.5) && last.time < end) {
    motion.samples.push({ time: end, transform: last.transform });
  }
  progress(1);
  return motion;
}
