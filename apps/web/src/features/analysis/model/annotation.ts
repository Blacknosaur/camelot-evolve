import type { Point, Rect, Size } from "@/domain/geometry";
import { rectMaxX, rectMaxY, rectMidX, rectMidY } from "@/domain/geometry";
import type { AnalysisAnnotation, AnalysisDrawingTool, AnnotationKeyframe } from "@/domain/annotation";
import { supportsGrounding, isGrounded } from "@/domain/annotation";
import type { GroundCalibration } from "@/domain/ground";
import type { PlayerMotion, TimeRange } from "@/domain/tracking";
import { newId } from "@/domain/ids";
import { CONNECTION_LINE_STYLE, DEFAULT_LINE_STYLE, LEGACY_ARROW_STYLE, textStyle, type AnnotationLineStyle, type AnnotationTextStyle } from "@/domain/annotation-styles";
import { boxAt, effectBodyBox, groundPoint, projectPoints, referenceBox, transformAt } from "@/features/analysis/tracking/motion";
import { cameraMatrix, mat3Inverse, mat3Point } from "@/features/analysis/tracking/geometry";
import { frozenGround, hasPlane, imagePoint, worldPoint } from "./ground";

/* Pure port of AnalysisAnnotation.swift, AnalysisLayerEditing.swift, AnnotationShapeEditing.swift and
   GroundShapeGeometry.swift. Data in, data out: the export worker, tests and the canvas renderer share it.
   Motion sampling (`boxAt`, `groundPoint`, camera transforms) comes from the vision agent's tracking module. */

export type AnnotationMotionMode = "still" | "keyframes" | "player" | "camera";
export const motionModeTitle = (mode: AnnotationMotionMode) => ({ still: "Static", keyframes: "Keyframes", player: "Follow player", camera: "Follow camera" })[mode];

const isPlayerTool = (tool: AnalysisDrawingTool) => tool === "player" || tool === "spotlight";
export const EPSILON_FRAME = 1 / 60;

/** Labels follow smoothed body translation by default (port of `displayPlayerMotion`). */
export function displayPlayerMotion(a: AnalysisAnnotation): PlayerMotion | null {
  if (!a.playerMotion) return null;
  if (a.tool === "text" && a.playerMotion.smoothing == null) return { ...a.playerMotion, smoothing: 0.95 };
  return a.playerMotion;
}

/** Port of `points(at:)`: geometry at `time` after camera, linked-player, player or keyframe motion. */
export function pointsAt(a: AnalysisAnnotation, time: number): Point[] {
  if (a.cameraMotion) { const projected = projectPoints(a.cameraMotion, a.points, time); if (projected) return projected; }
  if (a.linkedPlayers && a.linkedPlayers.length === a.points.length) {
    return a.points.map((point, i) => {
      const motion = a.linkedPlayers![i]!, reference = referenceBox(motion), box = boxAt(motion, time);
      if (!reference || !box) return point;
      return { x: rectMidX(box) + point.x - rectMidX(reference), y: rectMaxY(box) + point.y - rectMaxY(reference) };
    });
  }
  const motion = displayPlayerMotion(a);
  const reference = motion ? referenceBox(motion) : undefined;
  const box = motion ? boxAt(motion, time) : null;
  if (motion && reference && box) {
    if (isPlayerTool(a.tool)) {
      const body = effectBodyBox(motion, time), feet = groundPoint(motion, time);
      if (!body || !feet) return [];
      return a.points.map((p) => ({ x: feet.x + (p.x - rectMidX(reference)) * body.width / Math.max(0.001, reference.width), y: feet.y + (p.y - rectMaxY(reference)) * body.height / Math.max(0.001, reference.height) }));
    }
    if (a.tool === "text" || a.tool === "loupe") return a.points.map((p) => ({ x: p.x + rectMidX(box) - rectMidX(reference), y: p.y + rectMidY(box) - rectMidY(reference) }));
    const sx = box.width / Math.max(0.001, reference.width), sy = box.height / Math.max(0.001, reference.height);
    return a.points.map((p) => ({ x: rectMidX(box) + (p.x - rectMidX(reference)) * sx, y: rectMaxY(box) + (p.y - rectMaxY(reference)) * sy }));
  }
  const first = a.keyframes[0];
  if (!first) return a.points;
  if (time <= first.time) return first.points;
  const next = a.keyframes.findIndex((k) => k.time > time);
  if (next < 0) return a.keyframes[a.keyframes.length - 1]?.points ?? a.points;
  const k0 = a.keyframes[next - 1]!, k1 = a.keyframes[next]!;
  if (k0.points.length !== k1.points.length) return k0.points;
  const fraction = (time - k0.time) / Math.max(0.001, k1.time - k0.time);
  return k0.points.map((p, i) => ({ x: p.x + (k1.points[i]!.x - p.x) * fraction, y: p.y + (k1.points[i]!.y - p.y) * fraction }));
}

