import { useEffect, useState, type CSSProperties } from "react";
import type { MatchEvent, Recording } from "@/domain";
import { EVENT_COLORS, EVENT_KINDS, eventTint } from "@/domain";
import { events } from "@/storage/repository";
import { compactDuration } from "@/design/format";
import { Button, ListGroup, ListRow } from "@/design/components";
import { Icon, type IconName } from "@/design/icons";
import { ConfirmDialog, Sheet } from "@/design/sheet";
import "./EventForm.css";

const EVENT_ICONS: Record<string, IconName> = { Goal: "Ball", Shot: "Scope", Save: "Hand", Foul: "Warning", Card: "CardIcon", Note: "Note" };
/** SF-symbol equivalent for an event kind (port of `EventKind.symbol`). */
export function eventIcon(kind: string) { const Glyph = Icon[EVENT_ICONS[kind] ?? "Flag"]; return <Glyph />; }

/** Edit an event's kind, colour and note, or delete it. Times are edited in the recording editor. */
export function EventForm({ event, recording, open, onClose }: { event: MatchEvent | null; recording: Recording | undefined; open: boolean; onClose: () => void }) {
  const [kind, setKind] = useState("Goal");
  const [colorHex, setColorHex] = useState("");
  const [note, setNote] = useState("");
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  useEffect(() => {
    if (!open || !event) return;
    setKind(event.kind); setColorHex(event.colorHex); setNote(event.note);
  }, [open, event]);

  const save = async () => {
    if (!event) return;
    await events.save({ ...event, kind, colorHex, note: note.trim() });
    onClose();
  };
  const remove = async () => {
    if (!event) return;
    await events.delete(event.id);
    onClose();
  };

  const tint = eventTint(colorHex, kind);
  return (
    <Sheet open={open} onClose={onClose} title="Edit event" detent="large" trailing={<Button variant="plain" onClick={save}><strong>Save</strong></Button>}>
      {event && (
        <div className="ef">
          <div className="ef-summary" style={{ "--tint": tint } as CSSProperties}>
            <span className="ef-summary-icon">{eventIcon(kind)}</span>
            <div>
              <div className="ef-summary-title">{kind} · {compactDuration(event.offsetSeconds)}</div>
              <div className="ef-summary-subtitle">{recording ? (recording.name || "Recording") : "Not attached to a video"}</div>
            </div>
          </div>
          <ListGroup header="Type">
            <div className="ef-kinds" role="radiogroup" aria-label="Event type">
              {EVENT_KINDS.map((option) => (
                <button key={option} type="button" role="radio" aria-checked={kind === option} className="ef-kind" style={{ "--tint": eventTint("", option) } as CSSProperties} onClick={() => setKind(option)}>
                  {eventIcon(option)}<span>{option}</span>
                </button>
              ))}
            </div>
          </ListGroup>
          <ListGroup header="Colour">
            <div className="ef-colors" role="radiogroup" aria-label="Event colour">
              {EVENT_COLORS.map((option) => (
                <button key={option.id} type="button" role="radio" aria-checked={colorHex === option.id} className="ef-color" title={option.title} aria-label={option.title} style={{ "--tint": option.id ? `#${option.id}` : eventTint("", kind) } as CSSProperties} onClick={() => setColorHex(option.id)}>
                  <span className="ef-color-dot">{option.id === "" && <Icon.Sparkles />}</span>
                </button>
              ))}
            </div>
          </ListGroup>
          <ListGroup header="Note">
            <ListRow><textarea className="ef-note" rows={3} placeholder="Add a note" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Note" /></ListRow>
          </ListGroup>
          <ListGroup footer="Use the recording editor to move the event in time.">
            <ListRow label="Delete event" destructive onClick={() => setConfirmingDelete(true)} />
          </ListGroup>
        </div>
      )}
      <ConfirmDialog open={confirmingDelete} onClose={() => setConfirmingDelete(false)} title="Delete this event?" message="The event is removed from every synced device. The video is not affected." confirmLabel="Delete event" onConfirm={() => void remove()} />
    </Sheet>
  );
}
