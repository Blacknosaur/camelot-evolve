/* Port of `CameraEventCapture` (CameraEventCapture.swift) as pure functions so the countdown
   bookkeeping is testable. Pending windows follow the movie clock, so they pause with the footage. */

export interface PendingEvent {
  id: string;
  recordingID: string;
  kind: string;
  offsetSeconds: number;
  postRollSeconds: number;
}

export interface EventCaptureState {
  active: PendingEvent[];
  /** Latest movie-clock offset seen for `recordingID`. */
  offset: number;
  recordingID: string | null;
  selectedID: string | null;
}

/** An event whose post-roll was cut short and needs persisting. */
export interface ShortenedEvent { id: string; postRollSeconds: number }

export const emptyEventCapture: EventCaptureState = { active: [], offset: 0, recordingID: null, selectedID: null };

export function selectedEvent(state: EventCaptureState): PendingEvent | null {
  return state.active.find((e) => e.id === state.selectedID) ?? state.active.at(-1) ?? null;
}

export function remaining(state: EventCaptureState, event: PendingEvent): number {
  return Math.max(0, event.offsetSeconds + event.postRollSeconds - state.offset);
}

export function addEvent(state: EventCaptureState, event: PendingEvent): EventCaptureState {
  return { active: [...state.active, event], offset: event.offsetSeconds, recordingID: event.recordingID, selectedID: event.id };
}

/** Latest deadline among the windows open on `recordingID`; `null` when none is pending. */
export function endOffset(state: EventCaptureState, recordingID: string): number | null {
  const ends = state.active.filter((e) => e.recordingID === recordingID).map((e) => e.offsetSeconds + e.postRollSeconds);
  return ends.length ? Math.max(...ends) : null;
}

/** Moves the clock forward and drops windows that ran their full post-roll. */
export function advance(state: EventCaptureState, recordingID: string, offset: number): EventCaptureState {
  if (state.recordingID !== recordingID || !Number.isFinite(offset)) return state;
  const next = { ...state, offset: Math.max(state.offset, offset) };
  const active = next.active.filter((e) => remaining(next, e) > 0);
  return active.length === next.active.length ? next : { ...next, active };
}

function shorten(event: PendingEvent, endingAt: number): ShortenedEvent | null {
  const duration = Math.min(event.postRollSeconds, Math.max(0, endingAt - event.offsetSeconds));
  return duration === event.postRollSeconds ? null : { id: event.id, postRollSeconds: duration };
}

/** "End now": closes one window at the current offset. Returns `null` when the event is not pending. */
export function endNow(state: EventCaptureState, eventID: string, recordingID: string, offset: number): { state: EventCaptureState; shortened: ShortenedEvent | null } | null {
  if (!Number.isFinite(offset)) return null;
  const event = state.active.find((e) => e.id === eventID && e.recordingID === recordingID);
  if (!event) return null;
  const without = { ...state, active: state.active.filter((e) => e.id !== eventID) };
  return { state: advance(without, recordingID, offset), shortened: shorten(event, offset) };
}

/** Stopping or interrupting a recording also closes its unfinished windows at the file's end. */
export function finishSegment(state: EventCaptureState, recordingID: string, duration: number): { state: EventCaptureState; shortened: ShortenedEvent[] } {
  const shortened: ShortenedEvent[] = [];
  for (const event of state.active) if (event.recordingID === recordingID) { const s = shorten(event, duration); if (s) shortened.push(s); }
  return { state: { ...state, active: state.active.filter((e) => e.recordingID !== recordingID) }, shortened };
}

export function selectEvent(state: EventCaptureState, id: string): EventCaptureState {
  return state.selectedID === id ? state : { ...state, selectedID: id };
}
