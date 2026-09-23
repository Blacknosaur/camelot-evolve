import type { AnalysisAnnotation, AnnotationColor, AnnotationEffect } from "@/domain/annotation";
import { supportsGrounding, isGrounded } from "@/domain/annotation";
import { LINE_ENDPOINTS, LINE_PATTERNS, type AnnotationLineStyle, type AnnotationLoupeStyle, type AnnotationTextStyle } from "@/domain/annotation-styles";
import type { PlayerTrajectoryStyle } from "@/domain/tracking";
import { MAXIMUM_BRIDGE_HORIZON } from "@/features/analysis/tracking/motion";
import { resolvedLineStyle, displayPlayerMotion, type AnnotationMotionMode, motionModeTitle } from "../model/annotation";
import { toolRegistry } from "../render/toolRegistry";
import { Field, Segmented, SliderField, Stepper, Toggle } from "./Sheet";
import { percent1 } from "./format";

/* Ports of AnalysisEffectControls.swift, AnalysisTextControls.swift, AnalysisLoupeControls.swift,
   AnalysisTrajectoryControls.swift and AnalysisMotionControls. Each is a controlled form fragment. */

const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
export const colorHex = (c: AnnotationColor) => "#" + [c.red, c.green, c.blue].map((v) => Math.round(Math.min(1, Math.max(0, v)) * 255).toString(16).padStart(2, "0")).join("");
export const colorFromHex = (hex: string): AnnotationColor => ({ red: parseInt(hex.slice(1, 3), 16) / 255, green: parseInt(hex.slice(3, 5), 16) / 255, blue: parseInt(hex.slice(5, 7), 16) / 255 });

export function ColorField({ label, color, onChange, disabled = false }: { label: string; color: AnnotationColor; onChange(color: AnnotationColor): void; disabled?: boolean }) {
  return (
    <Field label={label}>
      <input type="color" value={colorHex(color)} disabled={disabled} aria-label={label} onChange={(e) => onChange(colorFromHex(e.target.value))} />
    </Field>
  );
}

export function LineControls({ mark, onChange, beginEdit }: { mark: AnalysisAnnotation; onChange(style: AnnotationLineStyle): void; beginEdit(): void }) {
  const current = resolvedLineStyle(mark);
  const supportsEndpoints = ["line", "arrow", "pen", "connection"].includes(mark.tool);
  const update = (patch: Partial<AnnotationLineStyle>) => { beginEdit(); onChange({ ...current, ...patch }); };
  const disabled = mark.isLocked === true;
  return (
    <>
      <div className="an-field column">
        <span>Pattern</span>
        <Segmented options={LINE_PATTERNS.map((p) => ({ value: p, label: capitalize(p) }))} value={current.pattern} onChange={(pattern) => update({ pattern })} title={capitalize} disabled={disabled} />
      </div>
      {supportsEndpoints && (
        <>
          <div className="an-field column"><span>Start</span><Segmented options={LINE_ENDPOINTS.map((e) => ({ value: e, label: capitalize(e) }))} value={current.start} onChange={(start) => update({ start })} title={capitalize} disabled={disabled} /></div>
          <div className="an-field column"><span>End</span><Segmented options={LINE_ENDPOINTS.map((e) => ({ value: e, label: capitalize(e) }))} value={current.end} onChange={(end) => update({ end })} title={capitalize} disabled={disabled} /></div>
        </>
      )}
    </>
  );
}

