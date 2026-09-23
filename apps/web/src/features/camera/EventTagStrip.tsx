import type { ReactNode } from "react";
import { EVENT_KINDS, eventKindTint, type EventKind } from "@/domain";
import { Icon } from "@/design/icons";

/* Port of EventTagStrip.swift: one row of event targets with counts and a brief checkmark
   acknowledgement on the last tagged kind. Lives in the camera feature; the editor owns its own copy. */

export const eventKindIcon: Record<EventKind, ReactNode> = {
  Goal: <Icon.Ball />, Shot: <Icon.Scope />, Save: <Icon.Hand />, Foul: <Icon.Warning />, Card: <Icon.CardIcon />, Note: <Icon.Note />,
};

export function EventTagStrip({ counts, lastTag, isEnabled, prefix, mark }: { counts: Partial<Record<EventKind, number>>; lastTag: EventKind | null; isEnabled: boolean; prefix: string; mark: (kind: EventKind) => void }) {
  return (
    <div className="cam-tags" role="group" aria-label="Event targets">
      {EVENT_KINDS.map((kind) => {
        const count = counts[kind] ?? 0, acknowledged = lastTag === kind;
        return (
          <button key={kind} type="button" className="cam-tag" data-acknowledged={acknowledged || undefined} disabled={!isEnabled} onClick={() => mark(kind)}
            aria-label={`Tag ${kind.toLowerCase()}`} aria-description={`${count} marked`} data-testid={`${prefix}-tag-${kind.toLowerCase()}`}>
            <span className="cam-tag-top">
              <span className="cam-tag-icon" style={{ color: acknowledged ? "#000" : eventKindTint(kind) }}>{acknowledged ? <Icon.Check /> : eventKindIcon[kind]}</span>
              {count > 0 && <span className="cam-tag-count mono">{count}</span>}
            </span>
            <span className="cam-tag-title">{kind}</span>
          </button>
        );
      })}
    </div>
  );
}