/** Port of `setKeyframe(at:points:)`: replaces a keyframe within a frame, otherwise inserts sorted. */
export function setKeyframe(a: AnalysisAnnotation, time: number, points: Point[]): AnalysisAnnotation {
  const index = a.keyframes.findIndex((k) => Math.abs(k.time - time) < EPSILON_FRAME);
  if (index >= 0) return { ...a, keyframes: a.keyframes.map((k, i) => (i === index ? { ...k, points } : k)) };
  const keyframe: AnnotationKeyframe = { id: newId(), time, points };
  return { ...a, keyframes: [...a.keyframes, keyframe].sort((x, y) => x.time - y.time) };
}

/** Port of `hasMotion(at:)`. */
export function hasMotion(a: AnalysisAnnotation, time: number): boolean {
  if (a.linkedPlayers) {
    if (a.tool === "connection") {
      if (a.linkedPlayers.length !== a.points.length || renderedPoints(a, time).length < 2) return false;
    } else if (a.linkedPlayers.some((m) => boxAt(m, time) === null)) return false;
  }
  if (a.cameraMotion && transformAt(a.cameraMotion, time) === null) return false;
  return !a.playerMotion || boxAt(a.playerMotion, time) !== null;
}

/** Port of `opacity(at:)`: 0 when hidden/out of range, else the fade ramp. */
export function opacityAt(a: AnalysisAnnotation, time: number): number {
  if (a.isHidden === true || time < a.start || time >= a.end) return 0;
  if (!hasMotion(a, time)) return 0;
  if (a.playerMotion && boxAt(a.playerMotion, time) === null) return 0;
  if (!a.fade) return 1;
  const ramp = Math.min(0.18, (a.end - a.start) / 4);
  return Math.min(1, Math.min((time - a.start) / ramp, (a.end - time) / ramp));
}

/** Exact seeks round to the source timebase; keep the drawing visible a fraction of a frame early/late. */
export const isActiveInEditor = (a: AnalysisAnnotation, time: number) => time >= a.start - 1 / 600 && time <= a.end + 1 / 600 && hasMotion(a, time);

/** Port of `renderedPoints(at:)`: connections only render confirmed players, in their original order. */
export function renderedPoints(a: AnalysisAnnotation, time: number): Point[] {
  if (a.tool !== "connection" || !a.linkedPlayers || a.linkedPlayers.length !== a.points.length) return pointsAt(a, time);
  const out: Point[] = [];
  a.points.forEach((point, i) => {
    const motion = a.linkedPlayers![i]!, reference = referenceBox(motion), feet = groundPoint(motion, time);
    if (!reference || !feet) return;
    out.push({ x: feet.x + point.x - rectMidX(reference), y: feet.y + point.y - rectMaxY(reference) });
  });
  return out;
}

export const motionMode = (a: AnalysisAnnotation): AnnotationMotionMode =>
  a.cameraMotion ? "camera" : a.playerMotion || a.linkedPlayers ? "player" : a.keyframes.length === 0 ? "still" : "keyframes";

export type AnnotationTimelineEdit =
  | { kind: "move"; delta: number }
  | { kind: "trimStart"; value: number }
  | { kind: "trimEnd"; value: number }
  | { kind: "keyframe"; id: string; value: number };

