/* Visible white markings on turf: port of FieldLineDetection.swift (Hough segments over marking candidates) and
   GroundReferenceDetection.swift (a single unambiguous convex quad supported by finite segments). Works on RGBA
   `FramePixels`; the WASM kernel replaces the Hough loop when loaded. */
import type { Point } from "@/domain/geometry";
import { cropRegion, type FramePixels } from "../tracking/frame-pixels";
import { visionKernels } from "@/wasm/camelot-vision";

export interface LineSegment { id: number; start: Point; end: Point }

/** Straight white segments with turf on both sides, normalized to the frame. At most 8, longest support first. */
export function detectFieldLines(frame: FramePixels): LineSegment[] {
  const width = Math.min(640, frame.width);
  const height = Math.max(1, Math.floor((frame.height * width) / frame.width));
  const image = width === frame.width ? frame : cropRegion(frame, { x: 0, y: 0, width: 1, height: 1 }, width, height);
  if (width <= 16 || height <= 16) return [];
  const kernels = visionKernels();
  if (kernels) {
    const flat = kernels.houghSegments(image.data, width, height);
    const result: LineSegment[] = [];
    for (let i = 0; i + 3 < flat.length; i += 4) result.push({ id: result.length, start: { x: flat[i]!, y: flat[i + 1]! }, end: { x: flat[i + 2]!, y: flat[i + 3]! } });
    return result;
  }
  const data = image.data;
  const rgb = (x: number, y: number): [number, number, number] => { const i = (y * width + x) * 4; return [data[i]!, data[i + 1]!, data[i + 2]!]; };
  const turf = (x: number, y: number) => {
    if (x < 0 || x >= width || y < 0 || y >= height) return false;
    const [r, g, b] = rgb(x, y);
    return g > 45 && g > r * 0.94 && g > b * 1.35;
  };
  const points: Point[] = [];
  for (let y = 6; y < height - 6; y++) for (let x = 6; x < width - 6; x++) {
    const [r, g, b] = rgb(x, y);
    if (!((r + g + b) / 3 > 100) || !(r > g * 0.72) || !(b > g * 0.53)) continue;
    const neighbours: [number, number][] = [[x - 5, y], [x + 5, y], [x, y - 5], [x, y + 5]];
    const grass = neighbours.filter(([nx, ny]) => turf(nx, ny));
    if (grass.length < 2) continue;
    let total = 0;
    for (const [nx, ny] of grass) { const [nr, ng, nb] = rgb(nx, ny); total += (nr + ng + nb) / 3; }
    if ((r + g + b) / 3 > total / grass.length + 16) points.push({ x, y });
  }
  if (points.length < 30) return [];
  const radius = Math.ceil(Math.hypot(width, height)), bins = radius * 2 + 1;
  const cosines = Array.from({ length: 180 }, (_, a) => Math.cos((a * Math.PI) / 180)), sines = Array.from({ length: 180 }, (_, a) => Math.sin((a * Math.PI) / 180));
  const votes = new Int32Array(180 * bins);
  for (let angle = 0; angle < 180; angle++) {
    const c = cosines[angle]!, s = sines[angle]!;
    for (const point of points) votes[angle * bins + Math.round(point.x * c + point.y * s) + radius]! += 1;
  }
  const peaks: number[] = [];
  for (let i = 0; i < votes.length; i++) if (votes[i]! >= 35) peaks.push(i);
  peaks.sort((a, b) => votes[b]! - votes[a]!);
  const result: LineSegment[] = [];
  for (const peak of peaks.slice(0, 160)) {
    const angle = Math.floor(peak / bins), rho = (peak % bins) - radius;
    const nx = cosines[angle]!, ny = sines[angle]!, dx = -ny, dy = nx;
    const support = points.filter((p) => Math.abs(p.x * nx + p.y * ny - rho) < 1.3).map((p) => p.x * dx + p.y * dy).sort((a, b) => a - b);
    const first = support[0];
    if (first == null) continue;
    const runs: [number, number, number][] = [];
    let start = first, previous = first, count = 0;
    for (const position of support) {
      if (position - previous > 10) { runs.push([start, previous, count]); start = position; count = 0; }
      previous = position; count += 1;
    }
    runs.push([start, previous, count]);
    let stop = false;
    for (const [low, high, n] of runs.sort((a, b) => (b[1] - b[0]) - (a[1] - a[0]))) {
      const length = high - low;
      if (!(length > width * 0.09) || !(n / length > 0.55)) continue;
      const a = { x: nx * rho + dx * low, y: ny * rho + dy * low }, b = { x: nx * rho + dx * high, y: ny * rho + dy * high };
      let turfSamples = 0;
      for (let step = 0; step < 20; step++) {
        const t = low + (length * (step + 0.5)) / 20, x = nx * rho + dx * t, y = ny * rho + dy * t;
        if (turf(Math.trunc(x + nx * 5), Math.trunc(y + ny * 5)) && turf(Math.trunc(x - nx * 5), Math.trunc(y - ny * 5))) turfSamples += 1;
      }
      if (turfSamples < 13) continue;
      const duplicate = result.some((segment) => {
        const px = segment.start.x * width, py = segment.start.y * height, qx = segment.end.x * width, qy = segment.end.y * height;
        const alongNormal = (qx - px) * nx + (qy - py) * ny;
        const parallel = Math.abs(alongNormal) / Math.max(1, Math.hypot(qx - px, qy - py)) < 0.18;
        const pT = px * dx + py * dy, qT = qx * dx + qy * dy;
        const overlapStart = Math.max(low, Math.min(pT, qT)), overlapEnd = Math.min(high, Math.max(pT, qT));
        if (!parallel || !(overlapEnd > overlapStart) || !(Math.abs(qT - pT) > 1)) return false;
        const fraction = ((overlapStart + overlapEnd) / 2 - pT) / (qT - pT);
        const x = px + (qx - px) * fraction, y = py + (qy - py) * fraction;
        return Math.abs(x * nx + y * ny - rho) < 5;
      });
      if (!duplicate) result.push({ id: result.length, start: { x: a.x / width, y: a.y / height }, end: { x: b.x / width, y: b.y / height } });
      if (result.length === 8) { stop = true; break; }
    }
    if (stop) break;
  }
  return result;
}

