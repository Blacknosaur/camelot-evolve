import type { CompositionClip, MatchEvent, Recording, VideoComposition } from "@/domain";
import { clipPlaybackDuration } from "@/domain";
import type { IconName } from "@/design/icons";

/* Pure status/statistics helpers behind ProjectDetailView.swift. Kept outside React so tests can
   cover every branch of the status pills and deletion copy. */

export interface VideoStatus { text: string; tint: string; icon: IconName }

export interface RecordingAvailability {
  /** Bytes are present in the media store. */
  hasLocalVideo: boolean;
  /** Size in bytes of the local file, when known. */
  localBytes?: number;
}

/** A recording that was synced but whose bytes live only on the server. */
export function remoteMediaURL(record: Pick<Recording, "shareURL">): string | null {
  if (!record.shareURL) return null;
  try {
    const url = new URL(record.shareURL);
    url.pathname = url.pathname.replace("/api/watch/", "/api/public/media/");
    return url.toString();
  } catch { return null; }
}

export function recordingTitle(video: Pick<Recording, "name" | "recordedAt">, formatDate: (iso: string) => string): string {
  return video.name || formatDate(video.recordedAt);
}

export function recordingSubtitle(video: Pick<Recording, "name" | "recordedAt" | "endedReason">, formatDate: (iso: string) => string): string {
  if (video.name) return formatDate(video.recordedAt);
  return video.endedReason === "import" || video.endedReason === ("imported" as string) ? "Imported video" : "Recorded with Camelot";
}

export function uploadProgressLabel(uploadedBytes: number, totalBytes: number | undefined, prefix: string): string {
  if (uploadedBytes <= 0 || !totalBytes || totalBytes <= 0) return prefix;
  return `${prefix} ${Math.min(100, Math.round((uploadedBytes / totalBytes) * 100))}%`;
}

export function recordingStatus(video: Pick<Recording, "uploadState" | "uploadedBytes" | "localPath" | "shareURL">, availability: RecordingAvailability): VideoStatus {
  if (!availability.hasLocalVideo) {
    return remoteMediaURL(video)
      ? { text: "In the cloud", tint: "var(--fg-secondary)", icon: "Cloud" }
      : { text: "Unavailable", tint: "var(--destructive)", icon: "Warning" };
  }
  switch (video.uploadState as string) {
    case "uploaded": return { text: "Synced", tint: "var(--success)", icon: "CloudCheck" };
    case "uploading": return { text: uploadProgressLabel(video.uploadedBytes, availability.localBytes, "Uploading"), tint: "var(--brand)", icon: "CloudUp" };
    case "paused": case "failed": return { text: uploadProgressLabel(video.uploadedBytes, availability.localBytes, "Paused"), tint: "var(--warning)", icon: "PauseCircle" };
    default: return { text: "On device", tint: "var(--fg-secondary)", icon: "Phone" };
  }
}

export function compositionStatus(video: Pick<VideoComposition, "uploadState" | "uploadedBytes">, clipCount: number, exportBytes: number | null): VideoStatus {
  const clips = clipCount === 1 ? "1 clip" : `${clipCount} clips`;
  switch (video.uploadState as string) {
    case "uploaded": return { text: `Shared · ${clips}`, tint: "var(--success)", icon: "Link" };
    case "uploading": return { text: uploadProgressLabel(video.uploadedBytes, exportBytes ?? undefined, "Uploading"), tint: "var(--brand)", icon: "CloudUp" };
    case "paused": case "failed": return { text: `Waiting · ${clips}`, tint: "var(--warning)", icon: "PauseCircle" };
    default:
      return exportBytes == null
        ? { text: `Ready to render · ${clips}`, tint: "var(--fg-secondary)", icon: "Film" }
        : { text: `Rendered · ${clips}`, tint: "var(--fg-secondary)", icon: "Phone" };
  }
}

export interface CompositionStats {
  duration: number;
  eventCount: number;
  clipCount: number;
  /** Source recording and time used for the thumbnail when no export exists. */
  thumbnail: { recording: Recording | null; seconds: number };
}

export function compositionStats(video: Pick<VideoComposition, "clips">, events: readonly MatchEvent[], recordings: readonly Recording[], hasLocalVideo: (recording: Recording) => boolean): CompositionStats {
  const clips = video.clips;
  const duration = clips.reduce((total, clip) => total + clipPlaybackDuration(clip), 0);
  const eventCount = events.filter((event) => event.recordingID && clips.some((clip) => clip.recordingID === event.recordingID && event.offsetSeconds >= clip.startSeconds && event.offsetSeconds <= clip.endSeconds)).length;
  const available = recordings.filter(hasLocalVideo);
  const first = clips.find((clip) => available.some((r) => r.id === clip.recordingID));
  const source = first ? available.find((r) => r.id === first.recordingID) ?? null : null;
  const seconds = Math.min(Math.max(0, (first?.startSeconds ?? 0) + 0.25), Math.max(0, (source?.duration ?? 0) - 0.1));
  return { duration, eventCount, clipCount: clips.length, thumbnail: { recording: source, seconds } };
}

export const compositionUses = (composition: Pick<VideoComposition, "clips">, recordingID: string) => composition.clips.some((clip) => clip.recordingID === recordingID);

/** Every clip's source is on this device, so the edit can open in the editor. */
export function compositionIsEditable(clips: readonly CompositionClip[], recordings: readonly Recording[], hasLocalVideo: (recording: Recording) => boolean): boolean {
  return clips.length > 0 && clips.every((clip) => recordings.some((r) => r.id === clip.recordingID && hasLocalVideo(r)));
}

export function recordingDeletionMessage(dependentEdits: number): string {
  const suffix = dependentEdits === 0 ? "" : ` ${dependentEdits} video edit${dependentEdits === 1 ? "" : "s"} that use this video will also be removed.`;
  return `The original video and its events will be removed from every synced device.${suffix} This cannot be undone.`;
}

export const compositionDeletionMessage = "The video edit and its rendered file will be removed from every synced device. Original videos are not affected.";

export function eventCountForRecording(events: readonly MatchEvent[], recordingID: string): number {
  return events.filter((e) => e.recordingID === recordingID && !e.pendingDeletion).length;
}
