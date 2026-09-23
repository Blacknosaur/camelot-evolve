import { useEffect, useRef, useState, type ReactNode } from "react";

/* Popover menu anchored to its trigger (replaces SwiftUI `Menu`). Closes on outside pointer, Escape or selection. */
export function Menu({ trigger, children, align = "right", side = "up", disabled = false, label }: { trigger: ReactNode; children: (close: () => void) => ReactNode; align?: "left" | "right"; side?: "up" | "down"; disabled?: boolean; label: string }) {
  const [open, setOpen] = useState(false);
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onPointer = (e: PointerEvent) => { if (!host.current?.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    window.addEventListener("pointerdown", onPointer, true);
    window.addEventListener("keydown", onKey, true);
    return () => { window.removeEventListener("pointerdown", onPointer, true); window.removeEventListener("keydown", onKey, true); };
  }, [open]);
  return (
    <div className="an-menu-host" ref={host}>
      <button type="button" className="an-control" aria-haspopup="menu" aria-expanded={open} aria-label={label} title={label} disabled={disabled} onClick={() => setOpen((v) => !v)}><span>{trigger}</span></button>
      {open && <div className="an-menu" role="menu" data-align={align} data-side={side}>{children(() => setOpen(false))}</div>}
    </div>
  );
}

export function MenuItem({ children, onClick, disabled = false, destructive = false, icon, close }: { children: ReactNode; onClick(): void; disabled?: boolean; destructive?: boolean; icon?: ReactNode; close(): void }) {
  return <button type="button" role="menuitem" disabled={disabled} data-destructive={destructive || undefined} onClick={() => { close(); onClick(); }}>{icon}{children}</button>;
}
