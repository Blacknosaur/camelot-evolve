import { useEffect, useRef, type ReactNode } from "react";

export interface MenuItem { title: string; icon?: ReactNode; checked?: boolean; disabled?: boolean; destructive?: boolean; onSelect: () => void }

/** Small popover menu built on <details>, closing on selection, outside pointer or Escape. */
export function Menu({ label, icon, items, ariaLabel, align = "start", disabled = false, prominent = false }: { label: ReactNode; icon?: ReactNode; items: MenuItem[]; ariaLabel: string; align?: "start" | "end"; disabled?: boolean; prominent?: boolean }) {
  const ref = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const close = (e: Event) => { const d = ref.current; if (d?.open && !(e.target instanceof Node && d.contains(e.target))) d.open = false; };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape" && ref.current) ref.current.open = false; };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", key);
    return () => { document.removeEventListener("pointerdown", close); document.removeEventListener("keydown", key); };
  }, []);
  return (
    <details ref={ref} className="ed-menu" data-align={align}>
      <summary className="ed-action" data-prominent={prominent || undefined} aria-label={ariaLabel} aria-disabled={disabled || undefined} onClick={(e) => { if (disabled) e.preventDefault(); }}>{icon}{label}</summary>
      <div className="ed-menu-list" role="menu">
        {items.map((item) => (
          <button key={item.title} type="button" role="menuitem" className="ed-menu-item" data-destructive={item.destructive || undefined} disabled={item.disabled} onClick={() => { if (ref.current) ref.current.open = false; item.onSelect(); }}>
            <span className="ed-menu-check">{item.checked ? "✓" : ""}</span>{item.icon}<span>{item.title}</span>
          </button>
        ))}
      </div>
    </details>
  );
}