/** Port of `applying(_:within:)`. All timeline edits use source seconds. */
export function applyTimelineEdit(a: AnalysisAnnotation, edit: AnnotationTimelineEdit, lower: number, upper: number): AnalysisAnnotation {
  if (a.isLocked === true) return a;
  const minimum = Math.min(1 / 30, upper - lower);
  switch (edit.kind) {
    case "move": {
      const shift = Math.min(upper - a.end, Math.max(lower - a.start, edit.delta));
      const mode = motionMode(a);
      return { ...a, start: a.start + shift, end: a.end + shift, keyframes: mode === "still" || mode === "keyframes" ? a.keyframes.map((k) => ({ ...k, time: k.time + shift })) : a.keyframes };
    }
    case "trimStart": return { ...a, start: Math.min(a.end - minimum, Math.max(lower, edit.value)) };
    case "trimEnd": return { ...a, end: Math.max(a.start + minimum, Math.min(upper, edit.value)) };
    case "keyframe": {
      const index = a.keyframes.findIndex((k) => k.id === edit.id);
      if (index < 0) return a;
      const lo = Math.max(a.start, index > 0 ? a.keyframes[index - 1]!.time + EPSILON_FRAME : a.start);
      const hi = Math.min(a.end, index + 1 < a.keyframes.length ? a.keyframes[index + 1]!.time - EPSILON_FRAME : a.end);
      if (hi < lo) return a;
      return { ...a, keyframes: a.keyframes.map((k, i) => (i === index ? { ...k, time: Math.min(hi, Math.max(lo, edit.value)) } : k)) };
    }
  }
}

export function makeStatic(a: AnalysisAnnotation, time: number): AnalysisAnnotation {
  const { playerMotion: _p, linkedPlayers: _l, cameraMotion: _c, ...rest } = a;
  return { ...rest, points: pointsAt(a, time), keyframes: [] };
}

export function enableKeyframes(a: AnalysisAnnotation, time: number): AnalysisAnnotation {
  const mode = motionMode(a);
  if (!(a.keyframes.length === 0 || mode === "player" || mode === "camera")) return a;
  let result = makeStatic(a, time);
  result = setKeyframe(result, result.start, result.points);
  if (time > result.start + 1 / 30 && time <= result.end) result = setKeyframe(result, time, result.points);
  return result;
}

/** Port of `moveDrawing(to:at:)`: stores the pose back through whatever motion drives the layer. */
export function moveDrawing(a: AnalysisAnnotation, points: Point[], time: number): AnalysisAnnotation {
  if (motionMode(a) === "keyframes") return setKeyframe(a, Math.min(a.end, Math.max(a.start, time)), points);
  const camera = a.cameraMotion ? transformAt(a.cameraMotion, time) : null;
  if (camera) {
    const inverse = mat3Inverse(cameraMatrix(camera));
    if (!inverse) return a;
    return { ...a, points: points.map((p) => mat3Point(inverse, p)).filter((p): p is Point => p !== null) };
  }
  if (a.linkedPlayers && a.linkedPlayers.length === points.length) {
    return { ...a, points: points.map((point, i) => {
      const motion = a.linkedPlayers![i]!, reference = referenceBox(motion), box = boxAt(motion, time);
      if (!reference || !box) return point;
      return { x: rectMidX(reference) + point.x - rectMidX(box), y: rectMaxY(reference) + point.y - rectMaxY(box) };
    }) };
  }
  const motion = displayPlayerMotion(a);
  const reference = motion ? referenceBox(motion) : undefined;
  const box = motion ? boxAt(motion, time) : null;
  if (motion && reference && box) {
    if (isPlayerTool(a.tool)) {
      const body = effectBodyBox(motion, time), feet = groundPoint(motion, time);
      if (!body || !feet) return a;
      return { ...a, points: points.map((p) => ({ x: rectMidX(reference) + (p.x - feet.x) * reference.width / Math.max(0.001, body.width), y: rectMaxY(reference) + (p.y - feet.y) * reference.height / Math.max(0.001, body.height) })) };
    }
    if (a.tool === "text" || a.tool === "loupe") return { ...a, points: points.map((p) => ({ x: p.x + rectMidX(reference) - rectMidX(box), y: p.y + rectMidY(reference) - rectMidY(box) })) };
    return { ...a, points: points.map((p) => ({ x: rectMidX(reference) + (p.x - rectMidX(box)) * reference.width / Math.max(0.001, box.width), y: rectMaxY(reference) + (p.y - rectMaxY(box)) * reference.height / Math.max(0.001, box.height) })) };
  }
  return { ...a, points };
}

