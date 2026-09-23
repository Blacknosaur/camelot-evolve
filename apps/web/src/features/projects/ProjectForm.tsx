import { useEffect, useState } from "react";
import type { Project } from "@/domain";
import { newId, now } from "@/domain";
import { projects } from "@/storage/repository";
import { Button, ListGroup, ListRow } from "@/design/components";
import { ConfirmDialog, Sheet } from "@/design/sheet";
import { deleteProject } from "@/features/project-detail/library";
import { toDateTimeLocal } from "./project-summary";
import "./ProjectForm.css";

/** Port of ProjectFormView: create or edit a project (name, opponent, scheduled date). Editing also offers deletion. */
export function ProjectForm({ project, open, onClose, onDeleted }: { project: Project | null; open: boolean; onClose: () => void; onDeleted?: () => void }) {
  const [name, setName] = useState("");
  const [opponent, setOpponent] = useState("");
  const [date, setDate] = useState("");
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setName(project?.name ?? "");
    setOpponent(project?.opponent ?? "");
    setDate(toDateTimeLocal(project?.scheduledAt ?? now()));
  }, [open, project]);

  const trimmedName = name.trim();
  const canSave = trimmedName.length > 0 && !isSaving;

  const save = async () => {
    if (!canSave) return;
    setIsSaving(true);
    const scheduledAt = date ? new Date(date).toISOString() : now();
    try {
      if (project) await projects.save({ ...project, name: trimmedName, opponent: opponent.trim(), scheduledAt });
      else await projects.save({ id: newId(), name: trimmedName, opponent: opponent.trim(), scheduledAt, createdAt: now(), serverVersion: null, needsSync: true, mutationID: newId() });
      onClose();
    } finally { setIsSaving(false); }
  };

  const remove = async () => {
    if (!project) return;
    await deleteProject(project.id);
    onClose();
    onDeleted?.();
  };

  return (
    <Sheet open={open} onClose={onClose} title={project ? "Edit project" : "New project"} detent="large" trailing={<Button variant="plain" onClick={save} disabled={!canSave}><strong>{project ? "Save" : "Create"}</strong></Button>}>
      <form className="pf" onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <ListGroup header="Match" footer="Use the opponent field for matches. Leave it empty for training sessions.">
          <ListRow><input className="ds-input pf-input" placeholder="Project name" value={name} onChange={(e) => setName(e.target.value)} autoFocus={!project} aria-label="Project name" enterKeyHint="next" /></ListRow>
          <ListRow><input className="ds-input pf-input" placeholder="Opponent (optional)" value={opponent} onChange={(e) => setOpponent(e.target.value)} aria-label="Opponent" autoCapitalize="words" /></ListRow>
        </ListGroup>
        <ListGroup header="When">
          <ListRow label="Date" value={<input className="ds-input pf-date" type="datetime-local" value={date} onChange={(e) => setDate(e.target.value)} aria-label="Date" />} />
        </ListGroup>
        {project && (
          <ListGroup footer="Removes the project, its videos, events and edits from this device and every synced device.">
            <ListRow label="Delete project" destructive onClick={() => setConfirmingDelete(true)} />
          </ListGroup>
        )}
        <button type="submit" className="sr-only" disabled={!canSave}>Save</button>
      </form>
      <ConfirmDialog open={confirmingDelete} onClose={() => setConfirmingDelete(false)} title="Delete this project?" message="All videos, events and edits in this project will be removed. This cannot be undone." confirmLabel="Delete project" onConfirm={() => void remove()} />
    </Sheet>
  );
}
