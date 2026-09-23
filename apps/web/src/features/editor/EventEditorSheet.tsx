import { useState } from "react";
import { EVENT_COLORS, EVENT_KINDS, defaultPostRoll, defaultPreRoll, eventTint, newId, now, type EventKind, type MatchEvent, type Recording } from "@/domain";
import { Button } from "@/design/components";
import { Icon } from "@/design/icons";
import { Sheet } from "./Sheet";
import { eventKindIcon } from "./icons";
import { timelineTimecode } from "./model/geometry";

export type EventEditorTarget = { kind: "new"; seconds: number } | { kind: "existing"; event: MatchEvent };

/** Kind, note, colour, position and pre/post roll for one event. Port of EventEditorSheet. */
export function EventEditorSheet({ recording, target, onSave, onDelete, onClose }: { recording: Recording; target: EventEditorTarget; onSave: (event: MatchEvent) => Promise<void>; onDelete: (event: MatchEvent) => void; onClose: () => void }) {
  const existing = target.kind === "existing" ? target.event : null;
  const initialOffset = existing ? existing.offsetSeconds : target.kind === "new" ? target.seconds : 0;
  const initialKind = (existing && EVENT_KINDS.includes(existing.kind as EventKind) ? existing.kind : existing ? "Note" : "Goal") as EventKind;
  const hasContext = !!existing && existing.contextRecordingIDs.length > 0;
  const maximumPreRoll = (offset: number) => (hasContext && existing ? Math.max(120, existing.preRollSeconds) : offset);
  const [kind, setKind] = useState<EventKind>(initialKind);
  const [note, setNote] = useState(existing?.note ?? "");
  const [colorHex, setColorHex] = useState(existing?.colorHex ?? "");
  const [offset, setOffset] = useState(initialOffset);
  const [preRoll, setPreRoll] = useState(existing ? (hasContext ? existing.preRollSeconds : Math.min(existing.offsetSeconds, existing.preRollSeconds)) : Math.min(Math.max(0, initialOffset), defaultPreRoll(initialKind)));
  const [postRoll, setPostRoll] = useState(existing ? Math.min(Math.max(0, recording.duration - existing.offsetSeconds), existing.postRollSeconds) : Math.min(Math.max(0, recording.duration - initialOffset), defaultPostRoll(initialKind)));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const changeKind = (next: EventKind) => {
    if (preRoll === Math.min(maximumPreRoll(offset), defaultPreRoll(kind)) && postRoll === Math.min(recording.duration - offset, defaultPostRoll(kind))) {
      setPreRoll(Math.min(maximumPreRoll(offset), defaultPreRoll(next)));
      setPostRoll(Math.min(Math.max(0, recording.duration - offset), defaultPostRoll(next)));
    }
    setKind(next);
  };
  const changeOffset = (value: number) => {
    const next = Math.max(0, Math.min(recording.duration, value));
    setOffset(next);
    setPreRoll((p) => Math.min(maximumPreRoll(next), p));
    setPostRoll((p) => Math.min(Math.max(0, recording.duration - next), p));
  };

  const save = async () => {
    const safeOffset = Math.max(0, Math.min(recording.duration, offset));
    const base: MatchEvent = existing ?? { id: newId(), projectID: recording.projectID, kind, note: "", occurredAt: now(), recordingID: recording.id, offsetSeconds: safeOffset, preRollSeconds: 0, postRollSeconds: 0, colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId() };
    const occurredAt = new Date(new Date(recording.recordedAt || recording.createdAt).getTime() + safeOffset * 1000).toISOString();
    try {
      await onSave({ ...base, kind, note, colorHex, offsetSeconds: safeOffset, occurredAt, preRollSeconds: Math.max(0, Math.min(maximumPreRoll(safeOffset), preRoll)), postRollSeconds: Math.max(0, Math.min(recording.duration - safeOffset, postRoll)) });
      onClose();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  return (
    <Sheet title={existing ? "Edit event" : "Add event"} onClose={onClose} trailing={<Button variant="pill-prominent" onClick={save}>Save</Button>}>
      <section className="ed-form-section">
        <h3>Event</h3>
        <div className="ed-kind-grid">
          {EVENT_KINDS.map((k) => <button key={k} type="button" className="ed-kind" data-active={kind === k || undefined} onClick={() => changeKind(k)}>{eventKindIcon(k)}<span>{k}</span></button>)}
        </div>
        <textarea className="ed-input" placeholder="Note (optional)" value={note} rows={2} onChange={(e) => setNote(e.target.value)} />
      </section>
      <section className="ed-form-section">
        <h3>Color</h3>
        <div className="ed-color-grid">
          {EVENT_COLORS.map((color) => (
            <button key={color.id} type="button" className="ed-color" aria-label={`${color.title} event color`} aria-pressed={colorHex === color.id} onClick={() => setColorHex(color.id)}>
              <span className="ed-swatch" style={{ background: eventTint(color.id, kind) }}>{colorHex === color.id && <Icon.Check />}</span>
              <span>{color.title}</span>
            </button>
          ))}
        </div>
      </section>
      <section className="ed-form-section">
        <h3>Position</h3>
        <div className="ed-position">
          <button type="button" className="ed-action" aria-label="Move event one second earlier" onClick={() => changeOffset(offset - 1)}>−1s</button>
          <span className="mono ed-position-value">{timelineTimecode(offset)}</span>
          <button type="button" className="ed-action" aria-label="Move event one second later" onClick={() => changeOffset(offset + 1)}>+1s</button>
        </div>
        <input type="range" min={0} max={Math.max(0.1, recording.duration)} step={0.1} value={offset} aria-label="Event position" onChange={(e) => changeOffset(Number(e.target.value))} />
        <label className="ed-stepper"><span>Before event</span><input type="number" min={0} max={Math.max(0, maximumPreRoll(offset))} step={0.5} value={preRoll} onChange={(e) => setPreRoll(Math.max(0, Math.min(maximumPreRoll(offset), Number(e.target.value) || 0)))} /><span>s</span></label>
        <label className="ed-stepper"><span>After event</span><input type="number" min={0} max={Math.max(0, recording.duration - offset)} step={0.5} value={postRoll} onChange={(e) => setPostRoll(Math.max(0, Math.min(recording.duration - offset, Number(e.target.value) || 0)))} /><span>s</span></label>
        <p className="ed-dim ed-footnote">Drag the edges of the event bar on the timeline to change the window.</p>
      </section>
      {existing && (
        <section className="ed-form-section">
          {confirmDelete
            ? <div className="ed-confirm"><span>Delete this event?</span><Button variant="destructive" onClick={() => { onDelete(existing); onClose(); }}>Delete event</Button><Button variant="pill" onClick={() => setConfirmDelete(false)}>Cancel</Button></div>
            : <Button variant="destructive" onClick={() => setConfirmDelete(true)}><Icon.Trash /> Delete event</Button>}
        </section>
      )}
      {error && <p className="ed-error" role="alert">Could not save event: {error}</p>}
    </Sheet>
  );
}
