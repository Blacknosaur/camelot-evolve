import type { MatchEvent, Project, Recording, VideoComposition } from "@/domain";
import { friendlyDate } from "@/design/format";

/* Pure helpers behind ProjectsView.swift (`ProjectSummary`, `Project.subtitle`, search filter). */

export interface ProjectPreview { recording: Recording | null; seconds: number }

export interface ProjectSummary {
  videoCount: number;
  highlightCount: number;
  eventCount: number;
  preview: ProjectPreview;
}

const byNewest = <T extends { createdAt: string }>(a: T, b: T) => b.createdAt.localeCompare(a.createdAt);

/** Counts and the preview frame for a project. `hasLocalVideo` says whether the bytes are on this device. */
export function projectSummary(videos: readonly Recording[], generated: readonly VideoComposition[], events: readonly MatchEvent[], hasLocalVideo: (recording: Recording) => boolean): ProjectSummary {
  const live = videos.filter((v) => !v.pendingDeletion).sort(byNewest);
  const edits = generated.filter((v) => !v.pendingDeletion).sort(byNewest);
  return {
    videoCount: live.length,
    highlightCount: edits.length,
    eventCount: events.filter((e) => !e.pendingDeletion).length,
    preview: projectPreview(live, edits, hasLocalVideo),
  };
}

/** Newest edit wins when it is more recent than the newest available video; otherwise the latest video at its midpoint (capped at 1s). */
export function projectPreview(videos: readonly Recording[], generated: readonly VideoComposition[], hasLocalVideo: (recording: Recording) => boolean): ProjectPreview {
  const available = videos.filter(hasLocalVideo);
  const newest = generated[0];
  if (newest && newest.createdAt > (available[0]?.createdAt ?? "")) {
    for (const clip of newest.clips) {
      const source = available.find((v) => v.id === clip.recordingID);
      if (source) return { recording: source, seconds: Math.min(Math.max(0, clip.startSeconds + 0.25), Math.max(0, source.duration - 0.1)) };
    }
  }
  const latest = available[0];
  if (latest) return { recording: latest, seconds: Math.min(1, Math.max(0, latest.duration / 2)) };
  return { recording: null, seconds: 0 };
}

/** "vs Rovers · Today, 14:30" or just the date for training sessions. */
export function projectSubtitle(project: Pick<Project, "opponent" | "scheduledAt">, now = new Date()): string {
  const date = friendlyDate(new Date(project.scheduledAt), now);
  return project.opponent ? `vs ${project.opponent} · ${date}` : date;
}

/** Case-insensitive match on name or opponent; blank queries return everything. */
export function filterProjects<T extends Pick<Project, "name" | "opponent">>(projects: readonly T[], query: string): T[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [...projects];
  return projects.filter((p) => p.name.toLowerCase().includes(needle) || p.opponent.toLowerCase().includes(needle));
}

/** Newest scheduled first, matching `@Query(sort: \.scheduledAt, order: .reverse)`. */
export function sortProjects<T extends Pick<Project, "scheduledAt">>(projects: readonly T[]): T[] {
  return [...projects].sort((a, b) => b.scheduledAt.localeCompare(a.scheduledAt));
}

/** Datetime-local input value for a date ("2026-09-17T14:30"). */
export function toDateTimeLocal(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
