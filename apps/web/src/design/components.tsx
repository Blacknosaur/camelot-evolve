import type { ButtonHTMLAttributes, CSSProperties, ReactNode } from "react";
import "./components.css";

/** Small coloured status capsule ("Synced", "Uploading 42%"). */
export function StatusPill({ text, tint = "var(--fg-secondary)", icon }: { text: string; tint?: string; icon?: ReactNode }) {
  return (
    <span className="ds-pill" style={{ "--tint": tint } as CSSProperties}>
      {icon}
      {text}
    </span>
  );
}

/** Icon + value pair used for counts (duration, events, clips). */
export function MetaLabel({ icon, text }: { icon: ReactNode; text: string }) {
  return (
    <span className="ds-meta">
      {icon}
      {text}
    </span>
  );
}

/** Round 44px glass button for overlay controls on video surfaces. */
export function GlassIconButton({ label, isActive = false, tint = "#fff", size = 44, children, ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & { label: string; isActive?: boolean; tint?: string; size?: number }) {
  return (
    <button type="button" className="ds-glass" aria-label={label} title={label} data-active={isActive || undefined} style={{ width: size, height: size, color: isActive ? "#000" : tint }} {...rest}>
      {children}
    </button>
  );
}

/** Stat tile used in headers ("12 videos"). */
export function StatTile({ value, title, icon, tint = "var(--brand)" }: { value: string; title: string; icon: ReactNode; tint?: string }) {
  return (
    <div className="ds-stat">
      <span className="ds-stat-icon" style={{ color: tint }}>{icon}</span>
      <span className="ds-stat-value tabular">{value}</span>
      <span className="ds-stat-title">{title}</span>
    </div>
  );
}

export type ButtonVariant = "primary" | "secondary" | "pill" | "pill-prominent" | "plain" | "destructive";

/** Button styles: primary/secondary (library), pill/pill-prominent (dark toolbars), plain. */
export function Button({ variant = "primary", tint, className = "", ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant; tint?: string }) {
  return <button type="button" className={`ds-button ds-button-${variant} ${className}`} style={tint ? ({ "--tint": tint } as CSSProperties) : undefined} {...rest} />;
}

/** Card container for library surfaces. */
export function Card({ children, className = "", ...rest }: { children: ReactNode; className?: string } & React.HTMLAttributes<HTMLDivElement>) {
  return <div className={`ds-card ${className}`} {...rest}>{children}</div>;
}

/** Header line with a title and optional trailing accessory. */
export function SectionTitle({ title, accessory }: { title: string; accessory?: ReactNode }) {
  return (
    <div className="ds-section-title">
      <h2>{title}</h2>
      {accessory}
    </div>
  );
}

/** Constrains single-column content to a readable width and centres it. */
export function Readable({ children, width = "var(--readable-width)" }: { children: ReactNode; width?: string }) {
  return <div className="ds-readable" style={{ maxWidth: width }}>{children}</div>;
}

/** Centered placeholder for empty lists. */
export function EmptyState({ icon, title, message, action }: { icon?: ReactNode; title: string; message?: string; action?: ReactNode }) {
  return (
    <div className="ds-empty">
      {icon && <div className="ds-empty-icon">{icon}</div>}
      <h3>{title}</h3>
      {message && <p>{message}</p>}
      {action}
    </div>
  );
}

export function Spinner({ size = 18 }: { size?: number }) {
  return <span className="ds-spinner" role="progressbar" aria-label="Loading" style={{ width: size, height: size }} />;
}

/** Segmented control (port of `.pickerStyle(.segmented)`). */
export function SegmentedControl<T extends string>({ options, value, onChange, label }: { options: readonly { value: T; label: string; icon?: ReactNode }[]; value: T; onChange: (value: T) => void; label: string }) {
  return (
    <div className="ds-segmented" role="radiogroup" aria-label={label}>
      {options.map((option) => (
        <button key={option.value} type="button" role="radio" aria-checked={option.value === value} className="ds-segment" onClick={() => onChange(option.value)}>
          {option.icon}
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  );
}

/** Text input with a leading icon, optional trailing accessory and inline hint (port of `FormField`). */
export function Field({ icon, hint, trailing, children }: { icon?: ReactNode; hint?: string; trailing?: ReactNode; children: ReactNode }) {
  return (
    <div className="ds-field">
      <div className="ds-field-box">
        {icon && <span className="ds-field-icon">{icon}</span>}
        {children}
        {trailing}
      </div>
      {hint && <span className="ds-field-hint">{hint}</span>}
    </div>
  );
}

/** Inset grouped list section with optional header and footer (port of `List` + `Section`). */
export function ListGroup({ header, footer, children }: { header?: string; footer?: string; children: ReactNode }) {
  return (
    <section className="ds-list-group">
      {header && <h3 className="ds-list-header">{header}</h3>}
      <div className="ds-list">{children}</div>
      {footer && <p className="ds-list-footer">{footer}</p>}
    </section>
  );
}

/** Row inside a ListGroup: label on the left, value/accessory on the right. Renders a button when `onClick` is set. */
export function ListRow({ icon, label, value, accessory, onClick, disabled, destructive, children }: { icon?: ReactNode; label?: ReactNode; value?: ReactNode; accessory?: ReactNode; onClick?: () => void; disabled?: boolean; destructive?: boolean; children?: ReactNode }) {
  const content = children ?? (
    <>
      {icon && <span className="ds-row-icon">{icon}</span>}
      <span className="ds-row-label">{label}</span>
      {value !== undefined && <span className="ds-row-value">{value}</span>}
      {accessory}
    </>
  );
  if (onClick) return <button type="button" className="ds-row ds-row-button" onClick={onClick} disabled={disabled} data-destructive={destructive || undefined}>{content}</button>;
  return <div className="ds-row">{content}</div>;
}

/** Screen header with a large title and trailing actions (port of `.navigationTitle`). */
export function ScreenHeader({ title, subtitle, back, actions, children }: { title: string; subtitle?: ReactNode; back?: ReactNode; actions?: ReactNode; children?: ReactNode }) {
  return (
    <header className="ds-screen-header">
      <div className="ds-screen-header-bar">
        <div className="ds-screen-header-side">{back}</div>
        <div className="ds-screen-header-side ds-screen-header-actions">{actions}</div>
      </div>
      <h1 className="ds-screen-title">{title}</h1>
      {subtitle && <div className="ds-screen-subtitle">{subtitle}</div>}
      {children}
    </header>
  );
}

/** Inline error/warning banner. */
export function Banner({ tint = "var(--destructive)", icon, children }: { tint?: string; icon?: ReactNode; children: ReactNode }) {
  return <div className="ds-banner" role="alert" style={{ "--tint": tint } as CSSProperties}>{icon}<span>{children}</span></div>;
}
