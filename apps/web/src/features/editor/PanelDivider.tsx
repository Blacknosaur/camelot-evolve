import { useRef, useState } from "react";

/** Grip between preview and workspace. Drags use fixed screen coordinates so the panel follows
 *  the pointer exactly; arrow keys move it by 40px. Port of EditorPanelDivider. */
export function PanelDivider({ title, vertical = false, value, min, max, onChange }: { title: string; vertical?: boolean; value: number; min: number; max: number; onChange: (value: number) => void }) {
  const origin = useRef<{ pointer: number; value: number } | null>(null);
  const [active, setActive] = useState(false);
  const clamp = (v: number) => Math.min(max, Math.max(min, v));
  return (
    <div
      className="ed-divider"
      data-vertical={vertical || undefined}
      data-active={active || undefined}
      role="separator"
      aria-orientation={vertical ? "vertical" : "horizontal"}
      aria-label={`Resize ${title.toLowerCase()}`}
      aria-valuenow={Math.round(value)}
      aria-valuemin={Math.round(min)}
      aria-valuemax={Math.round(max)}
      tabIndex={0}
      onKeyDown={(e) => {
        const grow = vertical ? e.key === "ArrowLeft" : e.key === "ArrowUp";
        const shrink = vertical ? e.key === "ArrowRight" : e.key === "ArrowDown";
        if (grow || shrink) { e.preventDefault(); onChange(clamp(value + (grow ? 40 : -40))); }
      }}
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        origin.current = { pointer: vertical ? e.clientX : e.clientY, value };
        setActive(true);
      }}
      onPointerMove={(e) => {
        if (!origin.current) return;
        const translation = (vertical ? e.clientX : e.clientY) - origin.current.pointer;
        const next = clamp(origin.current.value - translation);
        if (Math.abs(next - value) >= 0.5) onChange(next);
      }}
      onPointerUp={() => { origin.current = null; setActive(false); }}
      onPointerCancel={() => { origin.current = null; setActive(false); }}
    >
      <span className="ed-divider-grip" />
    </div>
  );
}
