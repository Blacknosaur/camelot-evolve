import { useCallback, useRef, useState } from "react";
import type { UUID } from "@/domain";
import { recordHistory, redoHistory, undoHistory, type EditHistory, type EditorDocument } from "./model/edits";

/** Clips, selection, crop and deferred deletions with a bounded undo/redo history.
 *  Every mutating call goes through `commit`, which snapshots the previous document first. */
export function useEditorDocument(initial: EditorDocument) {
  const [document, setDocument] = useState<EditorDocument>(initial);
  const [history, setHistory] = useState<EditHistory>({ undo: [], redo: [] });
  const current = useRef(document);
  current.current = document;

  const commit = useCallback((update: (doc: EditorDocument) => EditorDocument | null): EditorDocument | null => {
    const next = update(current.current);
    if (!next) return null;
    setHistory((h) => recordHistory(h, current.current));
    current.current = next;
    setDocument(next);
    return next;
  }, []);

  /** Selection changes are not history entries. */
  const select = useCallback((selectedClipID: UUID) => {
    if (current.current.selectedClipID === selectedClipID) return;
    current.current = { ...current.current, selectedClipID };
    setDocument(current.current);
  }, []);

  const replace = useCallback((next: EditorDocument) => { current.current = next; setDocument(next); }, []);

  const undo = useCallback((): EditorDocument | null => {
    const result = undoHistory(history, current.current);
    if (!result) return null;
    setHistory(result.history);
    replace(result.document);
    return result.document;
  }, [history, replace]);

  const redo = useCallback((): EditorDocument | null => {
    const result = redoHistory(history, current.current);
    if (!result) return null;
    setHistory(result.history);
    replace(result.document);
    return result.document;
  }, [history, replace]);

  return { document, commit, select, replace, undo, redo, canUndo: history.undo.length > 0, canRedo: history.redo.length > 0 };
}
