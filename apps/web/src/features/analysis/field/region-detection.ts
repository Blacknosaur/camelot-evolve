/* Field proposals for "Detect field": port of PitchRegionDetection.swift without its bundled CoreML segmentation
   model (there is no browser equivalent shipped). Proposals come from painted-line geometry instead: the turf mask
   bounds the search, `detectFieldLines` finds straight markings, `proposeReference` yields an unambiguous quad and
   every proposal is snapped to the paint and ranked exactly like iOS. The user always reviews the overlay. */
import type { Point } from "@/domain/geometry";
import type { GroundCalibration, GroundCircleReference, GroundLandmark } from "@/domain/ground";
import { GROUND_LANDMARK_INFO } from "@/domain/ground";
import type { FramePixels } from "../tracking/frame-pixels";
import { calibrationCorners } from "./overlay";
import { fitCircleReference, circleAnchors } from "./circle";
import { detectFieldLines, proposeReference, type LineSegment } from "./line-detection";
import { fieldProjection } from "./projection";
import { MarkingEvidence, qualityGrade, snapCalibration, type SnapResult } from "./registration";

export interface FieldProposal {
  landmark: GroundLandmark;
  corners: Point[];
  circle?: GroundCircleReference;
  /** The proposal snapped to painted markings, when that succeeded. */
  registration?: SnapResult;
}

/** Snapped grade first, then evidence coverage; a refined circle beats an unsnapped area proposal. */
export function proposalScore(p: FieldProposal): number {
  const quality = p.registration?.quality;
  if (!quality) return p.circle ? 0.5 : 0;
  const base = { good: 3, check: 2, poor: 1 }[qualityGrade(quality)];
  return base + Math.min(0.9, quality.coverage);
}

/** Proposals ordered best first. `sourceWidth/Height` are the display size for source-pixel residuals. */
export function detectFieldProposals(frame: FramePixels, pitchLength = 105, pitchWidth = 68, sourceWidth = frame.width, sourceHeight = frame.height): FieldProposal[] {
  const markings = detectFieldLines(frame);
  const proposals: FieldProposal[] = [];
  const quad = proposeReference(markings);
  if (quad.corners.length === 4 && fieldProjection(quad.corners)) {
    // A single closed rectangle of paint is most often a penalty or goal area; offer both orientations of scale and let snapping rank them.
    for (const landmark of ["penaltyArea", "goalArea"] as GroundLandmark[]) proposals.push({ landmark, corners: orientCorners(quad.corners) });
  }
  const circle = circleProposal(frame, markings);
  if (circle) proposals.push(circle);
  const evidence = proposals.length ? MarkingEvidence.fromFrame(frame, sourceWidth, sourceHeight) : null;
  if (!evidence) return proposals;
  for (const proposal of proposals) {
    const info = GROUND_LANDMARK_INFO[proposal.landmark];
    const draft: GroundCalibration = {
      mode: "plane", points: proposal.corners, lengthMeters: info.defaultLengthMeters, widthMeters: info.defaultWidthMeters, referenceTime: 0,
      imageAspectRatio: frame.width / Math.max(1, frame.height), fixedCamera: false, fieldReference: { landmark: proposal.landmark, pitchLength, pitchWidth },
    };
    proposal.registration = snapCalibration(draft, evidence) ?? undefined;
  }
  return proposals.sort((a, b) => proposalScore(b) - proposalScore(a));
}

/** Goal line first (the side nearer the frame edge the region leans to), clockwise, far corner first. */
function orientCorners(corners: Point[]): Point[] {
  const meanX = corners.reduce((a, p) => a + p.x, 0) / corners.length;
  const right = meanX > 0.5;
  let goal = 0, best = -Infinity;
  for (let i = 0; i < 4; i++) {
    const value = (corners[i]!.x + corners[(i + 1) % 4]!.x) * (right ? 1 : -1);
    if (value > best) { best = value; goal = i; }
  }
  const next = (goal + 1) % 4;
  return corners[goal]!.y < corners[next]!.y ? [0, 1, 2, 3].map((k) => corners[(goal + k) % 4]!) : [0, 1, 2, 3].map((k) => corners[(next - k + 4) % 4]!);
}