export function motionStart(a: AnalysisAnnotation): number | null {
  if (a.cameraMotion) return a.cameraMotion.samples[0]?.time ?? null;
  if (a.linkedPlayers) { const starts = a.linkedPlayers.map((m) => m.samples[0]?.time).filter((t): t is number => t != null); return starts.length ? Math.max(...starts) : null; }
  return a.playerMotion?.samples[0]?.time ?? null;
}

export function trackedSpan(a: AnalysisAnnotation): TimeRange | null {
  const lower = Math.max(a.start, motionStart(a) ?? a.start);
  let upper: number;
  if (a.cameraMotion) upper = Math.min(a.end, a.cameraMotion.lostAt ?? a.cameraMotion.samples[a.cameraMotion.samples.length - 1]?.time ?? a.start);
  else {
    const motions = a.linkedPlayers ?? (a.playerMotion ? [a.playerMotion] : []);
    if (motions.length === 0) return null;
    const ends = motions.map((m) => m.lostAt ?? m.samples[m.samples.length - 1]?.time).filter((t): t is number => t != null);
    upper = Math.min(a.end, ends.length ? Math.min(...ends) : a.start);
  }
  return lower <= upper ? [lower, upper] : null;
}

export const trackingGaps = (a: AnalysisAnnotation): TimeRange[] => (a.linkedPlayers ?? (a.playerMotion ? [a.playerMotion] : [])).flatMap((m) => m.gaps ?? []);

/* ---- Grounding (GroundShapeGeometry.swift) ---- */

export function groundPlane(a: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): GroundCalibration | null {
  if (!hasPlane(ground) || !supportsGrounding(a) || !isGrounded(a, true)) return null;
  return frozenGround(ground, time);
}

function projectGroundPoints(points: Point[], plane: GroundCalibration, time: number): Point[] | null {
  const out: Point[] = [];
  for (const p of points) { const q = imagePoint(plane, p, time); if (!q) return null; out.push(q); }
  return out;
}

export function groundShapeCorners(a: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): Point[] | null {
  if (a.tool !== "rectangle" && a.tool !== "ellipse") return null;
  const plane = groundPlane(a, time, ground);
  if (!plane) return null;
  const pose = pointsAt(a, time), first = pose[0], last = pose[pose.length - 1];
  if (!first || !last) return null;
  const wa = worldPoint(plane, first, time), wb = worldPoint(plane, last, time);
  if (!wa || !wb) return null;
  return projectGroundPoints([wa, { x: wb.x, y: wa.y }, wb, { x: wa.x, y: wb.y }], plane, time);
}