export function EffectControls({ mark, hasGround, groundAvailable, onEffect, onFill, onWallHeight, onWallOpacity, onGrounding, onMetricHeight, beginEdit }: {
  mark: AnalysisAnnotation; hasGround: boolean; groundAvailable: boolean;
  onEffect(effect: AnnotationEffect): void; onFill(value: number): void; onWallHeight(value: number): void; onWallOpacity(value: number): void; onGrounding(enabled: boolean): void; onMetricHeight(value: number): void; beginEdit(): void;
}) {
  const effects = toolRegistry[mark.tool].effects(mark).filter((e): e is AnnotationEffect => e != null);
  const disabled = mark.isLocked === true;
  const grounded = isGrounded(mark, hasGround);
  return (
    <>
      <div className="an-field column">
        <span>Effect</span>
        <Segmented options={effects.map((e) => ({ value: e, label: capitalize(e) }))} value={mark.effect ?? "clean"} onChange={onEffect} title={capitalize} disabled={disabled} />
      </div>
      {supportsGrounding(mark) && (
        <>
          <Toggle label="Ground to field" checked={grounded} onChange={onGrounding} disabled={disabled || (!hasGround && !isGrounded(mark, false))} id="analysis-ground-effect" />
          <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>
            {!hasGround ? "Set a four-point field reference in Measure to enable perspective." : grounded ? (groundAvailable ? "Uses field perspective and saved camera motion. Height is an estimate." : "No field tracking at this time. Grounded effects stay hidden.") : ""}
          </p>
        </>
      )}
      {(mark.effect === "wall" || mark.effect === "aerial") && (
        <>
          <p style={{ margin: "0 12px 4px", fontSize: 12, color: "var(--fg-secondary)" }}>{mark.effect === "aerial" ? "Raise the tactical roof above the ground area." : "Project a light wall above the boundary."}</p>
          {grounded
            ? <SliderField label="Height" value={mark.wallHeightMeters ?? 2} min={0.2} max={8} step={0.1} format={(v) => `${v.toFixed(1)} m`} onChange={onMetricHeight} onBegin={beginEdit} disabled={disabled} />
            : <SliderField label={mark.effect === "aerial" ? "Height" : "Wall height"} value={mark.wallHeight ?? 0.18} min={0.03} max={0.45} onChange={onWallHeight} onBegin={beginEdit} disabled={disabled} />}
          <SliderField label="Light intensity" value={mark.wallOpacity ?? 0.32} min={0.05} max={0.7} onChange={onWallOpacity} onBegin={beginEdit} disabled={disabled} />
        </>
      )}
      {mark.tool === "zone" && mark.fieldLines !== true && (
        <>
          <SliderField label="Area fill" value={mark.areaFill ?? 0.18} min={0.05} max={0.6} onChange={onFill} onBegin={beginEdit} disabled={disabled} />
          <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Drag each corner on the video to reshape. Use Keyframes to animate the area.</p>
        </>
      )}
    </>
  );
}

export function ZoomControls({ mark, onAmount, onRamp, beginEdit }: { mark: AnalysisAnnotation; onAmount(value: number): void; onRamp(value: number): void; beginEdit(): void }) {
  const disabled = mark.isLocked === true;
  return (
    <>
      <SliderField label="Zoom" value={mark.zoomScale ?? 2} min={1} max={4} step={0.05} format={(v) => `${v.toFixed(1)}×`} onChange={onAmount} onBegin={beginEdit} disabled={disabled} />
      <SliderField label="Ease in / out" value={mark.zoomRamp ?? 0.35} min={0} max={1.5} step={0.01} format={(v) => `${v.toFixed(2)}s`} onChange={onRamp} onBegin={beginEdit} disabled={disabled} />
      <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Drag the focus on the video. Set its duration in Timing, then use Preview effect.</p>
    </>
  );
}

export function TrackingBridgeControls({ mark, onChange, beginEdit }: { mark: AnalysisAnnotation; onChange(value: number): void; beginEdit(): void }) {
  const current = (mark.playerMotion ?? mark.linkedPlayers?.[0])?.gapBridging ?? 0.4;
  return (
    <>
      <SliderField label="Bridge missing tracking" value={current} min={0} max={MAXIMUM_BRIDGE_HORIZON} step={0.1} format={(v) => (v < 0.05 ? "Off" : `${v.toFixed(1)} s`)} onChange={(v) => onChange(Math.round(v * 10) / 10)} onBegin={beginEdit} disabled={mark.isLocked === true} />
      <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Keeps the effect on the player through short losses. Use Place here on the player track to fix longer ones.</p>
    </>
  );
}

export function TrackingSmoothingControls({ mark, onChange, beginEdit }: { mark: AnalysisAnnotation; onChange(value: number): void; beginEdit(): void }) {
  const current = displayPlayerMotion(mark)?.smoothing ?? mark.linkedPlayers?.[0]?.smoothing ?? 0.65;
  return <SliderField label="Tracking smoothing · Raw → Smooth" value={current} min={0} max={1} step={0.01} onChange={onChange} onBegin={beginEdit} disabled={mark.isLocked === true} />;
}

