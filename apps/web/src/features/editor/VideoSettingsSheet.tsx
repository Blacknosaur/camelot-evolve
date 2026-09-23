import { useState } from "react";
import { Button } from "@/design/components";
import { Icon } from "@/design/icons";
import { Sheet } from "./Sheet";
import { ASPECT_RATIOS, aspectTitle } from "./model/edits";

/** Title, aspect ratio and deletion for the edit. Port of EditorVideoSettingsSheet. */
export function VideoSettingsSheet({ title, aspect, deletionMessage, onSave, onDelete, onClose }: { title: string; aspect: string; deletionMessage: string; onSave: (title: string, aspect: string) => Promise<void>; onDelete: () => Promise<void>; onClose: () => void }) {
  const [name, setName] = useState(title);
  const [ratio, setRatio] = useState(aspect);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const trimmed = name.trim();
  const save = async () => {
    if (!trimmed) return;
    try { await onSave(trimmed, ratio); onClose(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };
  return (
    <Sheet title="Video settings" onClose={onClose} trailing={<Button variant="pill-prominent" disabled={!trimmed} onClick={save}>Done</Button>}>
      <section className="ed-form-section">
        <h3>Video title</h3>
        <input className="ed-input" value={name} placeholder="Video title" onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") save(); }} />
      </section>
      <section className="ed-form-section">
        <label className="ed-stepper"><span>Aspect ratio</span>
          <select value={ratio} onChange={(e) => setRatio(e.target.value)}>{ASPECT_RATIOS.map((a) => <option key={a} value={a}>{aspectTitle(a)}</option>)}</select>
        </label>
      </section>
      <section className="ed-form-section">
        {confirming
          ? <div className="ed-confirm"><span>{deletionMessage}</span><Button variant="destructive" onClick={async () => { try { await onDelete(); onClose(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); } }}>Delete video</Button><Button variant="pill" onClick={() => setConfirming(false)}>Cancel</Button></div>
          : <Button variant="destructive" onClick={() => setConfirming(true)}><Icon.Trash /> Delete video</Button>}
      </section>
      {error && <p className="ed-error" role="alert">{error}</p>}
    </Sheet>
  );
}
