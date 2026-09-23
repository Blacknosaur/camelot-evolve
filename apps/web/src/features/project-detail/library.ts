import type { CompositionClip, MatchEvent, Project, Recording, VideoComposition } from "@/domain";
import { newId, now } from "@/domain";
import { deleteRecordingFiles } from "@/media/import";
import { mediaStore } from "@/storage/media-store";
import { publishChange } from "@/storage/live";
import { compositions, events, projects, recordings } from "@/storage/repository";
import { compositionUses } from "./video-status";

/* Port of RecordingLibrary.deleteVideo plus the composition presets the web library offers.
   Deletion removes records (the repository writes outbox `delete` entries, which is the web
   equivalent of iOS marking `pendingDeletion` for the sync engine) and then the media files. */

/** Exports are named `${compositionID}-${revision}.${ext}` (or just the ID); remove every match. */
async function deleteExportFiles(compositionID: string) {
  const store = await mediaStore();
  for (const key of await store.list("Exports")) if (key.startsWith(compositionID)) await store.delete("Exports", key);
}

/** Deletes a recording, its events, every edit that uses it, and the bytes on this device. */
export async function deleteRecording(recording: Recording): Promise<void> {
  const [tagged, edits] = await Promise.all([events.forRecording(recording.id), compositions.forProject(recording.projectID)]);
  for (const event of tagged) await events.delete(event.id);
  for (const edit of edits) if (compositionUses(edit, recording.id)) await deleteComposition(edit);
  await recordings.delete(recording.id);
  await deleteRecordingFiles(recording);
}

/** Deletes an edit and its rendered export. Source videos are kept. */
export async function deleteComposition(composition: VideoComposition): Promise<void> {
  await compositions.delete(composition.id);
  await deleteExportFiles(composition.id);
  publishChange("media");
}

/** Deletes a project and everything inside it. */
export async function deleteProject(projectID: string): Promise<void> {
  const [videos, edits, tagged] = await Promise.all([recordings.forProject(projectID), compositions.forProject(projectID), events.forProject(projectID)]);
  for (const edit of edits) await deleteComposition(edit);
  for (const event of tagged) await events.delete(event.id);
  for (const video of videos) { await recordings.delete(video.id); await deleteRecordingFiles(video); }
  await projects.delete(projectID);
}

export async function renameRecording(recording: Recording, name: string) { await recordings.save({ ...recording, name }); }
export async function renameComposition(composition: VideoComposition, name: string) { await compositions.save({ ...composition, name }); }

export type CompositionPreset = "full" | "goals" | "custom";

const fullClip = (recording: Recording): CompositionClip => ({ id: newId(), recordingID: recording.id, startSeconds: 0, endSeconds: Math.max(0, recording.duration), rate: 1, annotations: [] });

/** Clips for a preset. Recordings are oldest-first so a full match plays in order. */
export function presetClips(preset: CompositionPreset, recordings: readonly Recording[], events: readonly MatchEvent[]): CompositionClip[] {
  const ordered = [...recordings].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  if (preset === "full") return ordered.map(fullClip);
  if (preset === "goals") {
    return events
      .filter((event) => event.kind === "Goal" && event.recordingID)
      .sort((a, b) => a.offsetSeconds - b.offsetSeconds)
      .flatMap((event) => {
        const source = ordered.find((r) => r.id === event.recordingID);
        if (!source) return [];
        const start = Math.max(0, event.offsetSeconds - event.preRollSeconds);
        const end = Math.min(source.duration || Number.POSITIVE_INFINITY, event.offsetSeconds + event.postRollSeconds);
        return end > start ? [{ id: newId(), recordingID: source.id, startSeconds: start, endSeconds: end, rate: 1, annotations: [] }] : [];
      });
  }
  return ordered[0] ? [fullClip(ordered[0])] : [];
}

export const PRESET_TITLES: Record<CompositionPreset, string> = { full: "Full match", goals: "Goals summary", custom: "New edit" };

/** Creates and saves an edit for the project. Returns null when the preset produced no clips. */
export async function createComposition(project: Project, preset: CompositionPreset, recordings: readonly Recording[], events: readonly MatchEvent[]): Promise<VideoComposition | null> {
  const clips = presetClips(preset, recordings, events);
  if (clips.length === 0) return null;
  const composition: VideoComposition = {
    id: newId(), projectID: project.id, name: PRESET_TITLES[preset], kind: preset, createdAt: now(), clips, aspectRatio: "original",
    uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId(),
  };
  return compositions.save(composition);
}

/** Share a link with the Web Share API, falling back to the clipboard. Returns what happened for a toast. */
export async function shareLink(title: string, url: string): Promise<"shared" | "copied" | "failed"> {
  if (typeof navigator.share === "function") {
    try { await navigator.share({ title, url }); return "shared"; } catch (error) { if ((error as Error).name === "AbortError") return "shared"; }
  }
  try { await navigator.clipboard.writeText(url); return "copied"; } catch { return "failed"; }
}
