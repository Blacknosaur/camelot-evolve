/* Port of clients/ios/Camelot/EditorGeometry.swift. All geometry uses seconds; zoom never
   creates a DOM node per frame. Pure functions so the timeline canvas, the event browser and
   the tests share one implementation. */

import type { UUID } from "@/domain";

/** Occurrence identity: an event as it appears inside one clip. `clipID` is null for source events. */
export interface TimelineEventID { eventID: UUID; clipID: UUID | null }

export const eventIDKey = (id: TimelineEventID) => `${id.eventID}-${id.clipID ?? "source"}`;
export const sameEventID = (a: TimelineEventID | null | undefined, b: TimelineEventID | null | undefined) =>
  !!a && !!b && a.eventID === b.eventID && a.clipID === b.clipID;

export interface TimelineEventSnapshot {
  id: TimelineEventID;
  /** Marker position in output seconds. */
  offset: number;
  preRoll: number;
  postRoll: number;
  kind: string;
  colorHex: string;
  isDrawing: boolean;
  isLocked: boolean;
  /** Footage retained by the owning clip; windows are clipped to it. */
  lowerBound: number;
  upperBound: number;
}

export function makeSnapshot(partial: Partial<TimelineEventSnapshot> & Pick<TimelineEventSnapshot, "offset" | "preRoll" | "postRoll" | "kind">): TimelineEventSnapshot {
  return {
    id: partial.id ?? { eventID: crypto.randomUUID().toUpperCase(), clipID: null },
    colorHex: partial.colorHex ?? "",
    isDrawing: partial.isDrawing ?? false,
    isLocked: partial.isLocked ?? false,
    lowerBound: partial.lowerBound ?? 0,
    upperBound: partial.upperBound ?? Number.POSITIVE_INFINITY,
    offset: partial.offset, preRoll: partial.preRoll, postRoll: partial.postRoll, kind: partial.kind,
  };
}

export const snapshotStart = (s: TimelineEventSnapshot) => Math.max(s.lowerBound, s.offset - s.preRoll);
export const snapshotEnd = (s: TimelineEventSnapshot) => Math.min(s.upperBound, s.offset + s.postRoll);

/** Drawing edges are independent. Match events must still contain their marker. */
export function resizeSnapshot(s: TimelineEventSnapshot, value: number, start: number, end: number, leading: boolean, duration: number): [number, number] {
  if (s.isLocked) return [start, end];
  if (s.isDrawing) {
    const minimum = Math.min(1 / 30, Math.max(0, Math.min(s.upperBound, duration) - s.lowerBound));
    return leading
      ? [Math.max(s.lowerBound, Math.min(value, end - minimum)), end]
      : [start, Math.min(s.upperBound, duration, Math.max(value, start + minimum))];
  }
  return leading
    ? [Math.max(s.lowerBound, Math.min(s.offset, end, value)), end]
    : [start, Math.min(s.upperBound, duration, Math.max(s.offset, start, value))];
}

/** Adjacent cuts of the same source window retain one marker and one pair of handles.
 *  Different timing (repeats, gaps, or speed changes) stays separate. */
export function joinContinuousWindow(a: TimelineEventSnapshot, next: TimelineEventSnapshot): TimelineEventSnapshot | null {
  const tolerance = 0.000_001;
  const close = (x: number, y: number) => Math.abs(x - y) < tolerance;
  if (a.id.eventID !== next.id.eventID || a.isDrawing !== next.isDrawing || a.isLocked !== next.isLocked) return null;
  if (!close(a.upperBound, next.lowerBound) || !close(snapshotEnd(a), snapshotStart(next))) return null;
  if (!close(a.offset, next.offset) || !close(a.preRoll, next.preRoll) || !close(a.postRoll, next.postRoll)) return null;
  // Select the clip containing the actual marker when it survives the cut.
  const anchor = a.offset >= next.lowerBound ? next.id : a.id;
  return { ...a, id: anchor, upperBound: next.upperBound };
}

/** Maps seconds to canvas x around a centred playhead. */
export interface TimelineGeometry { duration: number; width: number; zoom: number; contentInset: number }

