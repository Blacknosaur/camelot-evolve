import type { CSSProperties, ReactNode } from "react";
import type { Recording } from "@/domain";
import { useThumbnail } from "@/media/thumbnails";
import { Icon } from "@/design/icons";
import "./VideoThumbnail.css";

/** Port of VideoThumbnailView: tinted gradient placeholder with a play glyph until the frame decodes. */
export function VideoThumbnail({ recording, seconds, icon, tint = "var(--brand)", className = "", children }: { recording: Recording | null | undefined; seconds: number; icon?: ReactNode; tint?: string; className?: string; children?: ReactNode }) {
  const url = useThumbnail(recording ?? undefined, seconds);
  return (
    <div className={`vt ${className}`} style={{ "--tint": tint } as CSSProperties} aria-hidden="true">
      {url ? <img className="vt-image" src={url} alt="" draggable={false} /> : <span className="vt-placeholder">{icon ?? <Icon.Play />}</span>}
      <span className="vt-badge">{icon ?? <Icon.Play />}</span>
      {children}
    </div>
  );
}
