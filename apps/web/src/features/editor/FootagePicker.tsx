import { useState } from "react";
import { eventTint, type MatchEvent, type Recording } from "@/domain";
import { useThumbnail } from "@/media/thumbnails";
import { Icon } from "@/design/icons";
import { compactDuration, friendlyDate } from "@/design/format";
import { Sheet } from "./Sheet";
import { EditorIcon, eventKindIcon } from "./icons";
import { timelineTimecode } from "./model/geometry";

export type FootageChoice = { kind: "full"; recording: Recording } | { kind: "range"; recording: Recording } | { kind: "event"; recording: Recording; event: MatchEvent };

/** Add footage: a full recording, a custom range, or an event window. Port of ClipPickerSheet/ClipSourcePicker. */
export function FootagePicker({ recordings, events, onChoose, onClose }: { recordings: readonly Recording[]; events: readonly MatchEvent[]; onChoose: (choice: FootageChoice) => void; onClose: () => void }) {
  const [recording, setRecording] = useState<Recording | null>(recordings.length === 1 ? recordings[0]! : null);
  const [search, setSearch] = useState("");
  if (!recording) {
    return (
      <Sheet title="Add a video" onClose={onClose}>
        {recordings.length === 0 && <p className="ed-dim">No recordings in this project yet.</p>}
        <ul className="ed-list">
          {recordings.map((r) => <li key={r.id}><RecordingRow recording={r} onClick={() => setRecording(r)} /></li>)}
        </ul>
      </Sheet>
    );
  }
  const own = events.filter((e) => e.recordingID === recording.id);
  const needle = search.trim().toLowerCase();
  const filtered = own.filter((e) => !needle || e.kind.toLowerCase().includes(needle) || e.note.toLowerCase().includes(needle));
  return (
    <Sheet title="Use footage" onClose={onClose} trailing={recordings.length > 1 ? <button type="button" className="ed-action" onClick={() => setRecording(null)}><Icon.ChevronLeft /> Videos</button> : undefined}>
      <ul className="ed-list">
        <li><button type="button" className="ed-list-row" onClick={() => onChoose({ kind: "full", recording })}><Icon.Film /><span>Full video · {compactDuration(recording.duration)}</span></button></li>
        <li><button type="button" className="ed-list-row" onClick={() => onChoose({ kind: "range", recording })}><Icon.Scissors /><span>Choose a clip range</span></button></li>
      </ul>
      {own.length > 0 && (
        <>
          <div className="ed-search"><EditorIcon.Search /><input type="search" placeholder="Search events" aria-label="Search events" value={search} onChange={(e) => setSearch(e.target.value)} /></div>
          <h3 className="ed-list-title">Events · {filtered.length}</h3>
          <ul className="ed-list">
            {filtered.map((event) => (
              <li key={event.id}>
                <button type="button" className="ed-list-row" onClick={() => onChoose({ kind: "event", recording, event })} style={{ "--tint": eventTint(event.colorHex, event.kind) } as React.CSSProperties}>
                  <span className="ed-row-icon">{eventKindIcon(event.kind)}</span>
                  <span className="ed-row-text">
                    <span className="ed-row-kind">{event.kind}</span>
                    {event.note && <span className="ed-row-note">{event.note}</span>}
                    <span className="mono ed-dim">{timelineTimecode(Math.max(0, event.offsetSeconds - event.preRollSeconds))} – {timelineTimecode(Math.min(recording.duration, event.offsetSeconds + event.postRollSeconds))}</span>
                  </span>
                  <Icon.Plus />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </Sheet>
  );
}

function RecordingRow({ recording, onClick }: { recording: Recording; onClick: () => void }) {
  const thumbnail = useThumbnail(recording, Math.min(1, recording.duration / 2), 92);
  return (
    <button type="button" className="ed-list-row" onClick={onClick}>
      <span className="ed-thumb">{thumbnail ? <img src={thumbnail} alt="" /> : <Icon.Video />}</span>
      <span className="ed-row-text">
        <span className="ed-row-kind">{recording.name || friendlyDate(new Date(recording.recordedAt || recording.createdAt))}</span>
        <span className="ed-dim mono">{compactDuration(recording.duration)}</span>
      </span>
      <Icon.ChevronRight />
    </button>
  );
}