/** Normalised image vertices shared by rendering, selection and measurements. */
export function shapeBoundary(a: AnalysisAnnotation, time: number, ground: GroundCalibration | null | undefined): Point[] {
  const pose = renderedPoints(a, time);
  if (!supportsGrounding(a) || !isGrounded(a, hasPlane(ground))) return pose;
  const plane = groundPlane(a, time, ground);
  if (!plane) return [];
  const first = pose[0], last = pose[pose.length - 1];
  if (!first || !last) return [];
  if (a.tool === "rectangle") return groundShapeCorners(a, time, plane) ?? [];
  if (a.tool === "ellipse") {
    const wa = worldPoint(plane, first, time), wb = worldPoint(plane, last, time);
    if (!wa || !wb) return [];
    const center = { x: (wa.x + wb.x) / 2, y: (wa.y + wb.y) / 2 };
    const vertices = Array.from({ length: 96 }, (_, i) => { const angle = i * 2 * Math.PI / 96; return { x: center.x + (wb.x - wa.x) / 2 * Math.cos(angle), y: center.y + (wb.y - wa.y) / 2 * Math.sin(angle) }; });
    return projectGroundPoints(vertices, plane, time) ?? [];
  }
  if (a.tool === "zone" && pose.length === 2) {
    const wa = worldPoint(plane, first, time), wb = worldPoint(plane, last, time);
    if (!wa || !wb) return [];
    return projectGroundPoints([wa, { x: wb.x, y: wa.y }, wb], plane, time) ?? [];
  }
  return pose;
}

export function setGrounding(a: AnalysisAnnotation, enabled: boolean, time: number, ground: GroundCalibration | null | undefined): AnalysisAnnotation {
  let result: AnalysisAnnotation = { ...a, grounded: enabled };
  const untracked = !a.playerMotion && !a.linkedPlayers && !a.cameraMotion && a.keyframes.length === 0;
  if (enabled && untracked) result.groundReferenceTime = time;
  if (enabled && untracked && ground?.cameraMotion) {
    result = makeStatic(result, time);
    result.cameraMotion = { ...ground.cameraMotion, referenceTime: time };
  }
  return result;
}

/* ---- Handles and reshaping (AnnotationShapeEditing.swift) ---- */

/** Rectangle-like shapes expose four real resize handles; paths expose vertices; freehand moves as a unit. */
export function editHandles(a: AnalysisAnnotation, time: number, ground?: GroundCalibration | null): Point[] {
  if ((a.tool === "rectangle" || a.tool === "ellipse") && isGrounded(a, hasPlane(ground))) return groundShapeCorners(a, time, ground) ?? [];
  const pose = pointsAt(a, time), first = pose[0], last = pose[pose.length - 1];
  if (!first || !last) return [];
  switch (a.tool) {
    case "pen": return [];
    case "rectangle": case "ellipse": case "player": case "spotlight": return [first, { x: last.x, y: first.y }, last, { x: first.x, y: last.y }];
    default: return pose;
  }
}

export function reshaped(a: AnalysisAnnotation, time: number, handle: number | null, delta: Size, ground?: GroundCalibration | null): Point[] {
  const pose = pointsAt(a, time).map((p) => ({ ...p }));
  const plane = isPlayerTool(a.tool) ? null : groundPlane(a, time, ground);
  if (plane) {
    const world = pose.map((p) => worldPoint(plane, p, time)).filter((p): p is Point => p !== null);
    const first = pose[0];
    if (world.length !== pose.length || !first) return pose;
    let moved = world.map((p) => ({ ...p }));
    if (handle != null && (a.tool === "rectangle" || a.tool === "ellipse") && world.length === 2) {
      const corner = editHandles(a, time, plane)[handle];
      const target = corner && worldPoint(plane, { x: corner.x + delta.width, y: corner.y + delta.height }, time);
      if (!target) return pose;
      switch (handle) {
        case 0: moved[0] = target; break;
        case 1: moved[1]!.x = target.x; moved[0]!.y = target.y; break;
        case 2: moved[1] = target; break;
        case 3: moved[0]!.x = target.x; moved[1]!.y = target.y; break;
        default: return pose;
      }
    } else if (handle == null) {
      const origin = world[0], target = worldPoint(plane, { x: first.x + delta.width, y: first.y + delta.height }, time);
      if (!origin || !target) return pose;
      moved = world.map((p) => ({ x: p.x + target.x - origin.x, y: p.y + target.y - origin.y }));
    } else if (pose[handle]) {
      pose[handle]!.x += delta.width; pose[handle]!.y += delta.height;
      return pose;
    }
    const projected = moved.map((p) => imagePoint(plane, p, time)).filter((p): p is Point => p !== null);
    return projected.length === pose.length ? projected : pose;
  }
  if (handle == null) return pose.map((p) => ({ x: p.x + delta.width, y: p.y + delta.height }));
  if ((a.tool === "rectangle" || a.tool === "ellipse" || isPlayerTool(a.tool)) && pose.length === 2) {
    const [p0, p1] = pose as [Point, Point];
    switch (handle) {
      case 0: p0.x += delta.width; p0.y += delta.height; break;
      case 1: p1.x += delta.width; p0.y += delta.height; break;
      case 2: p1.x += delta.width; p1.y += delta.height; break;
      case 3: p0.x += delta.width; p1.y += delta.height; break;
    }
  } else if (pose[handle]) { pose[handle]!.x += delta.width; pose[handle]!.y += delta.height; }
  return pose;
}

