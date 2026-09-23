import { useEffect, type ReactNode } from "react";

/* Bottom sheet with the compact header from AnalysisSheetHeader.swift: 44-point targets without
   oversized navigation chrome. Escape or a backdrop click dismisses. */
export function Sheet({ title, onClose, cancel, actionTitle = "Done", onAction, actionDisabled = false, tall = false, tabs, children }: {
  title: string; onClose(): void; cancel?: () => void; actionTitle?: string; onAction?: () => void; actionDisabled?: boolean; tall?: boolean; tabs?: ReactNode; children: ReactNode;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);
  return (
    <div className="an-sheet-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }} data-surface="dark">
      <div className="an-sheet" role="dialog" aria-label={title} data-tall={tall || undefined}>
        <div className="an-sheet-grabber" />
        <div className="an-sheet-header">
          {cancel && <button type="button" className="an-control" onClick={cancel} aria-label="Cancel"><span>✕</span></button>}
          <h2>{title}</h2>
          <button type="button" className="an-control" data-signal="true" disabled={actionDisabled} onClick={onAction ?? onClose}><span>{actionTitle}</span></button>
        </div>
        {tabs}
        <div className="an-sheet-body">{children}</div>
      </div>
    </div>
  );
}

export function Section({ title, footer, children }: { title?: string; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className="an-section">
      {title && <h3>{title}</h3>}
      <div className="an-card">{children}</div>
      {footer && <p>{footer}</p>}
    </section>
  );
}

export function Field({ label, value, children, column = false }: { label: ReactNode; value?: ReactNode; children?: ReactNode; column?: boolean }) {
  return (
    <div className={`an-field${column ? " column" : ""}`}>
      <div className="label">{label}</div>
      {value != null && <span className="value">{value}</span>}
      {children}
    </div>
  );
}

export function Toggle({ label, checked, onChange, disabled = false, id }: { label: ReactNode; checked: boolean; onChange(value: boolean): void; disabled?: boolean; id?: string }) {
  return (
    <div className="an-field">
      <div className="label">{label}</div>
      <button type="button" role="switch" aria-checked={checked} className="an-switch" disabled={disabled} onClick={() => onChange(!checked)} data-testid={id} aria-label={typeof label === "string" ? label : undefined} />
    </div>
  );
}

export function SliderField({ label, value, min, max, step = 0.001, format, onChange, onBegin, disabled = false }: {
  label: ReactNode; value: number; min: number; max: number; step?: number; format?: (v: number) => string; onChange(value: number): void; onBegin?: () => void; disabled?: boolean;
}) {
  return (
    <div className="an-field column">
      <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}><span>{label}</span>{format && <span className="value">{format(value)}</span>}</div>
      <input type="range" min={min} max={max} step={step} value={value} disabled={disabled} onPointerDown={onBegin} onKeyDown={onBegin} onChange={(e) => onChange(Number(e.target.value))} aria-label={typeof label === "string" ? label : undefined} />
    </div>
  );
}

export function Segmented<T extends string>({ options, value, onChange, title, disabled = false }: { options: readonly { value: T; label: ReactNode }[]; value: T; onChange(value: T): void; title: (value: T) => string; disabled?: boolean }) {
  return (
    <div className="an-segmented" role="radiogroup">
      {options.map((option) => (
        <button key={option.value} type="button" role="radio" aria-checked={option.value === value} data-selected={option.value === value} disabled={disabled} onClick={() => onChange(option.value)} title={title(option.value)}>
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  );
}

export function Stepper({ label, value, step, min, max, format, onChange, disabled = false }: { label: ReactNode; value: number; step: number; min: number; max: number; format: (v: number) => string; onChange(value: number): void; disabled?: boolean }) {
  return (
    <div className="an-field">
      <div className="label">{label} <span className="value">{format(value)}</span></div>
      <div className="an-stepper">
        <button type="button" aria-label="Decrease" disabled={disabled || value - step < min - 1e-9} onClick={() => onChange(Math.max(min, value - step))}>−</button>
        <button type="button" aria-label="Increase" disabled={disabled || value + step > max + 1e-9} onClick={() => onChange(Math.min(max, value + step))}>+</button>
      </div>
    </div>
  );
}

export function FieldButton({ children, onClick, disabled = false, destructive = false, prominent = false, icon }: { children: ReactNode; onClick(): void; disabled?: boolean; destructive?: boolean; prominent?: boolean; icon?: ReactNode }) {
  return <button type="button" className="an-field-button" onClick={onClick} disabled={disabled} data-destructive={destructive || undefined} data-prominent={prominent || undefined}>{icon}{children}</button>;
}
