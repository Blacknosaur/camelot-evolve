import { useCallback } from "react";
import type { MatchEvent, Recording, VideoComposition } from "@/domain";
import { useLiveQuery } from "@/storage/live";
import { mediaStore } from "@/storage/media-store";
import { compositions, events, recordings } from "@/storage/repository";

/* One live query per project for the records the library screens need, plus which recordings
   actually have bytes in the media store (the web counterpart of `FileManager.fileExists`). */

export interface ProjectMedia {
  recordings: Recording[];
  compositions: VideoComposition[];
  events: MatchEvent[];
  /** Local file size by recording ID; absent when the bytes are missing. */
  localBytes: Record<string, number>;
}

const EMPTY: ProjectMedia = { recordings: [], compositions: [], events: [], localBytes: {} };
const byNewest = <T extends { createdAt: string }>(a: T, b: T) => b.createdAt.localeCompare(a.createdAt);

export async function loadProjectMedia(projectID: string): Promise<ProjectMedia> {
  const [videos, edits, tagged] = await Promise.all([recordings.forProject(projectID), compositions.forProject(projectID), events.forProject(projectID)]);
  const store = await mediaStore();
  const localBytes: Record<string, number> = {};
  await Promise.all(videos.map(async (video) => {
    if (!video.localPath) return;
    const file = await store.read("Recordings", video.localPath);
    if (file) localBytes[video.id] = file.size;
  }));
  return {
    recordings: videos.filter((v) => !v.pendingDeletion).sort(byNewest),
    compositions: edits.filter((v) => !v.pendingDeletion).sort(byNewest),
    events: tagged.filter((e) => !e.pendingDeletion).sort((a, b) => a.offsetSeconds - b.offsetSeconds),
    localBytes,
  };
}

export function useProjectMedia(projectID: string | undefined) {
  const query = useLiveQuery(() => (projectID ? loadProjectMedia(projectID) : Promise.resolve(EMPTY)), ["recordings", "compositions", "events", "media"], [projectID]);
  const media = query.data ?? EMPTY;
  const hasLocalVideo = useCallback((recording: Recording) => recording.id in media.localBytes, [media.localBytes]);
  return { ...media, isLoading: query.isLoading, hasLocalVideo, refresh: query.refresh };
}
