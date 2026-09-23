/* Pure edit operations on the clip list plus a bounded undo history.
   Port of the mutation helpers in RecordingEditorView.swift. */

import { clampRate, newId, type AspectRatio, type CompositionClip, type UUID, type VideoComposition } from "@/domain";
import { segmentsForClips, sourceTimeAt } from "./sequence";

export const ASPECT_RATIOS: readonly AspectRatio[] = ["original", "16:9", "9:16", "1:1", "4:5"];
export const aspectTitle = (a: string) => ({ original: "Original", "16:9": "Landscape 16:9", "9:16": "Portrait 9:16", "1:1": "Square 1:1", "4:5": "Portrait 4:5" } as Record<string, string>)[a] ?? a;
export const aspectShortTitle = (a: string) => (a === "original" ? "Original" : a);
export const aspectValue = (a: string): number | null => ({ "16:9": 16 / 9, "9:16": 9 / 16, "1:1": 1, "4:5": 4 / 5 } as Record<string, number>)[a] ?? null;

export const SPEED_OPTIONS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4] as const;
export const FREEZE_OPTIONS = [1, 2, 3, 5, 10] as const;

export interface EditorDocument {
  clips: CompositionClip[];
  selectedClipID: UUID;
  aspectRatio: AspectRatio | string;
  /** Deferred until closing so background sync cannot destroy undoable events. */
  deletedEventIDs: readonly UUID[];
}

export const clipsEqual = (a: readonly CompositionClip[], b: readonly CompositionClip[]) => JSON.stringify(a) === JSON.stringify(b);

export function splitClip(clips: readonly CompositionClip[], clipID: UUID, sourceTime: number): { clips: CompositionClip[]; trailingID: UUID } | null {
  const index = clips.findIndex((c) => c.id === clipID);
  const source = clips[index];
  if (!source || source.freezeDuration != null) return null;
  if (!(sourceTime > source.startSeconds + 0.1 && sourceTime < source.endSeconds - 0.1)) return null;
  const leading = { ...source, id: newId(), endSeconds: sourceTime };
  const trailing = { ...source, id: newId(), startSeconds: sourceTime };
  return { clips: [...clips.slice(0, index), leading, trailing, ...clips.slice(index + 1)], trailingID: trailing.id };
}

export const canSplit = (clip: CompositionClip | undefined, sourceTime: number) =>
  !!clip && clip.freezeDuration == null && sourceTime > clip.startSeconds + 0.1 && sourceTime < clip.endSeconds - 0.1;

/** Source time of the selected clip at an output position. */
export function sourceTimeOf(clips: readonly CompositionClip[], clipID: UUID, outputTime: number): number | null {
  const segment = segmentsForClips(clips).find((s) => s.id === clipID);
  return segment ? sourceTimeAt(segment, outputTime) : null;
}

export function reorderClip(clips: readonly CompositionClip[], clipID: UUID, destination: number): CompositionClip[] | null {
  const source = clips.findIndex((c) => c.id === clipID);
  if (source < 0 || source === destination) return null;
  const next = [...clips];
  const [moved] = next.splice(source, 1);
  next.splice(Math.min(next.length, Math.max(0, destination)), 0, moved!);
  return next;
}

export function removeClip(clips: readonly CompositionClip[], clipID: UUID): { clips: CompositionClip[]; selectedClipID: UUID } | null {
  const index = clips.findIndex((c) => c.id === clipID);
  if (index < 0 || clips.length <= 1) return null;
  const next = clips.filter((c) => c.id !== clipID);
  return { clips: next, selectedClipID: next[Math.min(index, next.length - 1)]!.id };
}

export function setClipRate(clips: readonly CompositionClip[], clipID: UUID, rate: number): CompositionClip[] | null {
  const clamped = clampRate(rate);
  const clip = clips.find((c) => c.id === clipID);
  if (!clip || Math.abs(clip.rate - clamped) <= 0.001) return null;
  return clips.map((c) => (c.id === clipID ? { ...c, rate: clamped } : c));
}

export function setFreezeDuration(clips: readonly CompositionClip[], clipID: UUID, duration: number): CompositionClip[] | null {
  const clip = clips.find((c) => c.id === clipID);
  if (!clip || clip.freezeDuration == null || clip.freezeDuration === duration) return null;
  return clips.map((c) => (c.id === clipID ? { ...c, freezeDuration: Math.max(0.1, duration) } : c));
}