/** Centre-circle proposal from a long near-vertical marking (the halfway line) and a conic fitted to white samples around it. */
function circleProposal(frame: FramePixels, markings: LineSegment[]): FieldProposal | null {
  const halfway = markings.filter((s) => Math.abs(s.end.y - s.start.y) > Math.abs(s.end.x - s.start.x) * 0.5)
    .sort((a, b) => Math.hypot(b.end.x - b.start.x, b.end.y - b.start.y) - Math.hypot(a.end.x - a.start.x, a.end.y - a.start.y))[0];
  if (!halfway) return null;
  const mid = { x: (halfway.start.x + halfway.end.x) / 2, y: (halfway.start.y + halfway.end.y) / 2 };
  const direction = { x: halfway.end.x - halfway.start.x, y: halfway.end.y - halfway.start.y };
  if (direction.y < 0) { direction.x *= -1; direction.y *= -1; }
  const outline = refinedCircleOutline(frame, mid, direction);
  if (outline.length < 130) return null;
  const size = { width: frame.width, height: frame.height };
  const circle = fitCircleReference(outline, [{ x: mid.x - direction.x / 2, y: mid.y - direction.y / 2 }, { x: mid.x + direction.x / 2, y: mid.y + direction.y / 2 }], size);
  const anchors = circle ? circleAnchors(circle) : null;
  if (!circle || !anchors) return null;
  const corners = calibrationCorners(anchors, "centreCircle");
  return corners.length === 4 ? { landmark: "centreCircle", corners, circle } : null;
}

/** Radial search for painted samples around a seed centre, several radii wide, players excluded as outliers by the conic fit. */
function refinedCircleOutline(frame: FramePixels, center: Point, halfway: Point): Point[] {
  const { width, height, data } = frame;
  const whiteness = (x: number, y: number) => {
    const ix = Math.round(x), iy = Math.round(y);
    if (ix < 0 || ix >= width || iy < 0 || iy >= height) return 0;
    const i = (iy * width + ix) * 4, r = data[i]!, g = data[i + 1]!, b = data[i + 2]!;
    if (!(r > g * 0.8) || !(b > g * 0.65)) return 0;
    return Math.max(0, Math.min(r, g, b) - 0.5 * Math.max(r, g, b));
  };
  const cx = center.x * width, cy = center.y * height;
  // Without a segmentation seed the radius is unknown: try radii relative to the halfway line length and keep the best-supported one.
  const halfLength = Math.hypot(halfway.x * width, halfway.y * height) / 2;
  let best: Point[] = [];
  for (const fraction of [0.35, 0.5, 0.7]) {
    const radiusX = halfLength * fraction, radiusY = halfLength * fraction * 0.45;
    const result: Point[] = [];
    for (let index = 0; index < 180; index++) {
      const angle = (index * 2 * Math.PI) / 180;
      const dx = radiusX * Math.cos(angle), dy = radiusY * Math.sin(angle), radius = Math.hypot(dx, dy);
      if (radius <= 8) continue;
      const ux = dx / radius, uy = dy / radius, px = cx + dx, py = cy + dy;
      const window = Math.min(60, Math.max(12, Math.floor(radius * 0.18)));
      let found: { score: number; point: Point } | null = null;
      for (let offset = -window; offset <= window; offset++) {
        const x = px + offset * ux, y = py + offset * uy, value = whiteness(x, y);
        const background = (whiteness(x - 5 * ux, y - 5 * uy) + whiteness(x + 5 * ux, y + 5 * uy)) / 2;
        const score = value - background - Math.abs(offset) * 0.12;
        if (value > 25 && score > 12 && score > (found?.score ?? 0)) found = { score, point: { x: x / width, y: y / height } };
      }
      if (found) result.push(found.point);
    }
    if (result.length > best.length) best = result;
  }
  return best.length >= 130 ? best : [];
}

export interface ReferenceFrame { time: number; proposal: FieldProposal }

/** Bounded search over candidate times: the preferred frame, then clip-wide candidates. Stops at the first good snap. */
export async function findReferenceFrame(frameAt: (time: number) => Promise<FramePixels | null>, range: [number, number], preferred: number,
  pitchLength = 105, pitchWidth = 68, sourceWidth?: number, sourceHeight?: number, signal?: AbortSignal): Promise<ReferenceFrame | null> {
  const span = range[1] - range[0], third = range[0] + span / 3;
  const candidates = [preferred, third, Math.max(range[0], third - Math.min(1, span / 12)), range[0] + (span * 2) / 3];
  let fallback: ReferenceFrame | null = null;
  for (const time of candidates) {
    if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
    const frame = await frameAt(time);
    if (!frame) continue;
    const best = detectFieldProposals(frame, pitchLength, pitchWidth, sourceWidth ?? frame.width, sourceHeight ?? frame.height)[0];
    if (!best) continue;
    const candidate = { time, proposal: best };
    if (best.registration && qualityGrade(best.registration.quality) === "good") return candidate;
    if (!fallback || proposalScore(candidate.proposal) > proposalScore(fallback.proposal)) fallback = candidate;
  }
  return fallback;
}