// MARK: - GroundReferenceDetection

export interface ReferenceProposal { corners: Point[]; intersections: Point[] }

const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
const cross = (a: Point, b: Point) => a.x * b.y - a.y * b.x;
const isFinitePt = (p: Point) => Number.isFinite(p.x) && Number.isFinite(p.y);
const polygonAreaSigned = (points: Point[]) => points.reduce((sum, p, i) => { const q = points[(i + 1) % points.length]!; return sum + p.x * q.y - q.x * p.y; }, 0) / 2;

function segmentIntersection(lhs: LineSegment, rhs: LineSegment): Point | null {
  const r = { x: lhs.end.x - lhs.start.x, y: lhs.end.y - lhs.start.y }, s = { x: rhs.end.x - rhs.start.x, y: rhs.end.y - rhs.start.y };
  const denominator = cross(r, s);
  if (!(Math.abs(denominator) > 0.035 * Math.hypot(r.x, r.y) * Math.hypot(s.x, s.y))) return null;
  const delta = { x: rhs.start.x - lhs.start.x, y: rhs.start.y - lhs.start.y };
  const t = cross(delta, s) / denominator, u = cross(delta, r) / denominator;
  if (t < -0.02 || t > 1.02 || u < -0.02 || u > 1.02) return null;
  return { x: lhs.start.x + t * r.x, y: lhs.start.y + t * r.y };
}

function pointOnSegment(point: Point, segment: LineSegment): boolean {
  const length = distance(segment.start, segment.end);
  const crossDistance = Math.abs(cross({ x: segment.end.x - segment.start.x, y: segment.end.y - segment.start.y }, { x: point.x - segment.start.x, y: point.y - segment.start.y })) / length;
  const dot = (point.x - segment.start.x) * (segment.end.x - segment.start.x) + (point.y - segment.start.y) * (segment.end.y - segment.start.y);
  return crossDistance < 0.012 && dot >= -0.02 * length * length && dot <= length * length * 1.02;
}

