import { thumbnailStrip } from "@/media/thumbnails";
import type { Recording, UUID } from "@/domain";

export type ThumbnailImage = ImageBitmap | HTMLImageElement;

export interface StripSample { outputSeconds: number; recordingID: UUID; sourceSeconds: number }

/** Requests visible strip frames grouped per recording; results arrive keyed by output seconds.
 *  Later generations ignore stale deliveries so a fast fling never paints old frames. */
export function requestStrip(samples: readonly StripSample[], recordings: ReadonlyMap<UUID, Recording>, height: number, deliver: (outputSeconds: number, image: ThumbnailImage) => void): () => void {
  let cancelled = false;
  const byRecording = new Map<UUID, StripSample[]>();
  for (const sample of samples) byRecording.set(sample.recordingID, [...(byRecording.get(sample.recordingID) ?? []), sample]);
  for (const [recordingID, list] of byRecording) {
    const recording = recordings.get(recordingID);
    if (!recording?.localPath) continue;
    const times = list.map((s) => s.sourceSeconds);
    void thumbnailStrip(recordingID, times, height, (time, url, bitmap) => {
      if (cancelled) return;
      const targets = list.filter((s) => s.sourceSeconds === time);
      if (bitmap) { for (const t of targets) deliver(t.outputSeconds, bitmap); return; }
      if (!url) return;
      const image = new Image();
      image.onload = () => { if (!cancelled) for (const t of targets) deliver(t.outputSeconds, image); };
      image.src = url;
    }, recording.localPath).catch(() => { /* strip failures leave the band blank */ });
  }
  return () => { cancelled = true; };
}
