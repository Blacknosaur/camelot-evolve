/* Throw-away ("replay") capture bookkeeping, mirroring the rolling branch of `CameraRecorder`
   (CameraView.swift). The buffer keeps at most the previous and the active segment. Tapping an event
   promotes both; the active segment then runs until the last pending post-roll before buffering resumes.
   Offsets are seconds on the active segment's movie clock. */

export interface RollingBuffer {
  bufferSeconds: number;
  previous: string | null;
  active: string | null;
  promoted: boolean;
  /** Segment offset at which the active file closes. */
  deadline: number;
}

export type RotationReason = "buffer-rotation" | "user" | "interruption" | "background" | "low-storage";

export interface Rotation {
  buffer: RollingBuffer;
  /** Segment IDs to move into the library, oldest first. */
  save: string[];
  /** Segment IDs whose files and journals are deleted. */
  discard: string[];
  /** Whether a fresh segment should start right away. */
  continues: boolean;
}

export function createRollingBuffer(bufferSeconds: number): RollingBuffer {
  return { bufferSeconds, previous: null, active: null, promoted: false, deadline: bufferSeconds };
}

export function beginSegment(buffer: RollingBuffer, id: string): RollingBuffer {
  return { ...buffer, active: id, promoted: false, deadline: buffer.bufferSeconds };
}

/** Event tap: keeps the buffered context and extends the active file to cover the post-roll.
 *  Preserves the latest deadline across overlapping events. */
export function promote(buffer: RollingBuffer, currentOffset: number, endOffset: number): { buffer: RollingBuffer; contextRecordingIDs: string[] } {
  const deadline = Math.max(currentOffset + 0.1, endOffset, buffer.promoted ? buffer.deadline : 0);
  return { buffer: { ...buffer, promoted: true, deadline }, contextRecordingIDs: buffer.previous ? [buffer.previous] : [] };
}

/** "End now": shortens the promoted file to the remaining window, or closes it immediately when none is left. */
export function endEventCapture(buffer: RollingBuffer, currentOffset: number, endOffset: number | null): RollingBuffer {
  if (!buffer.promoted) return buffer;
  return { ...buffer, deadline: endOffset != null && endOffset > currentOffset ? endOffset : currentOffset };
}

export const isDue = (buffer: RollingBuffer, offset: number) => buffer.active != null && offset >= buffer.deadline;

/** The active file just closed (or is closing). Decides what to keep, save and discard. */
export function rotate(buffer: RollingBuffer, reason: RotationReason): Rotation {
  const active = buffer.active;
  if (!active) return { buffer, save: [], discard: [], continues: false };
  const previous = buffer.previous ? [buffer.previous] : [];
  const cleared = { ...buffer, active: null, promoted: false, previous: null, deadline: buffer.bufferSeconds };
  if (buffer.promoted) return { buffer: cleared, save: [...previous, active], discard: [], continues: reason === "buffer-rotation" };
  if (reason !== "buffer-rotation") return { buffer: cleared, save: [], discard: [...previous, active], continues: false };
  return { buffer: { ...cleared, previous: active }, save: [], discard: previous, continues: true };
}

/** Segments currently held on disk by the buffer. */
export const retainedSegments = (buffer: RollingBuffer) => [buffer.previous, buffer.active].filter((id): id is string => id != null);