/** Keep topology identical in every authored keyframe. */
export function insertPolygonCorner(a: AnalysisAnnotation, after: number): AnalysisAnnotation {
  if (a.tool !== "zone" || a.fieldLines === true || a.linkedPlayers || a.isLocked === true) return a;
  if (a.points.length < 3 || a.points.length >= 12 || after < 0 || after >= a.points.length) return a;
  if (!a.keyframes.every((k) => k.points.length === a.points.length)) return a;
  const inserting = (pose: Point[]) => { const p = pose[after]!, q = pose[(after + 1) % pose.length]!; const out = [...pose]; out.splice(after + 1, 0, { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 }); return out; };
  return { ...a, points: inserting(a.points), keyframes: a.keyframes.map((k) => ({ ...k, points: inserting(k.points) })) };
}

export function removePolygonCorner(a: AnalysisAnnotation, index: number): AnalysisAnnotation {
  if (a.tool !== "zone" || a.fieldLines === true || a.linkedPlayers || a.isLocked === true || a.points.length <= 3) return a;
  if (index < 0 || index >= a.points.length || !a.keyframes.every((k) => k.points.length === a.points.length)) return a;
  const removing = (pose: Point[]) => pose.filter((_, i) => i !== index);
  return { ...a, points: removing(a.points), keyframes: a.keyframes.map((k) => ({ ...k, points: removing(k.points) })) };
}

/* ---- Styles ---- */

export const resolvedTextStyle = (a: AnalysisAnnotation): AnnotationTextStyle => a.textStyle ?? textStyle({ size: a.width * 6 });

export function resolvedLineStyle(a: AnalysisAnnotation): AnnotationLineStyle {
  if (a.lineStyle) return a.lineStyle;
  if (a.tool === "arrow") return LEGACY_ARROW_STYLE;
  if (a.tool === "connection") return CONNECTION_LINE_STYLE;
  return DEFAULT_LINE_STYLE;
}

/** Font pixel size for a frame width (shared by the renderer and hit testing). */
export function textPixelSize(a: AnalysisAnnotation, frameWidth: number): number {
  const style = resolvedTextStyle(a);
  return a.textStyle == null ? Math.max(12, frameWidth * a.width * 6) : Math.max(1, frameWidth * Math.min(0.24, Math.max(0.005, style.size)));
}

/** Text metrics without a canvas: approximate glyph advance so hit testing stays pure. */
export function approximateTextBounds(a: AnalysisAnnotation, frameWidth: number): Rect {
  const style = resolvedTextStyle(a), size = textPixelSize(a, frameWidth);
  const lines = a.text.split(/\r?\n/);
  let minX = Infinity, maxX = -Infinity, maxY = -Infinity;
  lines.forEach((line, i) => {
    const width = Math.max(1, line.length * size * (style.weight === "bold" ? 0.58 : 0.54));
    const x = style.alignment === "left" ? 0 : style.alignment === "center" ? -width / 2 : -width;
    minX = Math.min(minX, x); maxX = Math.max(maxX, x + width); maxY = Math.max(maxY, i * size * 1.2 + size * 0.25);
  });
  const ascent = size * 0.8;
  return { x: minX - size * 0.15, y: -ascent - size * 0.1, width: maxX - minX + size * 0.3, height: maxY + ascent + size * 0.2 };
}

