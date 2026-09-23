import { useEffect, useRef } from "react";
import { EVENT_KINDS, eventTint } from "@/domain";
import { Icon } from "@/design/icons";
import { EditorIcon, eventKindIcon } from "./icons";
import { eventIDKey, sameEventID, snapshotEnd, snapshotStart, timelineTimecode, type TimelineEventID } from "./model/geometry";
import { clipLabel, sequenceEventOffset, type SequenceEvent } from "./model/sequence";

export interface RangeDraft { eventID: TimelineEventID | null; start: number; end: number }

export interface EventBrowserProps {
  events: readonly SequenceEvent[];
  selectedID: TimelineEventID | null;
  draft: RangeDraft | null;
  search: string;
  kind: string | null;
  onSearch: (value: string) => void;
  onKind: (kind: string | null) => void;
  select: (event: SequenceEvent) => void;
  edit: (event: SequenceEvent) => void;
  remove: (event: SequenceEvent) => void;
}

export function filterEvents(events: readonly SequenceEvent[], search: string, kind: string | null): SequenceEvent[] {
  const needle = search.trim().toLowerCase();
  return events.filter((e) => (kind == null || e.event.kind === kind)
    && (!needle || e.event.kind.toLowerCase().includes(needle) || e.event.note.toLowerCase().includes(needle) || timelineTimecode(sequenceEventOffset(e), false).includes(needle)));
}

/** Event list of the assembled video: search, kind filter, select/edit/delete. Port of EditorEventBrowser. */
export function EventBrowser({ events, selectedID, draft, search, kind, onSearch, onKind, select, edit, remove }: EventBrowserProps) {
  const visible = filterEvents(events, search, kind);
  const listRef = useRef<HTMLDivElement>(null);
  const selectedKey = selectedID ? eventIDKey(selectedID) : null;
  useEffect(() => {
    if (!selectedKey) return;
    listRef.current?.querySelector<HTMLElement>(`[data-key="${selectedKey}"]`)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [selectedKey]);
  return (
    <div className="ed-browser">
      <div className="ed-search">
        <EditorIcon.Search />
        <input type="search" value={search} placeholder="Search events" aria-label="Search events" autoCorrect="off" autoCapitalize="none" onChange={(e) => onSearch(e.target.value)} />
        {search && <button type="button" className="ed-icon-button" aria-label="Clear event search" onClick={() => onSearch("")}><Icon.Close /></button>}
        <label className="ed-filter" data-active={kind != null || undefined}>
          <span>{kind ?? ""}</span><EditorIcon.Filter />
          <select value={kind ?? ""} aria-label="Filter events" onChange={(e) => onKind(e.target.value || null)}>
            <option value="">All types</option>
            {EVENT_KINDS.map((k) => <option key={k} value={k}>{k} ({events.filter((e) => e.event.kind === k).length})</option>)}
          </select>
        </label>
      </div>
      <div className="ed-browser-list" ref={listRef}>
        {visible.length === 0 && <p className="ed-browser-empty">{events.length === 0 ? "Find a moment in the video, then add an event." : "No matching events."}</p>}
        {visible.map((occurrence) => {
          const selected = sameEventID(selectedID, occurrence.snapshot.id);
          const tint = eventTint(occurrence.event.colorHex, occurrence.event.kind);
          const range = selected && draft && sameEventID(draft.eventID, occurrence.snapshot.id) ? draft : { start: snapshotStart(occurrence.snapshot), end: snapshotEnd(occurrence.snapshot) };
          return (
            <div key={eventIDKey(occurrence.snapshot.id)} data-key={eventIDKey(occurrence.snapshot.id)} className="ed-row" data-selected={selected || undefined} style={{ "--tint": tint } as React.CSSProperties}>
              <button type="button" className="ed-row-main" aria-pressed={selected} aria-label={`${occurrence.event.kind} at ${timelineTimecode(sequenceEventOffset(occurrence), false)}${occurrence.event.note ? `, ${occurrence.event.note}` : ""}`} onClick={() => select(occurrence)}>
                <span className="ed-row-icon">{eventKindIcon(occurrence.event.kind)}</span>
                <span className="ed-row-text">
                  <span className="ed-row-line"><span className="ed-row-kind">{occurrence.event.kind}</span><span className="mono ed-row-time">{timelineTimecode(sequenceEventOffset(occurrence))}</span></span>
                  <span className="ed-row-line ed-dim"><span className="mono">{timelineTimecode(range.start)} – {timelineTimecode(range.end)}</span><span>{clipLabel(occurrence)}</span></span>
                  {occurrence.event.note && <span className="ed-row-note">{occurrence.event.note}</span>}
                </span>
              </button>
              {selected && (
                <div className="ed-row-actions">
                  <button type="button" className="ed-action" aria-label="Edit selected event" onClick={() => edit(occurrence)}><EditorIcon.Sliders /> Edit</button>
                  <button type="button" className="ed-action" aria-label="Delete selected event" onClick={() => remove(occurrence)}><Icon.Trash /></button>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
