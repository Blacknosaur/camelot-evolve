import { useEffect, useId, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import type { EventKind } from "@/domain";
import { compactDuration } from "@/design/format";
import { Icon } from "@/design/icons";
import { Spinner } from "@/design/components";
import { captureModeShortTitle, type CaptureMode } from "./capture-mode";
import { remaining, selectedEvent, type EventCaptureState } from "./event-capture";
import { EventTagStrip, eventKindIcon } from "./EventTagStrip";

/* Port of CameraControls.swift and the countdown card from CameraEventCapture.swift. */

/** Round translucent capsule button for the header; lime when the option is active. */
export function ChromeButton({ isActive = false, label, value, toggle = false, className = "", children, ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & { isActive?: boolean; label: string; value?: string; /** Exposes on/off state to assistive tech. */ toggle?: boolean }) {
  return (
    <button type="button" className={`cam-chrome ${className}`} data-active={isActive || undefined} aria-label={label} aria-pressed={toggle ? isActive : undefined} title={value ? `${label}: ${value}` : label} {...rest}>
      {children}
    </button>
  );
}

/** Red pulsing dot and monospaced elapsed time while recording; amber while paused. */
export function TimerCapsule({ elapsed, isPaused }: { elapsed: number; isPaused: boolean }) {
  return (
    <span className="cam-timer" data-paused={isPaused || undefined} role="timer" aria-label={isPaused ? "Recording paused" : "Recording duration"} data-testid="camera-recording-time">
      <span className="cam-timer-dot" aria-hidden="true" />
      <span className="tabular">{compactDuration(elapsed)}</span>
    </span>
  );
}

/** White ring with a red core that morphs into a rounded square while recording. The target
 *  shrinks once recording starts so the event row keeps its room. */
export function RecordButton({ isRecording, isFinishing, progress, isEnabled, onClick }: { isRecording: boolean; isFinishing: boolean; progress: number; isEnabled: boolean; onClick: () => void }) {
  const outer = isRecording ? 44 : 64, inner = isRecording ? 18 : 52;
  const r = (outer - 4) / 2 - 1.5, circumference = 2 * Math.PI * r;
  return (
    <button type="button" className="cam-record" data-recording={isRecording || undefined} disabled={!isEnabled || isFinishing} onClick={onClick}
      style={{ width: outer, height: outer, opacity: isEnabled || isFinishing ? 1 : 0.45 }}
      aria-label={isFinishing ? "Saving recording" : isRecording ? "Stop recording" : "Start recording"} data-testid="camera-record">
      <svg width={outer} height={outer} viewBox={`0 0 ${outer} ${outer}`} aria-hidden="true">
        <circle cx={outer / 2} cy={outer / 2} r={r} fill="none" stroke="#fff" strokeOpacity={isFinishing ? 0.35 : 0.95} strokeWidth="3" />
        {isRecording && progress > 0 && !isFinishing && (
          <circle cx={outer / 2} cy={outer / 2} r={r} fill="none" stroke="var(--signal)" strokeWidth="3" strokeLinecap="round" transform={`rotate(-90 ${outer / 2} ${outer / 2})`}
            strokeDasharray={`${Math.min(1, Math.max(0, progress)) * circumference} ${circumference}`} />
        )}
      </svg>
      {isFinishing ? <span className="cam-record-spinner"><Spinner size={20} /></span> : <span className="cam-record-core" style={{ width: inner, height: inner, borderRadius: isRecording ? 5 : inner / 2 }} />}
    </button>
  );
}

export interface DockProps {
  isRecording: boolean; isFinishing: boolean; canRecord: boolean; mode: CaptureMode;
  tagCounts: Partial<Record<EventKind, number>>; lastTag: EventKind | null; savedCount: number; lastSavedDuration: number | null;
  bufferProgress: number; isLandscape: boolean; isPaused: boolean; supportsPause: boolean;
  record: () => void; mark: (kind: EventKind) => void; pause: () => void;
}

/** Compact overlays leave the full camera frame visible in either orientation. */
export function CaptureDock(p: DockProps) {
  const total = Object.values(p.tagCounts).reduce((sum, n) => sum + (n ?? 0), 0);
  const strip = <EventTagStrip counts={p.tagCounts} lastTag={p.lastTag} isEnabled={p.isRecording && !p.isFinishing && !p.isPaused} prefix="camera" mark={p.mark} />;
  const status = (
    <div className="cam-status">
      <span className="cam-status-title">{p.isFinishing ? "Saving…" : p.isPaused ? "Paused" : p.isRecording ? "Recording" : captureModeShortTitle(p.mode)}</span>
      <span className="cam-status-sub">{p.isRecording ? `${total} events` : "Ready"}</span>
    </div>
  );
  const saved = (
    <div className="cam-saved" data-testid="camera-saved-status">
      <span className="cam-status-title">{p.savedCount === 0 ? <Icon.Stack /> : <Icon.Check />} {p.savedCount} saved</span>
      {p.lastSavedDuration != null && <span className="cam-status-sub tabular">{compactDuration(p.lastSavedDuration)}</span>}
    </div>
  );
  const record = (
    <div className="cam-record-group">
      {p.isRecording && p.supportsPause && (
        <button type="button" className="cam-action" data-prominent={p.isPaused || undefined} disabled={p.isFinishing} onClick={p.pause} aria-label={p.isPaused ? "Resume recording" : "Pause recording"} data-testid="camera-pause">
          {p.isPaused ? <Icon.Play /> : <Icon.Pause />}
        </button>
      )}
      <RecordButton isRecording={p.isRecording} isFinishing={p.isFinishing} progress={p.bufferProgress} isEnabled={p.canRecord} onClick={p.record} />
    </div>
  );
  return (
    <div className="cam-dock" data-landscape={p.isLandscape || undefined} data-testid="camera-capture-controls">
      {p.isLandscape ? (
        <>{status}<div className="cam-dock-strip">{strip}</div>{record}</>
      ) : (
        <>{strip}<div className="cam-dock-row">{status}{record}{saved}</div></>
      )}
    </div>
  );
}

/** Countdown that follows the movie clock through the selected event's post-roll. */
export function EventCountdown({ capture, canEnd, isPaused, select, end }: { capture: EventCaptureState; canEnd: boolean; isPaused: boolean; select: (id: string) => void; end: (id: string) => void }) {
  const event = selectedEvent(capture);
  if (!event) return null;
  const left = remaining(capture, event), seconds = Math.ceil(left);
  const r = 13, circumference = 2 * Math.PI * r;
  return (
    <div className="cam-countdown" role="group" aria-label="Active event">
      <span className="cam-countdown-ring" aria-hidden="true">
        <svg width="30" height="30" viewBox="0 0 30 30">
          <circle cx="15" cy="15" r={r} fill="none" stroke="rgb(255 255 255 / 0.2)" strokeWidth="2" />
          <circle cx="15" cy="15" r={r} fill="none" stroke="var(--signal)" strokeWidth="2" strokeLinecap="round" transform="rotate(-90 15 15)" strokeDasharray={`${Math.min(1, left / Math.max(0.1, event.postRollSeconds)) * circumference} ${circumference}`} />
        </svg>
        <span className="cam-countdown-icon">{eventKindIcon[event.kind as EventKind] ?? <Icon.Flag />}</span>
      </span>
      <CameraMenu disabled={capture.active.length < 2} label="Active event" value={event.kind} className="cam-countdown-menu"
        items={capture.active.map((a) => ({ id: a.id, title: `${a.kind} · ${Math.ceil(remaining(capture, a))}s left`, checked: a.id === event.id, onSelect: () => select(a.id) }))}>
        <span className="cam-countdown-kind">{event.kind}{capture.active.length > 1 && <Icon.ChevronDown width={10} height={10} />}</span>
        <span className="cam-countdown-sub">{isPaused ? "Paused" : capture.active.length > 1 ? `${capture.active.length} active events` : "Capturing after event"}</span>
      </CameraMenu>
      <span className="cam-countdown-time mono" aria-label="Time remaining" aria-description={`${seconds} seconds`} data-testid="camera-event-countdown">{seconds}s</span>
      <button type="button" className="cam-action cam-action-text" disabled={!canEnd} onClick={() => end(event.id)} aria-label={`End ${event.kind.toLowerCase()} now`} data-testid="camera-event-end">End now</button>
    </div>
  );
}

export interface MenuItem { id: string; title: string; checked?: boolean; disabled?: boolean; note?: boolean; onSelect?: () => void }

/** Minimal popover menu for the header (quality, options) and the countdown. */
export function CameraMenu({ items, label, value, disabled = false, isActive = false, className = "", children }: { items: MenuItem[]; label: string; value?: string; disabled?: boolean; isActive?: boolean; className?: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useEffect(() => {
    if (!open) return;
    const close = (event: Event) => { if (!ref.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") setOpen(false); };
    document.addEventListener("pointerdown", close, true);
    document.addEventListener("keydown", key);
    return () => { document.removeEventListener("pointerdown", close, true); document.removeEventListener("keydown", key); };
  }, [open]);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  return (
    <div ref={ref} className={`cam-menu ${className}`}>
      <ChromeButton label={label} value={value} isActive={isActive} disabled={disabled} aria-haspopup="menu" aria-expanded={open} aria-controls={id} onClick={() => setOpen((o) => !o)}>{children}</ChromeButton>
      {open && (
        <div id={id} role="menu" className="cam-menu-list">
          {items.map((item) => item.note ? (
            <span key={item.id} className="cam-menu-note">{item.title}</span>
          ) : (
            <button key={item.id} type="button" role="menuitemcheckbox" aria-checked={item.checked ?? false} className="cam-menu-item" disabled={item.disabled} onClick={() => { item.onSelect?.(); setOpen(false); }}>
              <span className="cam-menu-check">{item.checked && <Icon.Check />}</span>{item.title}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export interface DialogAction { title: string; role?: "destructive" | "cancel"; onSelect: () => void }

/** Alert-style modal for stop confirmation and interruption recovery. */
export function CameraDialog({ title, message, actions }: { title: string; message: string; actions: DialogAction[] }) {
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => { first.current?.focus(); }, []);
  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") actions.find((a) => a.role === "cancel")?.onSelect(); };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [actions]);
  return (
    <div className="cam-dialog-backdrop">
      <div className="cam-dialog" role="alertdialog" aria-modal="true" aria-labelledby="cam-dialog-title" aria-describedby="cam-dialog-message">
        <h2 id="cam-dialog-title">{title}</h2>
        <p id="cam-dialog-message">{message}</p>
        <div className="cam-dialog-actions">
          {actions.map((action, index) => (
            <button key={action.title} ref={index === 0 ? first : undefined} type="button" className="cam-dialog-button" data-role={action.role} onClick={action.onSelect}>{action.title}</button>
          ))}
        </div>
      </div>
    </div>
  );
}
