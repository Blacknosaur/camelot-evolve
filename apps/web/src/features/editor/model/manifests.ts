/* Composition manifests: ordered immutable recording ranges. Port of the clip builders in
   RecordingEditorView.swift (clipsForEvents / mergeOverlapping) so project detail, the editor
   and the footage picker generate identical manifests. */

import { newId, type CompositionClip, type MatchEvent, type Recording, type UUID } from "@/domain";

export function makeClip(recordingID: UUID, startSeconds: number, endSeconds: number, extra: Partial<CompositionClip> = {}): CompositionClip {
  return { id: newId(), recordingID, startSeconds, endSeconds: Math.max(startSeconds, endSeconds), rate: 1, annotations: [], ...extra };
}

/** Whole recording as one clip; a zero-length recording still yields a playable 0.1 s clip. */
export const fullClip = (recording: Recording) => makeClip(recording.id, 0, Math.max(0.1, recording.duration));

const bySegment = (recordings: readonly Recording[]) => [...recordings].filter((r) => !r.pendingDeletion).sort((a, b) => a.segmentIndex - b.segmentIndex || a.createdAt.localeCompare(b.createdAt));

/** "Full match": every recording of the project, end to end, in capture order. */
export function fullMatchClips(recordings: readonly Recording[]): CompositionClip[] {
  return bySegment(recordings).map(fullClip);
}

/** Adjacent or overlapping ranges of the same recording collapse into one clip. */
export function mergeOverlapping(source: readonly CompositionClip[]): CompositionClip[] {
  const result: CompositionClip[] = [];
  for (const clip of source) {
    const last = result[result.length - 1];
    if (last && last.recordingID === clip.recordingID && clip.startSeconds <= last.endSeconds) {
      result[result.length - 1] = { ...last, endSeconds: Math.max(last.endSeconds, clip.endSeconds) };
    } else result.push(clip);
  }
  return result;
}

/** Window around an event, including preceding rolling-buffer context segments that hold its pre-roll. */
export function eventClips(recording: Recording | undefined, event: MatchEvent, recordings: readonly Recording[]): CompositionClip[] {
  const source = recording ?? recordings.find((r) => r.id === event.recordingID);
  if (!source) return [];
  const context = event.contextRecordingIDs.flatMap((id) => {
    const contextRecording = recordings.find((r) => r.id === id);
    return contextRecording ? [makeClip(id, Math.max(0, contextRecording.duration - event.preRollSeconds), contextRecording.duration)] : [];
  });
  const start = context.length ? 0 : Math.max(0, event.offsetSeconds - event.preRollSeconds);
  return [...context, makeClip(source.id, start, Math.min(source.duration, event.offsetSeconds + event.postRollSeconds))];
}

/** Single-clip window for an event inside its own recording (footage picker, "Save selected event"). */
export function eventWindowClip(recording: Recording, event: MatchEvent): CompositionClip {
  return makeClip(recording.id, Math.max(0, event.offsetSeconds - event.preRollSeconds), Math.min(recording.duration, event.offsetSeconds + event.postRollSeconds));
}

/** Clips for a set of events in recording/time order, with overlapping windows merged. */
export function clipsForEvents(events: readonly MatchEvent[], recordings: readonly Recording[]): CompositionClip[] {
  const order = new Map(bySegment(recordings).map((r, i) => [r.id, i] as const));
  const sorted = [...events].filter((e) => e.recordingID && order.has(e.recordingID)).sort((a, b) => (order.get(a.recordingID!)! - order.get(b.recordingID!)!) || a.offsetSeconds - b.offsetSeconds);
  return mergeOverlapping(sorted.flatMap((event) => eventClips(undefined, event, recordings)));
}

/** "Goals": every goal's window in match order. */
export function goalsSummaryClips(recordings: readonly Recording[], events: readonly MatchEvent[]): CompositionClip[] {
  return clipsForEvents(events.filter((e) => e.kind === "Goal" && !e.pendingDeletion), recordings);
}
