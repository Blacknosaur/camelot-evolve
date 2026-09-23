/* Maps clips to positions in the assembled video and projects source events onto it.
   Port of EditorSequenceSegment / EditorSequenceEvent (EditorGeometry.swift, EditorPlaybackControls.swift). */

import { clampRate, type CompositionClip, type MatchEvent, type UUID } from "@/domain";
import { joinContinuousWindow, makeSnapshot, snapshotEnd, snapshotStart, type TimelineEventSnapshot } from "./geometry";

export interface SequenceSegment {
  id: UUID;
  recordingID: UUID;
  sourceStart: number;
  sourceEnd: number;
  rate: number;
  /** Output start. */
  start: number;
  freezeDuration: number | null;
}

export const segmentDuration = (s: SequenceSegment) => s.freezeDuration ?? Math.max(0, s.sourceEnd - s.sourceStart) / clampRate(s.rate);
export const segmentEnd = (s: SequenceSegment) => s.start + segmentDuration(s);

/** Source time shown at an output time inside the segment. Held frames always show their start. */
export function sourceTimeAt(s: SequenceSegment, seconds: number): number {
  if (s.freezeDuration != null) return s.sourceStart;
  return Math.min(s.sourceEnd, Math.max(s.sourceStart, s.sourceStart + (seconds - s.start) * clampRate(s.rate)));
}

export function outputTimeAt(s: SequenceSegment, sourceSeconds: number): number {
  return Math.min(segmentEnd(s), Math.max(s.start, s.start + (sourceSeconds - s.sourceStart) / clampRate(s.rate)));
}

export function segmentsForClips(clips: readonly CompositionClip[]): SequenceSegment[] {
  let cursor = 0;
  return clips.map((clip) => {
    const segment: SequenceSegment = { id: clip.id, recordingID: clip.recordingID, sourceStart: clip.startSeconds, sourceEnd: clip.endSeconds, rate: clip.rate, start: cursor, freezeDuration: clip.freezeDuration ?? null };
    cursor = segmentEnd(segment);
    return segment;
  });
}

export const sequenceDuration = (segments: readonly SequenceSegment[]) => (segments.length ? segmentEnd(segments[segments.length - 1]!) : 0);

/** Segment under an output time; the last one at/after the end, the first before zero. */
export function segmentContaining(seconds: number, segments: readonly SequenceSegment[]): SequenceSegment | null {
  const hit = segments.find((s) => seconds >= s.start && seconds < segmentEnd(s));
  if (hit) return hit;
  const last = segments[segments.length - 1];
  if (!last) return null;
  return seconds >= segmentEnd(last) ? last : segments[0]!;
}

/** Preserve the true marker position even when only its before/after window survives a cut.
 *  Drawing and handle movement are limited to retained footage. Holds add presentation time,
 *  not a second occurrence of a match event. */
export function eventSnapshotInSegment(segment: SequenceSegment, event: TimelineEventSnapshot): TimelineEventSnapshot | null {
  if (segment.freezeDuration != null) return null;
  if (!(snapshotEnd(event) > segment.sourceStart && snapshotStart(event) < segment.sourceEnd)) return null;
  const speed = clampRate(segment.rate);
  return makeSnapshot({
    id: { eventID: event.id.eventID, clipID: segment.id },
    offset: segment.start + (event.offset - segment.sourceStart) / speed,
    preRoll: event.preRoll / speed,
    postRoll: event.postRoll / speed,
    kind: event.kind, colorHex: event.colorHex,
    lowerBound: segment.start, upperBound: segmentEnd(segment),
  });
}

export function snapshotForEvent(event: MatchEvent): TimelineEventSnapshot {
  return makeSnapshot({ id: { eventID: event.id, clipID: null }, offset: event.offsetSeconds, preRoll: event.preRollSeconds, postRoll: event.postRollSeconds, kind: event.kind, colorHex: event.colorHex });
}

/** An event as it occurs in the assembled video. */
export interface SequenceEvent {
  event: MatchEvent;
  firstClip: number;
  lastClip: number;
  snapshot: TimelineEventSnapshot;
}

export const sequenceEventOffset = (e: SequenceEvent) => Math.min(e.snapshot.upperBound, Math.max(e.snapshot.lowerBound, e.snapshot.offset));
export const clipLabel = (e: SequenceEvent) => (e.firstClip === e.lastClip ? `Clip ${e.firstClip}` : `Clips ${e.firstClip}–${e.lastClip}`);

export function joinContinuousWindows(events: readonly SequenceEvent[]): SequenceEvent[] {
  const result: SequenceEvent[] = [];
  const lastIndex = new Map<UUID, number>();
  for (const occurrence of events) {
    const index = lastIndex.get(occurrence.snapshot.id.eventID);
    const joined = index == null ? null : joinContinuousWindow(result[index]!.snapshot, occurrence.snapshot);
    if (index != null && joined) {
      result[index] = { event: occurrence.event, firstClip: result[index]!.firstClip, lastClip: occurrence.lastClip, snapshot: joined };
    } else {
      lastIndex.set(occurrence.snapshot.id.eventID, result.length);
      result.push(occurrence);
    }
  }
  return result;
}

/** Every occurrence of every event across the assembled clips, in output order. */
export function sequenceEvents(clips: readonly CompositionClip[], events: readonly MatchEvent[]): SequenceEvent[] {
  const byRecording = new Map<UUID, MatchEvent[]>();
  for (const event of events) {
    if (!event.recordingID) continue;
    const list = byRecording.get(event.recordingID) ?? [];
    list.push(event);
    byRecording.set(event.recordingID, list);
  }
  const occurrences = segmentsForClips(clips).flatMap((segment, index) =>
    (byRecording.get(segment.recordingID) ?? []).flatMap((event) => {
      const snapshot = eventSnapshotInSegment(segment, snapshotForEvent(event));
      return snapshot ? [{ event, firstClip: index + 1, lastClip: index + 1, snapshot }] : [];
    }),
  );
  return joinContinuousWindows(occurrences);
}
