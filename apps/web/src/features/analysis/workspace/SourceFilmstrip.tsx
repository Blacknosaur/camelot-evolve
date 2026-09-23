import { useEffect, useState } from "react";
import { requestThumbnailURL } from "@/media/thumbnails";

/* Only visible source tiles are decoded; stable time buckets reuse the editor's thumbnail cache
   while the playhead scrolls (port of AnalysisSourceFilmstrip.swift). */
export function SourceFilmstrip({ recordingID, bounds, visibleStart, scale, width, freezeTime, height }: { recordingID: string; bounds: [number, number]; visibleStart: number; scale: number; width: number; freezeTime: number | null; height: number }) {
  const [lower, upper] = bounds;
  const interval = Math.max(0.25, Math.ceil((80 / Math.max(0.01, scale)) * 4) / 4);
  const first = Math.max(0, Math.floor((visibleStart - lower) / interval));
  const last = Math.max(first, Math.min(Math.ceil((upper - lower) / interval), Math.ceil((visibleStart + width / Math.max(0.01, scale) - lower) / interval)));
  const tiles = Array.from({ length: Math.max(0, Math.min(last, first + 32) - first) }, (_, i) => first + i);
  return (
    <div style={{ position: "relative", width, height }} aria-label="Source video frames" data-testid="analysis-source-filmstrip">
      {tiles.map((index) => {
        const start = lower + index * interval, end = Math.min(upper, start + interval);
        return <Thumbnail key={index} recordingID={recordingID} time={freezeTime ?? Math.min(upper - 1 / 30, start)} left={(start - visibleStart) * scale} width={Math.max(1, (end - start) * scale)} height={height} />;
      })}
    </div>
  );
}

function Thumbnail({ recordingID, time, left, width, height }: { recordingID: string; time: number; left: number; width: number; height: number }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    requestThumbnailURL(recordingID, Math.max(0, time), 100).then((result) => { if (!cancelled) setUrl(result); }).catch(() => {});
    return () => { cancelled = true; };
  }, [recordingID, time]);
  return url ? <img src={url} alt="" draggable={false} style={{ left, width, height }} /> : <div style={{ position: "absolute", left, width, height, background: "rgb(255 255 255 / 0.06)" }} />;
}