const containsPoint = (rect: Rect, p: Point) => p.x >= rect.x && p.x <= rectMaxX(rect) && p.y >= rect.y && p.y <= rectMaxY(rect);

/** Port of the workspace `hit(_:)`: topmost unlocked visible annotation under a normalised point. */
export function hitTest(annotations: readonly AnalysisAnnotation[], point: Point, time: number, ground: GroundCalibration | null | undefined, displayAspect: number): AnalysisAnnotation | null {
  for (let i = annotations.length - 1; i >= 0; i--) {
    const mark = annotations[i]!;
    if (mark.isHidden === true || mark.isLocked === true || time < mark.start || time > mark.end || !hasMotion(mark, time)) continue;
    const points = shapeBoundary(mark, time, ground), first = points[0];
    if (!first) continue;
    if (mark.tool === "text") {
      const b = approximateTextBounds(mark, 1000);
      if (containsPoint({ x: first.x + b.x / 1000 - 0.015, y: first.y + b.y * displayAspect / 1000 - 0.015, width: b.width / 1000 + 0.03, height: b.height * displayAspect / 1000 + 0.03 }, point)) return mark;
      continue;
    }
    const xs = points.map((p) => p.x), ys = points.map((p) => p.y);
    if (containsPoint({ x: Math.min(...xs) - 0.025, y: Math.min(...ys) - 0.025, width: Math.max(...xs) - Math.min(...xs) + 0.05, height: Math.max(...ys) - Math.min(...ys) + 0.05 }, point)) return mark;
  }
  return null;
}

/** Nearest handle within `radius` pixels, or null. */
export function handleIndexAt(mark: AnalysisAnnotation, location: Point, frame: Rect, time: number, ground: GroundCalibration | null | undefined, radius = 22): number | null {
  if (mark.isLocked === true || mark.isHidden === true || time < mark.start || time > mark.end || !hasMotion(mark, time)) return null;
  let bestIndex = -1, bestDistance = Infinity;
  editHandles(mark, time, ground).forEach((handle, index) => {
    const distance = Math.hypot(frame.x + handle.x * frame.width - location.x, frame.y + handle.y * frame.height - location.y);
    if (distance < bestDistance) { bestDistance = distance; bestIndex = index; }
  });
  return bestIndex >= 0 && bestDistance <= radius ? bestIndex : null;
}

export interface ConnectionAnchor { id: number; name: string; point: Point | null; lastSeen: { time: number; box: Rect } | null; isMissing: boolean; title: string }

/** Port of `connectionAnchors(at:library:)`: editor markers for each linked endpoint. */
export function connectionAnchors(a: AnalysisAnnotation, time: number, playerName: (trackID: string | undefined, index: number) => string): ConnectionAnchor[] {
  return (a.linkedPlayers ?? []).map((motion, index) => {
    const name = playerName(motion.trackID, index);
    let seen: { time: number; box: Rect } | null = null;
    for (let i = motion.samples.length - 1; i >= 0; i--) {
      const s = motion.samples[i]!;
      if (s.time <= time + 0.001 && (motion.lostAt == null || s.time < motion.lostAt) && !motion.gaps?.some((g) => s.time >= g[0] && s.time <= g[1])) { seen = s; break; }
    }
    const current = boxAt(motion, time);
    const box = current ?? seen?.box;
    const reference = referenceBox(motion), point = a.points[index];
    const position = box && reference && point ? { x: rectMidX(box) + point.x - rectMidX(reference), y: rectMaxY(box) + point.y - rectMaxY(reference) } : null;
    return { id: index, name, point: position, lastSeen: seen, isMissing: current === null, title: `${index + 1} · ${name}` };
  });
}

export const newAnnotation = (tool: AnalysisDrawingTool, points: Point[], start: number, end: number, overrides: Partial<AnalysisAnnotation> = {}): AnalysisAnnotation => ({
  id: newId(), tool, points, color: { red: 0.86, green: 1, blue: 0.15 }, width: 0.006, text: "", start, end, fade: false, keyframes: [], ...overrides,
});
