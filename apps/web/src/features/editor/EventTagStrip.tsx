import { EVENT_KINDS, eventKindTint, type EventKind } from "@/domain";
import { Icon } from "@/design/icons";
import { eventKindIcon } from "./icons";

/** Compact row of event buttons that tag at the playhead without pausing. Port of EventTagStrip. */
export function EventTagStrip({ counts, lastTag, isEnabled = true, mark }: { counts: Partial<Record<EventKind, number>>; lastTag: EventKind | null; isEnabled?: boolean; mark: (kind: EventKind) => void }) {
  return (
    <div className="ed-tag-strip" role="group" aria-label="Tag event at playhead">
      {EVENT_KINDS.map((kind) => {
        const active = lastTag === kind;
        const count = counts[kind] ?? 0;
        return (
          <button type="button" key={kind} className="ed-tag" data-active={active || undefined} disabled={!isEnabled} onClick={() => mark(kind)} aria-label={`Tag ${kind.toLowerCase()}`} style={{ "--tint": eventKindTint(kind) } as React.CSSProperties}>
            <span className="ed-tag-icon">{active ? <Icon.Check /> : eventKindIcon(kind)}{count > 0 && <small className="mono">{count}</small>}</span>
            <span>{kind}</span>
          </button>
        );
      })}
    </div>
  );
}