export function TextControls({ style, onChange, onSizeEditing, disabled = false }: { style: AnnotationTextStyle; onChange(style: AnnotationTextStyle): void; onSizeEditing?(editing: boolean): void; disabled?: boolean }) {
  return (
    <>
      <div className="an-field column"><span>Alignment</span><Segmented options={(["left", "center", "right"] as const).map((a) => ({ value: a, label: capitalize(a) }))} value={style.alignment} onChange={(alignment) => onChange({ ...style, alignment })} title={capitalize} disabled={disabled} /></div>
      <SliderField label="Text size" value={Math.min(0.12, Math.max(0.01, style.size))} min={0.01} max={0.12} step={0.001} format={percent1} onChange={(size) => onChange({ ...style, size })} onBegin={() => onSizeEditing?.(true)} disabled={disabled} />
      <div className="an-field column"><span>Weight</span><Segmented options={(["regular", "bold"] as const).map((w) => ({ value: w, label: capitalize(w) }))} value={style.weight} onChange={(weight) => onChange({ ...style, weight })} title={capitalize} disabled={disabled} /></div>
      <Toggle label="Background" checked={style.background} onChange={(background) => onChange({ ...style, background })} disabled={disabled} id="analysis-text-background" />
    </>
  );
}

export function LoupeControls({ style, onChange, beginEdit, disabled = false }: { style: AnnotationLoupeStyle; onChange(style: AnnotationLoupeStyle): void; beginEdit(): void; disabled?: boolean }) {
  return (
    <>
      <SliderField label="Magnification" value={style.magnification} min={1.5} max={5} step={0.1} format={(v) => `${v.toFixed(1)}×`} onChange={(magnification) => onChange({ ...style, magnification })} onBegin={beginEdit} disabled={disabled} />
      <SliderField label="Lens size" value={style.diameter} min={0.12} max={0.4} step={0.005} onChange={(diameter) => onChange({ ...style, diameter })} onBegin={beginEdit} disabled={disabled} />
      <div className="an-field">
        <div className="label">Position</div>
        {(["Above", "Left", "Right"] as const).map((side) => (
          <button key={side} type="button" className="an-control" disabled={disabled} onClick={() => { beginEdit(); onChange({ ...style, offset: side === "Above" ? { x: 0, y: -0.22 } : { x: side === "Left" ? -0.2 : 0.2, y: -0.08 } }); }}><span>{side}</span></button>
        ))}
      </div>
      <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Drag the focus on the video. Follow a saved player without tracking again.</p>
    </>
  );
}

export function TrajectoryControls({ style, onChange, disabled = false }: { style: PlayerTrajectoryStyle; onChange(style: PlayerTrajectoryStyle): void; disabled?: boolean }) {
  return (
    <>
      <Stepper label="Past · solid" value={style.pastSeconds} step={0.5} min={0} max={10} format={(v) => `${v.toFixed(1)}s`} onChange={(pastSeconds) => onChange({ ...style, pastSeconds })} disabled={disabled} />
      <Stepper label="Future · dashed" value={style.futureSeconds} step={0.5} min={0} max={10} format={(v) => `${v.toFixed(1)}s`} onChange={(futureSeconds) => onChange({ ...style, futureSeconds })} disabled={disabled} />
      <ColorField label="Future color" color={style.futureColor} onChange={(futureColor) => onChange({ ...style, futureColor })} disabled={disabled} />
      <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Set either duration to 0 to hide it. Future means confirmed movement later in this clip, not a prediction. Gaps are never joined.</p>
    </>
  );
}

export function MotionControls({ selection, allowsPlayer, showsCamera, onSelect, disabled = false }: { selection: AnnotationMotionMode; allowsPlayer: boolean; showsCamera: boolean; onSelect(mode: AnnotationMotionMode): void; disabled?: boolean }) {
  const modes: AnnotationMotionMode[] = ["still", "keyframes", ...(allowsPlayer ? ["player" as const] : []), ...(showsCamera ? ["camera" as const] : [])];
  return <Segmented options={modes.map((m) => ({ value: m, label: m === "player" && showsCamera ? "Player" : m === "camera" ? "Camera" : motionModeTitle(m) }))} value={selection} onChange={onSelect} title={motionModeTitle} disabled={disabled} />;
}
