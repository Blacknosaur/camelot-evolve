import { useCallback, useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { annotationCss, annotationTitle } from "@/domain/annotation";
import type { UUID } from "@/domain/ids";
import { applyTimelineEdit, motionMode, trackedSpan, trackingGaps, type AnnotationTimelineEdit } from "../model/annotation";
import { AnalysisIcon } from "./icons";
import { formatTimecode } from "./format";
import { SourceFilmstrip } from "./SourceFilmstrip";

/* One shared time axis with a fixed centre playhead and a separate track per drawing (port of
   AnalysisLayerTimeline.swift). Horizontal drags scrub or edit; vertical scrolling stays native;
   two pointers or ⌘-wheel change the time scale. */

export interface LayerTimelineProps {
  annotations: readonly AnalysisAnnotation[];
  bounds: [number, number];
  time: number;
  selectedID: UUID | null;
  selectedKeyframe: UUID | null;
  zoom: number;
  setZoom(zoom: number): void;
  select(id: UUID): void;
  seek(time: number): void;
  previewSeek(time: number): void;
  beginEdit(): void;
  edit(mark: AnalysisAnnotation, finished: boolean): void;
  selectKeyframe(layer: UUID, keyframe: UUID, time: number): void;
  toggleHidden(id: UUID): void;
  toggleLocked(id: UUID): void;
  reorder(id: UUID, direction: number): void;
  undo: (() => void) | null;
  redo: (() => void) | null;
  recordingID?: string;
  freezeTime?: number | null;
  showsFilmstrip?: boolean;
}

const EDGE_INSET = 24;

export function LayerTimeline(p: LayerTimelineProps) {
  const hostRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [height, setHeight] = useState(0);
  useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const observer = new ResizeObserver(([entry]) => { if (entry) { setWidth(entry.contentRect.width); setHeight(entry.contentRect.height); } });
    observer.observe(host);
    return () => observer.disconnect();
  }, []);

  const [lower, upper] = p.bounds;
  const duration = Math.max(0.01, upper - lower);
  const maxZoom = Math.max(64, duration);
  const viewport = Math.max(64, width - EDGE_INSET * 2);
  const span = duration / p.zoom;
  const scale = viewport / Math.max(0.01, span);
  const visibleStart = p.time - span / 2 - EDGE_INSET / scale;
  const xFor = (seconds: number) => (seconds - visibleStart) * scale;
  const rows = [...p.annotations].reverse();

  const panStart = useRef<number | null>(null);
  const pan = useCallback((deltaPixels: number, finished: boolean) => {
    panStart.current ??= p.time;
    const next = Math.min(upper, Math.max(lower, panStart.current - deltaPixels / scale));
    p.previewSeek(next);
    if (finished) { p.seek(next); panStart.current = null; }
  }, [p, scale, lower, upper]);

  /* Two-pointer magnification over the whole timeline; ⌘/Ctrl-wheel on desktop. */
  const pinch = useRef<{ zoom: number; distance: number } | null>(null);
  const pinchPointers = useRef(new Map<number, number>());
  const onPointerDownCapture = (event: ReactPointerEvent) => {
    pinchPointers.current.set(event.pointerId, event.clientX);
    if (pinchPointers.current.size === 2) { const [a, b] = [...pinchPointers.current.values()] as [number, number]; pinch.current = { zoom: p.zoom, distance: Math.max(1, Math.abs(a - b)) }; panStart.current = null; }
  };
  const onPointerMoveCapture = (event: ReactPointerEvent) => {
    if (!pinchPointers.current.has(event.pointerId)) return;
    pinchPointers.current.set(event.pointerId, event.clientX);
    if (pinch.current && pinchPointers.current.size >= 2) {
      const [a, b] = [...pinchPointers.current.values()] as [number, number];
      p.setZoom(Math.min(maxZoom, Math.max(1, pinch.current.zoom * Math.abs(a - b) / pinch.current.distance)));
    }
  };
  const onPointerUpCapture = (event: ReactPointerEvent) => { pinchPointers.current.delete(event.pointerId); if (pinchPointers.current.size < 2) pinch.current = null; };
  const onWheel = (event: React.WheelEvent) => {
    if (event.ctrlKey || event.metaKey) { event.preventDefault(); p.setZoom(Math.min(maxZoom, Math.max(1, p.zoom * Math.exp(-event.deltaY * 0.01)))); }
    else if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) { event.preventDefault(); p.seek(Math.min(upper, Math.max(lower, p.time + event.deltaX / scale))); }
  };
  const magnifying = pinch.current !== null;

  return (
    <div className="an-timeline" data-testid="analysis-layer-timeline" onPointerDownCapture={onPointerDownCapture} onPointerMoveCapture={onPointerMoveCapture} onPointerUpCapture={onPointerUpCapture} onPointerCancelCapture={onPointerUpCapture} onWheel={onWheel}>
      <div className="an-timeline-bar">
        <button type="button" className="an-icon-button" aria-label="Undo" disabled={!p.undo} onClick={() => p.undo?.()}><AnalysisIcon.undo /></button>
        <button type="button" className="an-icon-button" aria-label="Redo" disabled={!p.redo} onClick={() => p.redo?.()}><AnalysisIcon.redo /></button>
        <span className="scale" data-testid="analysis-timeline-scale">{p.zoom.toFixed(1)}×</span>
        <button type="button" className="an-icon-button" aria-label="Zoom out" disabled={p.zoom <= 1} onClick={() => p.setZoom(p.zoom / 2)}>−</button>
        <button type="button" className="an-icon-button" aria-label="Fit" onClick={() => p.setZoom(1)}><AnalysisIcon.fit /></button>
        <button type="button" className="an-icon-button" aria-label="Zoom in" disabled={p.zoom >= maxZoom} onClick={() => p.setZoom(p.zoom * 2)}>+</button>
      </div>
      <div ref={hostRef} style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", position: "relative" }}>
        <Ruler width={width} viewport={viewport} scale={scale} span={span} visibleStart={visibleStart} lower={lower} upper={upper} zoom={p.zoom} time={p.time} seek={p.seek} previewSeek={p.previewSeek} disabled={magnifying} />
        <div className="an-playhead" style={{ left: width / 2 - 1, top: 0, height: 30 }} aria-hidden />
        <div className="an-tracks" data-testid="analysis-vertical-tracks">
          <div className="an-tracks-inner" style={{ minHeight: Math.max(0, height - 30) }}>
            {p.showsFilmstrip && p.recordingID && (
              <HorizontalDrag className="an-filmstrip" style={{ height: height < 160 ? 28 : 48 }} disabled={magnifying} onDrag={(_o, delta, finished) => pan(delta, finished)} onCancel={() => { panStart.current = null; }}>
                <SourceFilmstrip recordingID={p.recordingID} bounds={p.bounds} visibleStart={visibleStart} scale={scale} width={width} freezeTime={p.freezeTime ?? null} height={height < 160 ? 28 : 48} />
              </HorizontalDrag>
            )}
            {rows.map((mark) => (
              <LayerTrack key={mark.id} mark={mark} bounds={p.bounds} visibleStart={visibleStart} scale={scale} selected={mark.id === p.selectedID} selectedKeyframe={p.selectedKeyframe} disabled={magnifying}
                select={p.select} beginEdit={p.beginEdit} edit={p.edit} selectKeyframe={p.selectKeyframe} pan={pan} xFor={xFor}
                toggleHidden={p.toggleHidden} toggleLocked={p.toggleLocked} reorder={p.reorder} />
            ))}
            <HorizontalDrag className="an-pan-area" style={{ minHeight: Math.max(44, height - 30 - rows.length * 48 - (p.showsFilmstrip ? 56 : 0)) }} disabled={magnifying} onDrag={(_o, delta, finished) => pan(delta, finished)} onCancel={() => { panStart.current = null; }} testID="analysis-timeline-pan-area" />
            <div className="an-playhead" style={{ left: width / 2 - 1 }} aria-label="Playhead" data-testid="analysis-playhead" />
          </div>
        </div>
      </div>
    </div>
  );
}