export const makeGeometry = (duration: number, width: number, zoom: number, contentInset = 0): TimelineGeometry => ({ duration, width, zoom, contentInset });

export const pointsPerSecond = (g: TimelineGeometry) => Math.max(1, g.width - g.contentInset * 2) * Math.max(1, g.zoom) / Math.max(0.1, g.duration);
export const timeToX = (g: TimelineGeometry, seconds: number, center: number) => g.width / 2 + (seconds - center) * pointsPerSecond(g);
export const clampTime = (g: TimelineGeometry, seconds: number) => Math.max(0, Math.min(g.duration, seconds));
export const xToTime = (g: TimelineGeometry, x: number, center: number) => clampTime(g, center + (x - g.width / 2) / pointsPerSecond(g));

const TICKS = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600];

export function tickInterval(g: TimelineGeometry): number {
  const ideal = 72 / pointsPerSecond(g);
  return TICKS.find((t) => t >= ideal) ?? Math.ceil(ideal / 3600) * 3600;
}

export function subdivisionInterval(g: TimelineGeometry): number {
  const major = tickInterval(g);
  if ([0.2, 2, 120].includes(major)) return major / 4;
  if (major === 15) return 5;
  if ([30, 60, 600, 1800, 3600].includes(major)) return major / 6;
  return major / 5;
}

/** Trim edge that can never cross the other edge or leave the recording. */
export function trimRange(value: number, start: number, end: number, duration: number, leading: boolean): [number, number] {
  const minimum = Math.min(0.1, Math.max(0, duration));
  if (leading) return [Math.max(0, Math.min(value, end - minimum)), end];
  return [start, Math.min(duration, Math.max(value, start + minimum))];
}

export const maxZoom = (duration: number) => Math.max(1, duration / 2);

export interface TimelinePlacedEvent { event: TimelineEventSnapshot; row: number }

/** Interval partitioning runs only when events change, never on a scroll/zoom frame. */
export function layoutEvents(events: readonly TimelineEventSnapshot[]): TimelinePlacedEvent[] {
  const ends: number[] = [];
  return [...events]
    .sort((a, b) => {
      const sa = snapshotStart(a), sb = snapshotStart(b);
      if (sa === sb) return a.offset === b.offset ? eventIDKey(a.id).localeCompare(eventIDKey(b.id)) : a.offset - b.offset;
      return sa - sb;
    })
    .map((event) => {
      const start = snapshotStart(event);
      let row = ends.findIndex((e) => e <= start);
      if (row < 0) row = ends.length;
      ends[row] = Math.max(start + 0.1, snapshotEnd(event));
      return { event, row };
    });
}

/** One preview and one workspace, separated by a fixed 20px grip. */
export function panelSizes(height: number, workspace: number, minimumWorkspace = 220): { preview: number; workspace: number } {
  const space = Math.max(0, height - 20);
  const minimumPreview = Math.min(160, space * 0.35);
  const minWorkspace = Math.min(minimumWorkspace, space * 0.45);
  const w = Math.min(Math.max(minWorkspace, workspace), Math.max(minWorkspace, space - minimumPreview));
  return { workspace: w, preview: Math.max(0, space - w) };
}

/** Preview dimensions can differ by a pixel after even-size video encoding. */
export function videoAspectRatioLabel(width: number, height: number): string {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return "…";
  const ratio = width / height;
  for (const [w, h] of [[1, 1], [16, 9], [9, 16], [4, 3], [3, 4], [4, 5], [5, 4], [3, 2], [2, 3], [17, 9], [21, 9]] as const) {
    const candidate = w / h;
    if (Math.abs(ratio - candidate) / candidate < 0.003) return `${w}:${h}`;
  }
  return `${ratio.toFixed(2)}:1`;
}

/** "4:05.3" with rounded tenths that carry across the minute ("59.99" → "1:00.0"). */
export function timelineTimecode(seconds: number, includesTenths = true): string {
  const value = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  if (!includesTenths) {
    const total = Math.floor(value);
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
  }
  const tenths = Math.round(value * 10);
  return `${Math.floor(tenths / 600)}:${String(Math.floor(tenths / 10) % 60).padStart(2, "0")}.${tenths % 10}`;
}
