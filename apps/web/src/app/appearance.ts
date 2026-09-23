import { useCallback, useState } from "react";

/** Account → Appearance offers System (default), Light, and Dark. Applies immediately, persists between launches.
 *  Camera and editor surfaces stay dark via `data-surface="dark"` regardless of this setting. */
export type Appearance = "system" | "light" | "dark";
const KEY = "camelot.appearance";

export const APPEARANCES: readonly { value: Appearance; title: string }[] = [
  { value: "system", title: "System" },
  { value: "light", title: "Light" },
  { value: "dark", title: "Dark" },
];

export function storedAppearance(): Appearance {
  try { const v = localStorage.getItem(KEY); return v === "light" || v === "dark" ? v : "system"; } catch { return "system"; }
}

export function setAppearance(value: Appearance) {
  try { localStorage.setItem(KEY, value); } catch { /* private window */ }
  applyAppearance(value);
}

export function applyAppearance(value: Appearance) {
  if (value === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = value;
}

export function applyStoredAppearance() { applyAppearance(storedAppearance()); }

/** React binding for the appearance picker. */
export function useAppearance(): [Appearance, (value: Appearance) => void] {
  const [value, setValue] = useState(storedAppearance);
  const update = useCallback((next: Appearance) => { setAppearance(next); setValue(next); }, []);
  return [value, update];
}
