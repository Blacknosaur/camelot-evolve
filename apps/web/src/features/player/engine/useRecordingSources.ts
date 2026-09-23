import { useEffect, useState } from "react";
import type { Recording, UUID } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import type { SequenceSource } from "./sequence-player";

export interface RecordingSources {
  sources: SequenceSource[];
  /** Recordings whose file is not in the media store. */
  missing: UUID[];
  isLoading: boolean;
}

/** Resolves object URLs for recordings and revokes them when the set changes or the screen closes. */
export function useRecordingSources(recordings: readonly Recording[] | undefined): RecordingSources {
  const [result, setResult] = useState<RecordingSources>({ sources: [], missing: [], isLoading: true });
  const key = (recordings ?? []).map((r) => `${r.id}:${r.localPath}`).join("|");
  useEffect(() => {
    let cancelled = false;
    const urls: string[] = [];
    (async () => {
      const store = await mediaStore();
      const sources: SequenceSource[] = [];
      const missing: UUID[] = [];
      for (const recording of recordings ?? []) {
        const url = recording.localPath ? await store.url("Recordings", recording.localPath) : null;
        if (!url) { missing.push(recording.id); continue; }
        urls.push(url);
        sources.push({ recordingID: recording.id, url, duration: recording.duration, width: recording.width, height: recording.height });
      }
      if (cancelled) urls.forEach((u) => URL.revokeObjectURL(u));
      else setResult({ sources, missing, isLoading: false });
    })();
    return () => { cancelled = true; urls.forEach((u) => URL.revokeObjectURL(u)); };
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps
  return result;
}
