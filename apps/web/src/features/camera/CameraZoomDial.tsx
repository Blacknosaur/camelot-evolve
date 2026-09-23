import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { arcPoint, crossedStop, defaultArcDial, dialTicks, dialValue, formatZoom, pillLabel, selectedPill, snapZoom, stepZoom, zoomPills, type ZoomScale } from "./zoom-model";

/* Port of CameraZoomDial.swift. Lens pills like Camera.app with a precision arc dial behind them:
   tap a pill to ramp to that stop, hold or drag anywhere on the row to open the dial and slide.
   The dial collapses after three seconds without interaction. */

const COLLAPSE_AFTER_MS = 3000;
const HOLD_TO_OPEN_MS = 320;

export const vibrate = (pattern: number | number[]) => { try { navigator.vibrate?.(pattern); } catch { /* unsupported */ } };

export function CameraZoomDial({ value, scale, disabled = false, change }: { value: number; scale: ZoomScale; disabled?: boolean; /** `smooth` asks the recorder to ramp instead of jumping. */ change: (value: number, smooth: boolean) => void }) {
  const [expanded, setExpanded] = useState(false);
  const [interaction, setInteraction] = useState(0);
  const drag = useRef<{ start: number; x: number; pointerID: number; moved: boolean } | null>(null);
  const holdTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const suppressTapsUntil = useRef(0);
  const lastHaptic = useRef<number | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);

  const pills = zoomPills(scale);
  const selected = selectedPill(value, pills);
  const dial = defaultArcDial(scale);

  useEffect(() => {
    if (!expanded) return;
    const timer = setTimeout(() => { if (!drag.current) setExpanded(false); }, COLLAPSE_AFTER_MS);
    return () => clearTimeout(timer);
  }, [expanded, interaction]);
  useEffect(() => () => { if (holdTimer.current) clearTimeout(holdTimer.current); }, []);

  const touch = () => setInteraction((n) => n + 1);
  const open = () => { if (!expanded) { vibrate(8); suppressTapsUntil.current = performance.now() + 600; setExpanded(true); } touch(); };

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled || event.button !== 0) return;
    drag.current = { start: value, x: event.clientX, pointerID: event.pointerId, moved: false };
    lastHaptic.current = null;
    rootRef.current?.setPointerCapture(event.pointerId);
    if (holdTimer.current) clearTimeout(holdTimer.current);
    if (!expanded) holdTimer.current = setTimeout(() => { if (drag.current) open(); }, HOLD_TO_OPEN_MS);
  };
  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.pointerID !== event.pointerId) return;
    const translation = event.clientX - d.x;
    if (!expanded && Math.abs(translation) > 12) { d.moved = true; open(); }
    if (!expanded && !d.moved) return;
    const target = dialValue(dial, d.start, translation);
    const stop = crossedStop(value, target, pills);
    if (stop != null && stop !== lastHaptic.current) { vibrate(6); lastHaptic.current = stop; }
    change(target, false);
  };
  const onPointerUp = (event: PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.pointerID !== event.pointerId) return;
    if (holdTimer.current) { clearTimeout(holdTimer.current); holdTimer.current = null; }
    if (expanded) { suppressTapsUntil.current = performance.now() + 400; change(snapZoom(value, pills), false); }
    drag.current = null;
    touch();
  };
  const onPillClick = (stop: number) => {
    if (disabled || performance.now() < suppressTapsUntil.current) return;
    vibrate(6);
    change(stop, true);
    touch();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (disabled) return;
    const keys: Record<string, () => void> = {
      ArrowRight: () => change(stepZoom(scale, value, 1), true), ArrowUp: () => change(stepZoom(scale, value, 1), true),
      ArrowLeft: () => change(stepZoom(scale, value, -1), true), ArrowDown: () => change(stepZoom(scale, value, -1), true),
      Home: () => change(scale.minimum, true), End: () => change(scale.maximum, true),
      Enter: () => setExpanded((e) => !e), " ": () => setExpanded((e) => !e), Escape: () => setExpanded(false),
    };
    const action = keys[event.key];
    if (!action) return;
    event.preventDefault();
    action();
    touch();
  };

  const slider = {
    role: "slider" as const, tabIndex: disabled ? -1 : 0, "aria-label": "Camera zoom", "aria-valuemin": scale.minimum, "aria-valuemax": scale.maximum, "aria-valuenow": Number(value.toFixed(2)),
    "aria-valuetext": `${formatZoom(value, 1)} times${expanded ? ", dial open" : ""}`, "aria-description": expanded ? "Drag left to zoom in, right to zoom out." : "Tap to snap to this lens, hold or drag to open the dial.",
    "data-testid": "camera-zoom-dial", onKeyDown,
  };

  return (
    <div ref={rootRef} className="cam-zoom" data-expanded={expanded || undefined} data-disabled={disabled || undefined}
      onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}>
      {expanded ? (
        <ArcDialView value={value} dial={dial} sliderProps={slider} />
      ) : (
        <div className="cam-zoom-pills">
          {pills.map((stop) => {
            const isSelected = stop === selected;
            return (
              <button key={stop} type="button" className="cam-zoom-pill" data-selected={isSelected || undefined} disabled={disabled} onClick={() => onPillClick(stop)}
                {...(isSelected ? slider : { "aria-label": `Zoom to ${formatZoom(stop, Number.isInteger(stop) ? 0 : 1)} times`, "data-testid": `camera-zoom-${formatZoom(stop, Number.isInteger(stop) ? 0 : 1)}x` })}>
                {pillLabel(stop, value, isSelected)}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

const WIDTH = 320, HEIGHT = 96, RADIUS = 150, CX = WIDTH / 2, CY = 12 + RADIUS;

/** Ticks swing under a fixed pointer; labelled stops read as the lenses. */
function ArcDialView({ value, dial, sliderProps }: { value: number; dial: ReturnType<typeof defaultArcDial>; sliderProps: Record<string, unknown> }) {
  const ticks = dialTicks(dial, value);
  const pointerTop = arcPoint(CX, CY, RADIUS + 6, 0), pointerBottom = arcPoint(CX, CY, RADIUS - 22, 0);
  return (
    <div className="cam-zoom-arc" {...sliderProps}>
      <svg width="100%" viewBox={`0 0 ${WIDTH} ${HEIGHT}`} aria-hidden="true" focusable="false">
        {ticks.map((tick) => {
          const fade = Math.max(0.15, 1 - Math.pow(Math.abs(tick.angle) / dial.halfSweep, 2));
          const outer = arcPoint(CX, CY, RADIUS, tick.angle), inner = arcPoint(CX, CY, RADIUS - (tick.isStop ? 16 : 8), tick.angle);
          const label = arcPoint(CX, CY, RADIUS - 28, tick.angle);
          return (
            <g key={tick.zoom}>
              <line x1={outer.x} y1={outer.y} x2={inner.x} y2={inner.y} stroke="#fff" strokeOpacity={tick.isStop ? fade : fade * 0.5} strokeWidth={tick.isStop ? 2 : 1} strokeLinecap="round" />
              {tick.isStop && <text x={label.x} y={label.y} fill="#fff" fillOpacity={fade} fontSize="11" fontWeight="600" textAnchor="middle" dominantBaseline="middle">{formatZoom(tick.zoom, Number.isInteger(tick.zoom) ? 0 : 1)}</text>}
            </g>
          );
        })}
        <line x1={pointerTop.x} y1={pointerTop.y} x2={pointerBottom.x} y2={pointerBottom.y} stroke="var(--signal)" strokeWidth="2.5" strokeLinecap="round" />
        <text x={CX} y={HEIGHT - 12} fill="var(--signal)" fontSize="14" fontWeight="700" textAnchor="middle" className="tabular">{formatZoom(value, 1)}×</text>
      </svg>
    </div>
  );
}