function tickIntervals(duration: number, width: number, zoom: number): [number, number] {
  const pixelsPerSecond = (width * zoom) / Math.max(0.01, duration);
  const candidates = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300];
  const major = candidates.find((c) => c * pixelsPerSecond >= 70) ?? 600;
  return [major, major / (major >= 1 ? 5 : 2)];
}

function Ruler({ width, viewport, scale, span, visibleStart, lower, upper, zoom, time, seek, previewSeek, disabled }: { width: number; viewport: number; scale: number; span: number; visibleStart: number; lower: number; upper: number; zoom: number; time: number; seek(t: number): void; previewSeek(t: number): void; disabled: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const start = useRef<number | null>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas || width <= 0) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * dpr); canvas.height = 30 * dpr;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, width, 30);
    const [step, minor] = tickIntervals(upper - lower, viewport, zoom);
    const first = Math.ceil((visibleStart - lower) / minor), count = Math.min(512, Math.floor(span / minor) + 3);
    const divisions = Math.max(1, Math.round(step / minor));
    ctx.font = "10px ui-monospace, Menlo, monospace"; ctx.textBaseline = "top";
    for (let index = 0; index < count; index++) {
      const seconds = (first + index) * minor;
      if (seconds < 0 || seconds > upper - lower) continue;
      const x = (seconds + lower - visibleStart) * scale;
      const major = (first + index) % divisions === 0;
      if (major) { ctx.fillStyle = "rgba(255,255,255,0.7)"; ctx.fillText(formatTimecode(seconds, step < 1), x + 4, 1); }
      ctx.strokeStyle = major ? "rgba(255,255,255,0.6)" : "rgba(255,255,255,0.24)";
      ctx.beginPath(); ctx.moveTo(x, major ? 16 : 20); ctx.lineTo(x, 25); ctx.stroke();
    }
  }, [width, viewport, scale, span, visibleStart, lower, upper, zoom]);
  return (
    <HorizontalDrag className="an-ruler" disabled={disabled} testID="analysis-time-ruler"
      onDrag={(_o, delta, finished) => { start.current ??= time; const next = Math.min(upper, Math.max(lower, start.current - delta / scale)); if (finished) { seek(next); start.current = null; } else previewSeek(next); }}
      onCancel={() => { start.current = null; }}
      onTap={(origin) => seek(Math.min(upper, Math.max(lower, time + (origin.x - width / 2) / scale)))}>
      <canvas ref={ref} aria-label="Analysis time ruler" role="slider" aria-valuenow={time - lower} aria-valuemin={0} aria-valuemax={upper - lower} tabIndex={0}
        onKeyDown={(e) => { if (e.key === "ArrowLeft") seek(Math.max(lower, time - 1 / 30)); if (e.key === "ArrowRight") seek(Math.min(upper, time + 1 / 30)); }} />
    </HorizontalDrag>
  );
}