export function trimClip(clips: readonly CompositionClip[], clipID: UUID, startSeconds: number, endSeconds: number): CompositionClip[] | null {
  const clip = clips.find((c) => c.id === clipID);
  if (!clip || (clip.startSeconds === startSeconds && clip.endSeconds === endSeconds)) return null;
  return clips.map((c) => (c.id === clipID ? { ...c, startSeconds, endSeconds } : c));
}

/** Insert a held frame at `sourceTime`, splitting the parent so playback resumes after the hold. */
export function insertFreezeFrame(clips: readonly CompositionClip[], clipID: UUID, sourceTime: number, holdSeconds = 5, recordingDuration = Number.POSITIVE_INFINITY): { clips: CompositionClip[]; frozenID: UUID } | null {
  const index = clips.findIndex((c) => c.id === clipID);
  const original = clips[index];
  if (!original || original.freezeDuration != null) return null;
  const seconds = Math.min(sourceTime, Math.max(original.startSeconds, original.endSeconds - 1 / 60));
  const frozen: CompositionClip = { ...original, id: newId(), startSeconds: seconds, endSeconds: Math.min(recordingDuration, seconds + 1 / 60), rate: 1, annotations: [], freezeDuration: holdSeconds };
  const replacement: CompositionClip[] = [];
  if (seconds > original.startSeconds + 0.01) replacement.push({ ...original, id: newId(), endSeconds: seconds });
  replacement.push(frozen);
  if (seconds < original.endSeconds - 0.01) replacement.push({ ...original, id: newId(), startSeconds: seconds });
  return { clips: [...clips.slice(0, index), ...replacement, ...clips.slice(index + 1)], frozenID: frozen.id };
}

/** Repeat a clip right after itself. */
export function duplicateClip(clips: readonly CompositionClip[], clipID: UUID): { clips: CompositionClip[]; copyID: UUID } | null {
  const index = clips.findIndex((c) => c.id === clipID);
  const source = clips[index];
  if (!source) return null;
  const copy = { ...source, id: newId() };
  return { clips: [...clips.slice(0, index + 1), copy, ...clips.slice(index + 1)], copyID: copy.id };
}

export function insertClips(clips: readonly CompositionClip[], additions: readonly CompositionClip[], atStart: boolean): CompositionClip[] {
  return atStart ? [...additions, ...clips] : [...clips, ...additions];
}

export interface EditHistory { undo: EditorDocument[]; redo: EditorDocument[] }
export const HISTORY_LIMIT = 20;

export function recordHistory(history: EditHistory, current: EditorDocument): EditHistory {
  const undo = [...history.undo, current];
  return { undo: undo.length > HISTORY_LIMIT ? undo.slice(undo.length - HISTORY_LIMIT) : undo, redo: [] };
}

export function undoHistory(history: EditHistory, current: EditorDocument): { history: EditHistory; document: EditorDocument } | null {
  const snapshot = history.undo[history.undo.length - 1];
  if (!snapshot) return null;
  return { history: { undo: history.undo.slice(0, -1), redo: [...history.redo, current] }, document: snapshot };
}

export function redoHistory(history: EditHistory, current: EditorDocument): { history: EditHistory; document: EditorDocument } | null {
  const snapshot = history.redo[history.redo.length - 1];
  if (!snapshot) return null;
  return { history: { undo: [...history.undo, current], redo: history.redo.slice(0, -1) }, document: snapshot };
}

/** Apply an edit to a saved composition. Rendered media is invalidated only when footage,
 *  order, speed, holds or crop change; renaming keeps the upload. */
export function compositionWithEdit(saved: VideoComposition, clips: readonly CompositionClip[], aspectRatio: string, name: string): VideoComposition {
  const mediaChanged = !clipsEqual(saved.clips, clips) || saved.aspectRatio !== aspectRatio;
  return {
    ...saved,
    clips: [...clips],
    aspectRatio,
    name,
    ...(mediaChanged ? { uploadState: "local" as const, uploadedBytes: 0, shareURL: null } : {}),
  };
}
