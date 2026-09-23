import { useEffect, type ReactNode } from "react";
import { Icon } from "@/design/icons";

/** Dark modal sheet: bottom-anchored on phones, centred card on wide windows. */
export function Sheet({ title, onClose, children, trailing, wide = false }: { title: string; onClose: () => void; children: ReactNode; trailing?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="ed-sheet-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="ed-sheet" role="dialog" aria-modal="true" aria-label={title} data-wide={wide || undefined} data-surface="dark">
        <header className="ed-sheet-header">
          <button type="button" className="ed-icon-button" aria-label="Close" onClick={onClose}><Icon.Close /></button>
          <h2>{title}</h2>
          <div className="ed-sheet-trailing">{trailing}</div>
        </header>
        <div className="ed-sheet-body">{children}</div>
      </div>
    </div>
  );
}
