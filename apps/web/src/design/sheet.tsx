import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { Button } from "./components";
import { Icon } from "./icons";
import "./sheet.css";

/* Modal primitives shared by every library screen (ports of `.sheet`, `Menu`,
   `.confirmationDialog` and `.alert`). Built on the native <dialog> element so focus
   trapping, Escape and the backdrop come for free. On narrow windows a Sheet slides up
   from the bottom with a grab handle; on wide windows it becomes a centred dialog. */

const WIDE_QUERY = "(min-width: 700px)";

function useModalDialog(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLDialogElement>(null);
  useLayoutEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    else if (!open && dialog.open) dialog.close();
  }, [open]);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    const handleCancel = (event: Event) => { event.preventDefault(); onClose(); };
    const handleClick = (event: MouseEvent) => { if (event.target === dialog) onClose(); };
    dialog.addEventListener("cancel", handleCancel);
    dialog.addEventListener("click", handleClick);
    return () => { dialog.removeEventListener("cancel", handleCancel); dialog.removeEventListener("click", handleClick); };
  }, [onClose]);
  return ref;
}

export interface SheetProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  /** Leading toolbar button, usually "Cancel". Defaults to a Cancel button that closes the sheet. */
  leading?: ReactNode;
  /** Trailing toolbar button, usually "Save"/"Create". */
  trailing?: ReactNode;
  /** Preferred height on phones; `large` fills almost the whole screen. */
  detent?: "medium" | "large";
  children: ReactNode;
}

/** Bottom sheet on phones, centred dialog on wide windows. */
export function Sheet({ open, onClose, title, leading, trailing, detent = "medium", children }: SheetProps) {
  const ref = useModalDialog(open, onClose);
  const titleID = useId();
  return (
    <dialog ref={ref} className="ds-sheet" data-detent={detent} aria-labelledby={title ? titleID : undefined}>
      {open && (
        <div className="ds-sheet-panel">
          <div className="ds-sheet-grab" aria-hidden="true" />
          {(title || leading !== null || trailing) && (
            <header className="ds-sheet-bar">
              <div className="ds-sheet-bar-side">{leading === undefined ? <Button variant="plain" onClick={onClose}>Cancel</Button> : leading}</div>
              {title && <h2 id={titleID} className="ds-sheet-title">{title}</h2>}
              <div className="ds-sheet-bar-side ds-sheet-bar-trailing">{trailing}</div>
            </header>
          )}
          <div className="ds-sheet-body">{children}</div>
        </div>
      )}
    </dialog>
  );
}

export interface MenuItem {
  label: string;
  icon?: ReactNode;
  onSelect: () => void;
  destructive?: boolean;
  disabled?: boolean;
}

/** Action list: bottom action sheet on phones, small centred dialog on wide windows. */
export function ActionSheet({ open, onClose, title, message, items, cancelLabel = "Cancel" }: { open: boolean; onClose: () => void; title?: string; message?: string; items: (MenuItem | "divider")[]; cancelLabel?: string }) {
  const ref = useModalDialog(open, onClose);
  const titleID = useId();
  return (
    <dialog ref={ref} className="ds-sheet ds-action-sheet" aria-labelledby={title ? titleID : undefined}>
      {open && (
        <div className="ds-sheet-panel">
          <div className="ds-sheet-grab" aria-hidden="true" />
          {(title || message) && (
            <div className="ds-action-header">
              {title && <h2 id={titleID}>{title}</h2>}
              {message && <p>{message}</p>}
            </div>
          )}
          <div className="ds-action-list" role="menu">
            {items.map((item, index) => item === "divider"
              ? <hr key={index} className="ds-action-divider" />
              : (
                <button key={item.label} type="button" role="menuitem" className="ds-action-item" data-destructive={item.destructive || undefined} disabled={item.disabled} onClick={() => { onClose(); item.onSelect(); }}>
                  {item.icon}
                  <span>{item.label}</span>
                </button>
              ))}
          </div>
          <button type="button" className="ds-action-item ds-action-cancel" onClick={onClose}>{cancelLabel}</button>
        </div>
      )}
    </dialog>
  );
}

/** Destructive/confirm dialog with a title, message and one confirming action. */
export function ConfirmDialog({ open, onClose, title, message, confirmLabel, destructive = true, onConfirm }: { open: boolean; onClose: () => void; title: string; message?: string; confirmLabel: string; destructive?: boolean; onConfirm: () => void }) {
  return <ActionSheet open={open} onClose={onClose} title={title} message={message} items={[{ label: confirmLabel, destructive, onSelect: onConfirm }]} />;
}