function permutations(values: number[]): number[][] {
  return values.length === 1 ? [values] : values.flatMap((v) => permutations(values.filter((o) => o !== v)).map((rest) => [v, ...rest]));
}

function clockwise(points: Point[]): Point[] {
  const ordered = polygonAreaSigned(points) >= 0 ? points : points.slice().reverse();
  let first = 0;
  for (let i = 1; i < ordered.length; i++) {
    const l = ordered[i]!, r = ordered[first]!;
    const ls = l.x + l.y, rs = r.x + r.y;
    if (ls !== rs ? ls < rs : l.y !== r.y ? l.y < r.y : l.x < r.x) first = i;
  }
  return [...ordered.slice(first), ...ordered.slice(0, first)];
}

/** Intersections supported by finite segments and, only for a single unambiguous convex cycle, its corners. */
export function proposeReference(segments: readonly LineSegment[]): ReferenceProposal {
  const usable = segments.slice(0, 8).filter((s) => isFinitePt(s.start) && isFinitePt(s.end) && distance(s.start, s.end) > 0.0001);
  const unique: LineSegment[] = [];
  const same = (a: LineSegment, b: LineSegment) => (distance(a.start, b.start) < 0.012 && distance(a.end, b.end) < 0.012) || (distance(a.start, b.end) < 0.012 && distance(a.end, b.start) < 0.012);
  for (const segment of usable) if (!unique.some((u) => same(u, segment))) unique.push(segment);
  const intersections: Point[] = [];
  for (let i = 0; i < unique.length; i++) for (let j = i + 1; j < unique.length; j++) {
    const point = segmentIntersection(unique[i]!, unique[j]!);
    if (point && !intersections.some((p) => distance(p, point) < 0.012)) intersections.push(point);
  }
  const candidates: Point[][] = [];
  const samePointSet = (lhs: Point[], rhs: Point[]) => lhs.every((p) => rhs.some((q) => distance(p, q) < 0.012));
  if (unique.length >= 4) {
    for (let a = 0; a < unique.length - 3; a++) for (let b = a + 1; b < unique.length - 2; b++) for (let c = b + 1; c < unique.length - 1; c++) for (let d = c + 1; d < unique.length; d++) {
      for (const order of permutations([a, b, c, d])) {
        if (order[0] !== a) continue;
        const sides = order.map((i) => unique[i]!);
        const points: Point[] = [];
        for (let k = 0; k < 4; k++) { const p = segmentIntersection(sides[k]!, sides[(k + 1) % 4]!); if (!p) break; points.push(p); }
        if (points.length !== 4 || !points.every(isFinitePt)) continue;
        let distinct = true;
        for (let i = 0; i < 4 && distinct; i++) for (let j = i + 1; j < 4; j++) if (distance(points[i]!, points[j]!) < 0.012) { distinct = false; break; }
        if (!distinct) continue;
        const supported = points.every((point, index) => { const previous = points[(index + 3) % 4]!, segment = sides[index]!; return distance(point, previous) > 0.03 && pointOnSegment(point, segment) && pointOnSegment(previous, segment); });
        if (!supported) continue;
        const signs = [0, 1, 2, 3].map((i) => { const p = points[i]!, q = points[(i + 1) % 4]!, r = points[(i + 2) % 4]!; return cross({ x: q.x - p.x, y: q.y - p.y }, { x: r.x - q.x, y: r.y - q.y }); });
        if (!(signs.every((s) => s > 0.0001) || signs.every((s) => s < -0.0001))) continue;
        if (!(Math.abs(polygonAreaSigned(points)) > 0.002)) continue;
        if (!candidates.some((existing) => samePointSet(existing, points))) candidates.push(clockwise(points));
      }
    }
  }
  return { corners: candidates.length === 1 ? candidates[0]! : [], intersections };
}

export const detectReference = (frame: FramePixels): ReferenceProposal => proposeReference(detectFieldLines(frame));
