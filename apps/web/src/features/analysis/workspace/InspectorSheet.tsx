import { useState } from "react";
import { useStore } from "zustand";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { annotationTitle } from "@/domain/annotation";
import { clipAnnotationEnd } from "@/domain/records";
import { DEFAULT_LOUPE_STYLE } from "@/domain/annotation-styles";
import { DEFAULT_TRAJECTORY_STYLE } from "@/domain/tracking";
import { cameraAt } from "@/features/analysis/tracking/library";
import type { AnalysisEngine } from "../model/engine";
import { motionStart, resolvedTextStyle, setGrounding } from "../model/annotation";
import { frozenGround, hasPlane } from "../model/ground";
import { measurementStatus } from "../model/measurements";
import { Field, FieldButton, Section, Sheet, Stepper, Toggle } from "./Sheet";
import { ColorField, EffectControls, LineControls, LoupeControls, TextControls, TrackingBridgeControls, TrackingSmoothingControls, TrajectoryControls, ZoomControls } from "./controls";
import { AnalysisIcon } from "./icons";
import { seconds1 } from "./format";

/* One task at a time: Style, Timing and Layer tabs sized for a phone (port of AnalysisInspectorSheet
   and the inspector sections of AnalysisOverlayView.swift). */

type Tab = "Style" | "Timing" | "Layer";