/** Informational alert with a single dismiss button (port of `.alert`). */
export function AlertDialog({ open, onClose, title, message, dismissLabel = "OK" }: { open: boolean; onClose: () => void; title: string; message?: string; dismissLabel?: string }) {
  const ref = useModalDialog(open, onClose);
  const titleID = useId();
  return (
    <dialog ref={ref} className="ds-alert" aria-labelledby={titleID}>
      {open && (
        <div className="ds-alert-panel">
          <h2 id={titleID}>{title}</h2>
          {message && <p>{message}</p>}
          <Button variant="plain" onClick={onClose} autoFocus>{dismissLabel}</Button>
        </div>
      )}
    </dialog>
  );
}

/** Single text field prompt ("Rename video"). */
export function PromptDialog({ open, onClose, title, message, placeholder, initialValue = "", confirmLabel = "Save", onConfirm }: { open: boolean; onClose: () => void; title: string; message?: string; placeholder?: string; initialValue?: string; confirmLabel?: string; onConfirm: (value: string) => void }) {
  const [value, setValue] = useState(initialValue);
  useEffect(() => { if (open) setValue(initialValue); }, [open, initialValue]);
  const trimmed = value.trim();
  const submit = () => { if (!trimmed) return; onClose(); onConfirm(trimmed); };
  return (
    <Sheet open={open} onClose={onClose} title={title} trailing={<Button variant="plain" onClick={submit} disabled={!trimmed}><strong>{confirmLabel}</strong></Button>}>
      <form className="ds-prompt" onSubmit={(event) => { event.preventDefault(); submit(); }}>
        {message && <p className="ds-prompt-message">{message}</p>}
        <input className="ds-input" autoFocus value={value} placeholder={placeholder} onChange={(event) => setValue(event.target.value)} aria-label={title} />
      </form>
    </Sheet>
  );
}

/** Trigger button + action menu. Uses a popover anchored to the button when a fine pointer
 *  is available and enough room exists; otherwise falls back to an ActionSheet. */
export function Menu({ items, label = "More", children, className = "" }: { items: (MenuItem | "divider")[]; label?: string; children?: ReactNode; className?: string }) {
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<CSSProperties | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  const openMenu = () => {
    const wide = typeof matchMedia !== "undefined" && matchMedia(WIDE_QUERY).matches;
    const rect = triggerRef.current?.getBoundingClientRect();
    if (wide && rect) {
      const alignRight = rect.left > window.innerWidth / 2;
      setAnchor({ top: rect.bottom + 6, ...(alignRight ? { right: window.innerWidth - rect.right } : { left: rect.left }) });
    } else setAnchor(null);
    setOpen(true);
  };

  useEffect(() => {
    if (!open || !anchor) return;
    const close = (event: Event) => { if (!popoverRef.current?.contains(event.target as Node) && event.target !== triggerRef.current) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") { setOpen(false); triggerRef.current?.focus(); } };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", () => setOpen(false), { once: true });
    popoverRef.current?.querySelector<HTMLElement>("[role=menuitem]:not(:disabled)")?.focus();
    return () => { document.removeEventListener("pointerdown", close); document.removeEventListener("keydown", key); };
  }, [open, anchor]);

  const moveFocus = (event: React.KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const nodes = Array.from(popoverRef.current?.querySelectorAll<HTMLElement>("[role=menuitem]:not(:disabled)") ?? []);
    const index = nodes.indexOf(document.activeElement as HTMLElement);
    nodes[(index + (event.key === "ArrowDown" ? 1 : nodes.length - 1)) % nodes.length]?.focus();
  };

  return (
    <>
      <button ref={triggerRef} type="button" className={`ds-menu-trigger ${className}`} aria-label={label} title={label} aria-haspopup="menu" aria-expanded={open} onClick={openMenu}>
        {children ?? <Icon.MoreCircle />}
      </button>
      {open && anchor && (
        <div ref={popoverRef} className="ds-menu-popover" role="menu" style={anchor} onKeyDown={moveFocus}>
          {items.map((item, index) => item === "divider"
            ? <hr key={index} className="ds-action-divider" />
            : (
              <button key={item.label} type="button" role="menuitem" className="ds-menu-item" data-destructive={item.destructive || undefined} disabled={item.disabled} onClick={() => { setOpen(false); item.onSelect(); }}>
                <span>{item.label}</span>
                {item.icon}
              </button>
            ))}
        </div>
      )}
      <ActionSheet open={open && !anchor} onClose={() => setOpen(false)} items={items} />
    </>
  );
}