type DragTarget = { kind: "layer" } | { kind: "start" } | { kind: "end" } | { kind: "keyframe"; id: UUID } | { kind: "pan" };

function LayerTrack({ mark, bounds, visibleStart, scale, selected, selectedKeyframe, disabled, select, beginEdit, edit, selectKeyframe, pan, xFor, toggleHidden, toggleLocked, reorder }: {
  mark: AnalysisAnnotation; bounds: [number, number]; visibleStart: number; scale: number; selected: boolean; selectedKeyframe: UUID | null; disabled: boolean;
  select(id: UUID): void; beginEdit(): void; edit(mark: AnalysisAnnotation, finished: boolean): void; selectKeyframe(layer: UUID, keyframe: UUID, time: number): void; pan(delta: number, finished: boolean): void; xFor(seconds: number): number;
  toggleHidden(id: UUID): void; toggleLocked(id: UUID): void; reorder(id: UUID, direction: number): void;
}) {
  const [lower, upper] = bounds;
  const x = xFor(mark.start);
  const width = Math.max(3, (Math.min(upper, mark.end) - Math.max(lower, mark.start)) * scale);
  const tint = annotationCss(mark.color);
  const frames = mark.keyframes.filter((k) => k.time >= mark.start && k.time <= mark.end);
  const drag = useRef<{ original: AnalysisAnnotation; target: DragTarget; scale: number } | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const mode = motionMode(mark);
  const span = trackedSpan(mark);

  const targetAt = (point: { x: number; y: number }): DragTarget => {
    if (!selected || mark.isLocked === true) return { kind: "pan" };
    const start = xFor(mark.start), end = xFor(mark.end);
    if (point.y >= 24) {
      const nearest = frames.map((f) => ({ f, d: Math.abs(xFor(f.time) - point.x) })).sort((a, b) => a.d - b.d)[0];
      if (nearest && nearest.d <= 14) return { kind: "keyframe", id: nearest.f.id };
    }
    if (Math.min(Math.abs(point.x - start), Math.abs(point.x - end)) <= 22) return Math.abs(point.x - start) <= Math.abs(point.x - end) ? { kind: "start" } : { kind: "end" };
    return point.x >= start && point.x <= end ? { kind: "layer" } : { kind: "pan" };
  };

  const onDrag = (origin: { x: number; y: number }, delta: number, finished: boolean) => {
    if (!drag.current) {
      const target = targetAt(origin);
      drag.current = { original: mark, target, scale };
      if (target.kind === "keyframe") { const frame = mark.keyframes.find((k) => k.id === target.id); if (frame) selectKeyframe(mark.id, frame.id, frame.time); }
      if (target.kind !== "pan") beginEdit();
    }
    const { original, target, scale: dragScale } = drag.current;
    const seconds = delta / dragScale;
    let operation: AnnotationTimelineEdit | null = null;
    switch (target.kind) {
      case "pan": pan(delta, finished); break;
      case "layer": operation = { kind: "move", delta: seconds }; break;
      case "start": operation = { kind: "trimStart", value: original.start + seconds }; break;
      case "end": operation = { kind: "trimEnd", value: original.end + seconds }; break;
      case "keyframe": { const frame = original.keyframes.find((k) => k.id === target.id); if (frame) operation = { kind: "keyframe", id: target.id, value: frame.time + seconds }; break; }
    }
    if (operation) edit(applyTimelineEdit(original, operation, lower, upper), finished);
    if (finished) drag.current = null;
  };

  return (
    <HorizontalDrag className="an-track" data-selected={selected} disabled={disabled} onDrag={onDrag}
      onCancel={() => { if (drag.current) edit(drag.current.original, false); drag.current = null; }}
      onTap={() => select(mark.id)}
      onContextMenu={(e) => { e.preventDefault(); setMenu({ x: e.nativeEvent.offsetX, y: e.nativeEvent.offsetY }); }}>
      <div className="an-track-bar" data-testid={`analysis-layer-bar-${mark.id}`} style={{ left: x, width, background: annotationCss(mark.color, mark.isHidden === true ? 0.1 : selected ? 0.55 : 0.28), borderColor: selected ? "#fff" : annotationCss(mark.color, 0.7), borderWidth: selected ? 2 : 1 }}
        aria-label={`${annotationTitle(mark)} timing`}>
        <span style={{ left: Math.max(12, -x + 12), right: "auto" }}>{annotationTitle(mark)} · {formatTimecode(mark.end - mark.start, true)}</span>
      </div>
      {(mode === "player" || mode === "camera") && (
        <>
          <div className="an-track-coverage" style={{ left: xFor(span?.[0] ?? mark.start), width: Math.max(0, ((span?.[1] ?? mark.start) - (span?.[0] ?? mark.start)) * scale), background: "rgb(50, 200, 230)" }} />
          {span && span[0] > mark.start + 0.05 && <div className="an-track-coverage" style={{ left: x, width: (Math.min(mark.end, span[0]) - mark.start) * scale, background: "var(--event-foul)" }} />}
          {span && span[1] < mark.end - 0.12 && <div className="an-track-coverage" style={{ left: xFor(span[1]), width: (mark.end - span[1]) * scale, background: "var(--event-foul)" }} />}
          {trackingGaps(mark).map((gap, i) => { const lo = Math.max(mark.start, gap[0]), hi = Math.min(mark.end, gap[1]); return hi > lo ? <div key={i} className="an-track-coverage" style={{ left: xFor(lo), width: (hi - lo) * scale, background: "var(--event-foul)" }} /> : null; })}
        </>
      )}
      {frames.map((frame) => (
        <button key={frame.id} type="button" className="an-keyframe" data-selected={frame.id === selectedKeyframe} style={{ left: xFor(frame.time) - 12, color: tint }} aria-label={`Keyframe at ${formatTimecode(frame.time - lower, true)}`} data-testid={`analysis-keyframe-${frame.id}`}
          onClick={(e) => { e.stopPropagation(); selectKeyframe(mark.id, frame.id, frame.time); }}><i /></button>
      ))}
      {selected && mark.isLocked !== true && (
        <>
          <div className="an-handle" style={{ left: x - 22 }} role="slider" aria-label="Layer start" aria-valuenow={mark.start - lower} data-testid="analysis-layer-start" />
          <div className="an-handle" style={{ left: x + width - 22 }} role="slider" aria-label="Layer end" aria-valuenow={mark.end - lower} data-testid="analysis-layer-end" />
        </>
      )}
      {menu && (
        <div className="an-menu-host" style={{ position: "absolute", left: menu.x, top: menu.y }} onPointerLeave={() => setMenu(null)}>
          <div className="an-menu" data-align="left" data-side="down">
            <button type="button" onClick={() => { toggleHidden(mark.id); setMenu(null); }}><AnalysisIcon.eye />{mark.isHidden === true ? "Show layer" : "Hide layer"}</button>
            <button type="button" onClick={() => { toggleLocked(mark.id); setMenu(null); }}><AnalysisIcon.lock />{mark.isLocked === true ? "Unlock layer" : "Lock layer"}</button>
            <button type="button" onClick={() => { reorder(mark.id, 1); setMenu(null); }}>Bring forward</button>
            <button type="button" onClick={() => { reorder(mark.id, -1); setMenu(null); }}>Send backward</button>
          </div>
        </div>
      )}
    </HorizontalDrag>
  );
}

