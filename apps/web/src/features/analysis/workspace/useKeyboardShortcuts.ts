import { useEffect } from "react";
import type { AnalysisDrawingTool } from "@/domain/annotation";
import { toolForShortcut } from "../render/toolRegistry";

export interface ShortcutHandlers {
  chooseTool(tool: AnalysisDrawingTool): void;
  togglePlayback(): void;
  step(frames: number): void;
  setIn(): void;
  setOut(): void;
  deleteSelection(): void;
  undo(): void;
  redo(): void;
  escape(): void;
  enabled: boolean;
}

const isEditable = (target: EventTarget | null) => {
  const element = target as HTMLElement | null;
  return !!element && (element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.isContentEditable);
};

/** V/P/A/L/E/R/Z/T (and the other registry shortcuts) pick tools; space plays; arrows step; I/O set In/Out;
 *  Delete removes; ⌘/Ctrl+Z undoes and ⇧⌘Z redoes. Ignored while typing in a field. */
export function useKeyboardShortcuts(handlers: ShortcutHandlers) {
  useEffect(() => {
    if (!handlers.enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (isEditable(event.target)) return;
      const meta = event.metaKey || event.ctrlKey;
      if (meta && event.key.toLowerCase() === "z") { event.preventDefault(); if (event.shiftKey) handlers.redo(); else handlers.undo(); return; }
      if (meta) return;
      switch (event.key) {
        case " ": event.preventDefault(); handlers.togglePlayback(); return;
        case "ArrowLeft": event.preventDefault(); handlers.step(event.shiftKey ? -10 : -1); return;
        case "ArrowRight": event.preventDefault(); handlers.step(event.shiftKey ? 10 : 1); return;
        case "Backspace": case "Delete": event.preventDefault(); handlers.deleteSelection(); return;
        case "Escape": handlers.escape(); return;
      }
      const key = event.key.toLowerCase();
      if (key === "i") { handlers.setIn(); return; }
      if (key === "o") { handlers.setOut(); return; }
      const tool = toolForShortcut(key);
      if (tool) { event.preventDefault(); handlers.chooseTool(tool); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [handlers]);
}
