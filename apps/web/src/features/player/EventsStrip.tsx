import type { CSSProperties } from "react";
import { eventTint } from "@/domain";
import { eventKindIcon } from "@/features/editor/icons";
import { timelineTimecode, type TimelineEventSnapshot, snapshotEnd, snapshotStart } from "@/features/editor/model/geometry";

export interface StripEvent { snapshot: TimelineEventSnapshot; note: string; key: string }

/** Colour-coded event windows along the whole video plus tappable chips. */
export function EventsStrip({ events, duration, currentTime, onSeek }: { events: readonly StripEvent[]; duration: number; currentTime: number; onSeek: (seconds: number) => void }) {
  if (!events.length || duration <= 0) return null;
  return (
    <div className="pl-events" aria-label="Events">
      <div className="pl-events-bar" role="presentation">
        {events.map((e) => (
          <span key={e.key} style={{ "--tint": eventTint(e.snapshot.colorHex, e.snapshot.kind), left: `${(snapshotStart(e.snapshot) / duration) * 100}%`, width: `${Math.max(0.5, ((snapshotEnd(e.snapshot) - snapshotStart(e.snapshot)) / duration) * 100)}%` } as CSSProperties} />
        ))}
        <i style={{ left: `${Math.min(100, (currentTime / duration) * 100)}%` }} />
      </div>
      <div className="pl-chips">
        {events.map((e) => {
          const active = currentTime >= snapshotStart(e.snapshot) && currentTime <= snapshotEnd(e.snapshot);
          return (
            <button type="button" key={e.key} className="pl-chip" data-active={active || undefined} style={{ "--tint": eventTint(e.snapshot.colorHex, e.snapshot.kind) } as CSSProperties} onClick={() => onSeek(snapshotStart(e.snapshot))} aria-label={`${e.snapshot.kind} at ${timelineTimecode(e.snapshot.offset, false)}`}>
              {eventKindIcon(e.snapshot.kind)}<span>{e.snapshot.kind}</span><span className="mono">{timelineTimecode(e.snapshot.offset, false)}</span>{e.note && <span className="ed-dim">· {e.note}</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}