/** Direction-selective drag: rejects vertical movement before recognition so the enclosing scroll view
 *  keeps scrolling; horizontal movement (≥4 px, 1.5× more horizontal than vertical) drives edits. */
function HorizontalDrag({ children, className, style, disabled, onDrag, onCancel, onTap, onContextMenu, testID, ...rest }: {
  children?: React.ReactNode; className?: string; style?: React.CSSProperties; disabled: boolean;
  onDrag(origin: { x: number; y: number }, delta: number, finished: boolean): void; onCancel(): void; onTap?(origin: { x: number; y: number }): void;
  onContextMenu?(event: React.MouseEvent): void; testID?: string; "data-selected"?: boolean;
}) {
  const gesture = useRef<{ id: number; startX: number; startY: number; origin: { x: number; y: number }; state: "possible" | "active" | "failed" } | null>(null);
  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (disabled || gesture.current) return;
    const rect = event.currentTarget.getBoundingClientRect();
    gesture.current = { id: event.pointerId, startX: event.clientX, startY: event.clientY, origin: { x: event.clientX - rect.left, y: event.clientY - rect.top }, state: "possible" };
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const g = gesture.current;
    if (!g || g.id !== event.pointerId || disabled) return;
    const dx = event.clientX - g.startX, dy = event.clientY - g.startY;
    if (g.state === "possible") {
      if (Math.max(Math.abs(dx), Math.abs(dy)) < 4) return;
      if (Math.abs(dx) > Math.abs(dy) * 1.5) { g.state = "active"; event.currentTarget.setPointerCapture(event.pointerId); } else { g.state = "failed"; return; }
    }
    if (g.state === "active") onDrag(g.origin, dx, false);
  };
  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    const g = gesture.current;
    if (!g || g.id !== event.pointerId) return;
    gesture.current = null;
    if (g.state === "active") onDrag(g.origin, event.clientX - g.startX, true);
    else if (g.state === "possible" && onTap && !disabled) onTap(g.origin);
  };
  const onPointerCancel = () => { if (gesture.current?.state === "active") onCancel(); gesture.current = null; };
  useEffect(() => { if (disabled && gesture.current) { if (gesture.current.state === "active") onCancel(); gesture.current = null; } }, [disabled, onCancel]);
  return (
    <div className={className} style={style} data-testid={testID} data-selected={rest["data-selected"]} onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel} onContextMenu={onContextMenu}>
      {children}
    </div>
  );
}