export function InspectorSheet({ engine, time, onClose, onEditTiming, previewEffect }: { engine: AnalysisEngine; time: number; onClose(): void; onEditTiming(mark: AnalysisAnnotation): void; previewEffect(mark: AnalysisAnnotation): void }) {
  const state = useStore(engine);
  const [tab, setTab] = useState<Tab>("Style");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [editingTextSize, setEditingTextSize] = useState(false);
  const clip = state.clip;
  const selected = clip.annotations.find((a) => a.id === state.selectedID) ?? null;
  const busy = state.tracking !== null;
  const update = (change: (m: AnalysisAnnotation) => AnalysisAnnotation, recordUndo = true) => state.updateSelected(change, recordUndo);
  const checkpoint = () => state.checkpoint();
  const hasGround = hasPlane(clip.groundCalibration);
  const groundAvailable = !!clip.groundCalibration && frozenGround(clip.groundCalibration, time) !== null;
  const status = measurementStatus(clip.groundCalibration);
  const end = clipAnnotationEnd(clip);
  const locked = selected?.isLocked === true;

  const changeTiming = (change: (m: AnalysisAnnotation) => AnalysisAnnotation) => {
    update(change);
    const mark = engine.getState().clip.annotations.find((a) => a.id === state.selectedID);
    if (mark) onEditTiming(mark);
  };

  const style = selected ? (
    <fieldset disabled={busy} style={{ border: 0, padding: 0, margin: 0 }}>
      {toolSupportsLineStyle(selected) && <Section title="Line style"><LineControls mark={selected} onChange={(value) => update((m) => ({ ...m, lineStyle: value }), false)} beginEdit={checkpoint} /></Section>}
      <Section title={selected.tool === "zoom" ? "Zoom" : "Effect"}>
        {selected.tool === "zoom" ? (
          <ZoomControls mark={selected} onAmount={(v) => update((m) => ({ ...m, zoomScale: v }), false)} onRamp={(v) => update((m) => ({ ...m, zoomRamp: v }), false)} beginEdit={checkpoint} />
        ) : selected.tool === "loupe" ? (
          <LoupeControls style={selected.loupeStyle ?? DEFAULT_LOUPE_STYLE} onChange={(v) => update((m) => ({ ...m, loupeStyle: v }), false)} beginEdit={checkpoint} disabled={locked} />
        ) : selected.tool === "trajectory" ? (
          <>
            <TrajectoryControls style={selected.trajectoryStyle ?? DEFAULT_TRAJECTORY_STYLE} onChange={(v) => update((m) => ({ ...m, trajectoryStyle: v }))} disabled={locked} />
            <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>{selected.trajectoryCameraMotion ? "Camera-compensated trail within saved camera coverage." : "Image-space trail. Add a camera track and use it to compensate for camera movement."}</p>
            {!selected.trajectoryCameraMotion && cameraAt(clip.trackingLibrary, time) && <FieldButton onClick={() => { const camera = cameraAt(clip.trackingLibrary, time); if (camera) update((m) => ({ ...m, trajectoryCameraMotion: camera })); }}>Use saved camera for trail</FieldButton>}
          </>
        ) : (
          <EffectControls mark={selected} hasGround={hasGround} groundAvailable={groundAvailable}
            onEffect={(v) => update((m) => ({ ...m, effect: v }))} onFill={(v) => update((m) => ({ ...m, areaFill: v }), false)}
            onWallHeight={(v) => update((m) => ({ ...m, wallHeight: v }), false)} onWallOpacity={(v) => update((m) => ({ ...m, wallOpacity: v }), false)}
            onGrounding={(enabled) => update((m) => setGrounding(m, enabled, time, clip.groundCalibration))} onMetricHeight={(v) => update((m) => ({ ...m, wallHeightMeters: v }), false)} beginEdit={checkpoint} />
        )}
      </Section>
      {(selected.playerMotion || selected.linkedPlayers) && (
        <Section title="Tracking">
          <TrackingSmoothingControls mark={selected} onChange={(v) => state.setTrackingSmoothing(v)} beginEdit={checkpoint} />
          <TrackingBridgeControls mark={selected} onChange={(v) => state.setGapBridging(v)} beginEdit={checkpoint} />
        </Section>
      )}
      {locked && <Section><div className="an-field"><AnalysisIcon.lock /><span style={{ color: "var(--fg-secondary)" }}>Unlock this layer in Layer settings to edit.</span></div></Section>}
      {selected.tool === "text" && (
        <Section title="Text">
          <div className="an-field"><textarea rows={2} value={selected.text} disabled={locked} data-testid="analysis-text-input" aria-label="Annotation text" onChange={(e) => update((m) => ({ ...m, text: e.target.value }))} /></div>
          <TextControls style={resolvedTextStyle(selected)} disabled={locked} onChange={(value) => update((m) => ({ ...m, textStyle: value }), !editingTextSize)} onSizeEditing={(editing) => { if (editing && !editingTextSize) checkpoint(); setEditingTextSize(editing); }} />
        </Section>
      )}
      {selected.tool !== "zoom" && selected.tool !== "loupe" && (
        <Section title="Appearance">
          <ColorField label="Colour" color={selected.color} disabled={locked} onChange={(color) => state.setColor(color)} />
          {selected.tool !== "text" && (
            <div className="an-field column">
              <span>Line width</span>
              <input type="range" min={0.002} max={0.04} step={0.0005} value={selected.width} disabled={locked} aria-label="Line width" onPointerDown={checkpoint} onChange={(e) => state.setWidth(Number(e.target.value))} />
            </div>
          )}
        </Section>
      )}
      {(selected.tool === "text" || ["line", "arrow", "connection", "zone"].includes(selected.tool)) && (
        <Section title="Measurements" footer={status ?? "Set a known ground reference in Measure. Values stay unavailable without calibration."}>
          {selected.tool === "text"
            ? <Toggle label="Show player speed · km/h" checked={selected.showsSpeed === true} disabled={locked || clip.freezeDuration != null || !selected.playerMotion} onChange={(v) => update((m) => ({ ...m, showsSpeed: v }))} />
            : selected.fieldLines !== true && <Toggle label="Show distances · m" checked={selected.showsDistance === true} disabled={locked} onChange={(v) => update((m) => ({ ...m, showsDistance: v }))} id="analysis-show-distance" />}
        </Section>
      )}
    </fieldset>
  ) : (
    <>
      <Section title="Players" footer="Tap a player, then open Player effects to combine a ring, spotlight and label.">
        <Toggle label="Show detected players" checked={state.showsPlayers} onChange={(v) => state.setShowsPlayers(v)} />
      </Section>
      <FreezeControls engine={engine} />
    </>
  );

  const timing = selected && (
    <fieldset disabled={busy || locked} style={{ border: 0, padding: 0, margin: 0 }}>
      <Section title="On the timeline" footer={<>Times are relative to this clip. Drag either edge on the timeline for larger changes.{motionStart(selected) != null && selected.start < motionStart(selected)! - 0.05 ? " Orange marks frames without tracking. Re-track from an earlier frame, or choose Static for a fixed drawing." : ""}</>}>
        <Field label="Duration" value={seconds1(selected.end - selected.start)} />
        <Stepper label="Start" value={selected.start - clip.startSeconds} step={0.1} min={0} max={Math.max(0, selected.end - clip.startSeconds - 1 / 30)} format={seconds1} onChange={(v) => changeTiming((m) => ({ ...m, start: clip.startSeconds + v }))} />
        <Stepper label="End" value={selected.end - clip.startSeconds} step={0.1} min={Math.min(end, selected.start + 1 / 30) - clip.startSeconds} max={end - clip.startSeconds} format={seconds1} onChange={(v) => changeTiming((m) => ({ ...m, end: clip.startSeconds + v }))} />
      </Section>
      <Section>
        <FieldButton onClick={() => changeTiming((m) => ({ ...m, start: Math.max(clip.startSeconds, Math.min(time, m.end - 1 / 30)) }))}>Start at playhead</FieldButton>
        <FieldButton onClick={() => changeTiming((m) => ({ ...m, end: Math.min(end, Math.max(time, m.start + 1 / 30)) }))}>End at playhead</FieldButton>
        <FieldButton onClick={() => changeTiming((m) => ({ ...m, start: clip.startSeconds, end }))}>Use whole clip</FieldButton>
      </Section>
      {selected.tool !== "zoom" && <Section><Toggle label="Fade in and out" checked={selected.fade} onChange={(v) => update((m) => ({ ...m, fade: v }))} /></Section>}
      {clip.freezeDuration == null && <Section><FieldButton onClick={() => previewEffect(selected)} icon={<AnalysisIcon.play />}>Preview effect</FieldButton></Section>}
      <FreezeControls engine={engine} />
    </fieldset>
  );

  const layer = selected && (
    <fieldset disabled={busy} style={{ border: 0, padding: 0, margin: 0 }}>
      {selected.playerMotion?.trackID && clip.trackingLibrary?.players.some((p) => p.id === selected.playerMotion!.trackID) && (
        <Section title="Shared tracking" footer="Ring, spotlight and label reuse this track. Correcting its motion updates all attached layers.">
          <div className="an-field"><input type="text" aria-label="Track name" data-testid="analysis-track-name" value={clip.trackingLibrary.players.find((p) => p.id === selected.playerMotion!.trackID)?.name ?? ""} onChange={(e) => state.renamePlayerTrack(selected.playerMotion!.trackID!, e.target.value)} /></div>
        </Section>
      )}
      {selected.cameraMotion?.trackID && <Section title="Shared tracking" footer="Other drawings can use this camera track without processing the video again."><Field label="Saved camera track" /></Section>}
      <Section title="Name">
        <div className="an-field"><input type="text" placeholder={annotationTitle({ ...selected, layerName: undefined })} value={selected.layerName ?? ""} disabled={locked} aria-label="Layer name" data-testid="analysis-layer-name" onChange={(e) => state.rename(selected.id, e.target.value)} /></div>
      </Section>
      <Section>
        <Toggle label="Visible" checked={selected.isHidden !== true} onChange={() => state.toggleHidden(selected.id)} />
        <Toggle label="Lock layer" checked={selected.isLocked === true} onChange={() => state.toggleLocked(selected.id)} />
        <FieldButton onClick={() => state.duplicate()} icon={<AnalysisIcon.duplicate />}>Duplicate layer</FieldButton>
      </Section>
      <Section>
        {confirmDelete
          ? <><FieldButton destructive onClick={() => { state.deleteLayer(selected.id); onClose(); }} icon={<AnalysisIcon.trash />}>Delete this layer?</FieldButton><FieldButton onClick={() => setConfirmDelete(false)}>Cancel</FieldButton></>
          : <FieldButton destructive disabled={locked} onClick={() => setConfirmDelete(true)} icon={<AnalysisIcon.trash />}>Delete layer</FieldButton>}
      </Section>
    </fieldset>
  );

  const tabs = selected ? (
    <div className="an-tabs" role="tablist" data-testid="analysis-inspector-tabs">
      {(["Style", "Timing", "Layer"] as Tab[]).map((t) => <button key={t} type="button" role="tab" aria-selected={tab === t} data-selected={tab === t} onClick={() => setTab(t)}>{t}</button>)}
    </div>
  ) : undefined;

  return (
    <Sheet title={selected ? annotationTitle(selected) : "Drawing style"} onClose={onClose} tabs={tabs} tall>
      {tab === "Style" || !selected ? style : tab === "Timing" ? timing : layer}
    </Sheet>
  );
}

const toolSupportsLineStyle = (mark: AnalysisAnnotation) => ["line", "arrow", "pen", "connection", "zone", "rectangle", "ellipse"].includes(mark.tool) && mark.fieldLines !== true;

function FreezeControls({ engine }: { engine: AnalysisEngine }) {
  const state = useStore(engine);
  if (state.clip.freezeDuration == null) return null;
  return (
    <Section title="Freeze frame">
      <Stepper label="Hold" value={state.clip.freezeDuration} step={1} min={1} max={30} format={(v) => `${v.toFixed(0)} seconds`} onChange={(v) => state.setFreezeDuration(v)} />
    </Section>
  );
}
