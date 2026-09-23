export type EventKind = "Goal" | "Shot" | "Save" | "Foul" | "Card" | "Note";
export const EVENT_KINDS: readonly EventKind[] = ["Goal", "Shot", "Save", "Foul", "Card", "Note"];

export function defaultPreRoll(kind: string): number { return kind === "Goal" ? 15 : 10; }
export function defaultPostRoll(kind: string): number { return kind === "Goal" ? 5 : 10; }

/** CSS colour for a known kind; unknown kinds (custom or synced) fall back to orange. */
export function eventKindTint(kind: string): string {
  switch (kind) {
    case "Goal": return "var(--event-goal)";
    case "Shot": return "var(--event-shot)";
    case "Save": return "var(--event-save)";
    case "Foul": case "Card": return "var(--event-foul)";
    case "Note": return "var(--event-note)";
    default: return "var(--event-foul)";
  }
}

/** An empty colour preserves the event type's default, including older synced events. */
export const EVENT_COLORS = [
  { id: "", title: "Auto" },
  { id: "FF6B6B", title: "Red" }, { id: "FFAA55", title: "Orange" }, { id: "F5D76E", title: "Yellow" },
  { id: "B6F36A", title: "Green" }, { id: "6AB7FF", title: "Blue" }, { id: "B89AFF", title: "Purple" }, { id: "FF8CCD", title: "Pink" },
] as const;

export function eventTint(colorHex: string, kind: string): string {
  return /^[0-9a-fA-F]{6}$/.test(colorHex) ? `#${colorHex}` : eventKindTint(kind);
}
