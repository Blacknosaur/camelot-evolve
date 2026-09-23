import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { useStore } from "zustand";
import type { Rect } from "@/domain/geometry";
import type { CompositionClip, Recording, VideoComposition } from "@/domain/records";
import { clipAnnotationEnd } from "@/domain/records";
import type { AnalysisTrackingLibraryPlayer } from "@/domain/tracking";
import { boxAt } from "@/features/analysis/tracking/motion";
import { hasFullCameraTrack, playerMatching, sharedCamera } from "@/features/analysis/tracking/library";
import { GroundCalibrationSheet } from "@/features/analysis/field/GroundCalibrationSheet";
import { SequencePreview } from "@/features/player/engine/SequencePreview";
import { useSequencePlayer } from "@/features/player/engine/useSequencePlayer";
import { useRecordingSources } from "@/features/player/engine/useRecordingSources";
import { useLayoutMetrics } from "@/design/layout";
import * as repository from "@/storage/repository";
import { useLiveQuery } from "@/storage/live";
import { createAnalysisEngine, playerEffectLayers, type AnalysisEngine } from "./model/engine";
import { isActiveInEditor } from "./model/annotation";
import { measurementStatus } from "./model/measurements";
import { DEFAULT_INSPECTION } from "./model/viewport";
import { toolRegistry } from "./render/toolRegistry";
import { OverlayCanvas } from "./workspace/OverlayCanvas";
import { LayerTimeline } from "./workspace/LayerTimeline";
import { BottomRow, TopStrip, playerForSelection } from "./workspace/BottomRow";
import { InspectorSheet } from "./workspace/InspectorSheet";
import { ToolPickerSheet } from "./workspace/ToolPickerSheet";
import { PlayerEffectsSheet, PlayerTracksSheet, PlayerTrackingSheet } from "./workspace/PlayerSheets";
import { Sheet } from "./workspace/Sheet";
import { Menu, MenuItem } from "./workspace/Menu";
import { AnalysisIcon, ToolIcon } from "./workspace/icons";
import { useTracking } from "./workspace/useTracking";
import { useKeyboardShortcuts } from "./workspace/useKeyboardShortcuts";
import { formatTimecode } from "./workspace/format";
import "./workspace/AnalysisScreen.css";

/* Route: /projects/:projectID/edit/:compositionID/analyze/:clipID. Port of AnalysisWorkspaceView.swift:
   preview with the shared renderer above, one bottom row + layer timeline below (side by side in landscape). */

export default function AnalysisScreen() {
  const { compositionID = "", clipID = "" } = useParams();
  const composition = useLiveQuery(() => repository.compositions.get(compositionID), ["compositions"], [compositionID]);
  const clip = composition.data?.clips.find((c) => c.id === clipID);
  const recording = useLiveQuery(async () => (clip ? repository.recordings.get(clip.recordingID) : undefined), ["recordings"], [clip?.recordingID]);
  if (composition.isLoading || recording.isLoading) return <div className="an-screen" data-surface="dark"><div className="an-loading">Loading…</div></div>;
  if (!composition.data || !clip || !recording.data) return <div className="an-screen" data-surface="dark"><div className="an-loading">This clip is no longer available.</div></div>;
  return <AnalysisWorkspace key={clip.id} composition={composition.data} clip={clip} recording={recording.data} />;
}

function AnalysisWorkspace({ composition, clip: initialClip, recording }: { composition: VideoComposition; clip: CompositionClip; recording: Recording }) {
  const navigate = useNavigate();
  const [engine] = useState<AnalysisEngine>(() => createAnalysisEngine(initialClip));
  const state = useStore(engine);
  const clip = state.clip;
  const frozen = clip.freezeDuration != null;
  const annotationEnd = clipAnnotationEnd(clip);

  /* Playback: one sequence player over this clip only; annotations never rebuild it. */
  const playbackClip = useMemo<CompositionClip>(() => ({ ...initialClip, startSeconds: clip.startSeconds, endSeconds: clip.endSeconds, rate: clip.rate, freezeDuration: clip.freezeDuration, annotations: [] }), [initialClip, clip.startSeconds, clip.endSeconds, clip.rate, clip.freezeDuration]);
  const clips = useMemo(() => [playbackClip], [playbackClip]);
  const recordings = useMemo(() => [recording], [recording]);
  const { sources } = useRecordingSources(recordings);
  const { player, state: playback } = useSequencePlayer(clips, sources);
  const [time, setTime] = useState(clip.startSeconds);
  useEffect(() => player.onTime((sample) => setTime(frozen ? clip.startSeconds + sample.outputTime : sample.sourceTime)), [player, frozen, clip.startSeconds]);
  const toOutput = useCallback((source: number) => (frozen ? source - clip.startSeconds : player.outputTimeFor(clip.id, source) ?? source - clip.startSeconds), [player, frozen, clip.id, clip.startSeconds]);
  const seek = useCallback((value: number) => player.seek(toOutput(Math.min(annotationEnd, Math.max(clip.startSeconds, value)))), [player, toOutput, annotationEnd, clip.startSeconds]);
  const previewSeek = useCallback((value: number) => player.previewSeek(toOutput(Math.min(annotationEnd, Math.max(clip.startSeconds, value)))), [player, toOutput, annotationEnd, clip.startSeconds]);
  const pause = useCallback(() => player.pause(), [player]);
  const togglePlayback = useCallback(() => {
    if (player.isPlaying) player.pause();
    else player.playRange(toOutput(time >= annotationEnd - 0.04 ? clip.startSeconds : time), null);
  }, [player, toOutput, time, annotationEnd, clip.startSeconds]);
  const previewEffect = useCallback((start: number, end: number) => player.playRange(toOutput(start), toOutput(end)), [player, toOutput]);
  const isPlaying = playback.isPlaying;
  const video = player.activeElement;
  const displayAspect = video?.videoWidth ? video.videoWidth / video.videoHeight : recording.width && recording.height ? recording.width / recording.height : 16 / 9;

  const tracking = useTracking(engine, seek, pause);

  /* Tappable players on the paused frame. The vision API has no single-frame detector yet, so the canvas
     offers the saved tracks' boxes at the current time; a detector can feed this list later. */
  const detections = useMemo<Rect[]>(() => [], []);
  const requestDetections = useCallback(() => {}, []);

  /* Selected player follows the playhead. */
  useEffect(() => {
    const s = engine.getState();
    const selected = s.clip.annotations.find((a) => a.id === s.selectedID);
    if (selected?.playerMotion) { const box = boxAt(selected.playerMotion, time); if (box) s.setSelectedPlayer({ time, box }); return; }
    if (selected && !selected.playerMotion && selected.playerEffectBox) { s.setSelectedPlayer({ time, box: selected.playerEffectBox }); return; }
    if (!selected && s.selectedPlayerTrackID) { const saved = s.clip.trackingLibrary?.players.find((p) => p.id === s.selectedPlayerTrackID); const box = saved ? boxAt(saved.motion, time) : null; if (box) { s.setSelectedPlayer({ time, box }); return; } }
    if (s.selectedPlayer && Math.abs(s.selectedPlayer.time - time) > 0.05) s.setSelectedPlayer(null);
  }, [engine, time]);

  const activePlayer = playerForSelection(engine);
  const selected = clip.annotations.find((a) => a.id === state.selectedID) ?? null;
  const effectLayers = playerEffectLayers(state, time, isActiveInEditor);
  const selectedPlayerName = clip.trackingLibrary?.players.find((p) => p.id === state.selectedPlayerTrackID)?.name ?? "Player";

  const openPlayerEffects = (player: AnalysisTrackingLibraryPlayer | null) => {
    pause();
    if (!player) { state.openSheet("playerEffects"); return; }
    const range: [number, number] = selected ? [selected.start, selected.end] : [clip.startSeconds, clip.endSeconds];
    let effectTime = time;
    if (!(boxAt(player.motion, time) && time >= range[0] && time <= range[1])) {
      const nearest = player.motion.samples.filter((s) => s.time >= range[0] && s.time <= range[1] && boxAt(player.motion, s.time)).sort((a, b) => Math.abs(a.time - time) - Math.abs(b.time - time))[0];
      if (!nearest) { state.setError("This player has no tracking inside this layer's time range."); return; }
      effectTime = nearest.time;
    }
    state.setSelectedPlayer({ time: effectTime, box: boxAt(player.motion, effectTime) ?? { x: 0, y: 0, width: 0, height: 0 } }, player.id);
    if (effectTime !== time) seek(effectTime);
    state.openSheet("playerEffects");
  };

  const applyEffects = (options: Parameters<typeof state.applyPlayerEffects>[0]) => {
    const s = engine.getState();
    const sample = s.selectedPlayer;
    if (!sample || s.tracking) return;
    const savedByID = s.selectedPlayerTrackID ? s.clip.trackingLibrary?.players.find((p) => p.id === s.selectedPlayerTrackID) ?? null : null;
    const current = savedByID ? boxAt(savedByID.motion, time) : null;
    const saved = (savedByID && current && overlapRatio(current, sample.box) > 0.5 ? savedByID : null) ?? (s.clip.trackingLibrary ? playerMatching(s.clip.trackingLibrary, sample.box, time) : null);
    if (!frozen && !saved) { tracking.trackIndependentPlayer(sample.box, time, options); return; }
    s.applyPlayerEffects(options, new Set(effectLayers.map((a) => a.id)), sample.box, saved?.motion ?? null, time);
    s.setSelectedPlayer(s.selectedPlayer, saved?.id ?? null);
  };

  const chooseSavedPlayer = (player: AnalysisTrackingLibraryPlayer) => {
    const s = engine.getState();
    const layerID = s.playerPickerLayerID, mark = layerID ? s.clip.annotations.find((a) => a.id === layerID) : null;
    if (!layerID || !mark) {
      const at = boxAt(player.motion, time) ? time : player.motion.samples[0]?.time ?? time;
      const box = boxAt(player.motion, at);
      if (!box) return;
      s.setPicking(false); s.setCorrectingPlayer(false); s.clearConstruction();
      if (at !== time) seek(at);
      pause(); s.select(null, at); s.setSelectedPlayer({ time: at, box }, player.id);
      return;
    }
    const available = player.motion.samples.filter((sm) => sm.time >= mark.start && sm.time <= mark.end && boxAt(player.motion, sm.time)).sort((a, b) => Math.abs(a.time - time) - Math.abs(b.time - time));
    const nearest = available[0];
    if (!nearest) { s.setError("This player has no tracking inside this layer's time range."); return; }
    const bindTime = boxAt(player.motion, time) && time >= mark.start && time <= mark.end ? time : nearest.time;
    if (s.followSavedPlayer(player, layerID, bindTime)) { const box = boxAt(player.motion, bindTime); if (box) s.setSelectedPlayer({ time: bindTime, box }, player.id); seek(bindTime); }
  };

  const pickLayerPlayer = () => {
    const s = engine.getState();
    const mark = selected;
    s.openSheet(null);
    if (!mark || mark.isLocked === true) return;
    pause(); s.setCorrectingPlayer(true); s.setShowsPlayers(true);
    if (time < mark.start || time >= mark.end) seek(mark.start);
  };

  const [fieldOpen, setFieldOpen] = useState(false);
  const openMeasurements = () => { pause(); setFieldOpen(true); };
  const toggleFieldPreview = () => {
    if (!clip.groundCalibration) { state.setFieldPreview(true); openMeasurements(); return; }
    const next = !state.fieldPreviewEnabled;
    state.setFieldPreview(next);
    if (next && clip.groundCalibration.fixedCamera === false) tracking.ensureSharedCameraTracking();
  };

  const save = async () => {
    try {
      await repository.compositions.save({ ...composition, clips: composition.clips.map((c) => (c.id === clip.id ? clip : c)) });
      navigate(-1);
    } catch (error) { state.setError(error instanceof Error ? error.message : String(error)); }
  };

  const busy = state.tracking !== null;
  useKeyboardShortcuts(useMemo(() => ({
    enabled: state.sheet === null && !fieldOpen,
    chooseTool: (tool) => { pause(); engine.getState().chooseTool(tool); },
    togglePlayback,
    step: (frames) => { pause(); seek(time + frames / 30); },
    setIn: () => engine.getState().updateSelected((m) => ({ ...m, start: Math.max(clip.startSeconds, Math.min(time, m.end - 1 / 30)) })),
    setOut: () => engine.getState().updateSelected((m) => ({ ...m, end: Math.min(annotationEnd, Math.max(time, m.start + 1 / 30)) })),
    deleteSelection: () => { const s = engine.getState(); if (s.selectedKeyframe) s.deleteKeyframe(time); else if (s.selectedID) s.deleteLayer(s.selectedID); },
    undo: () => engine.getState().undo(),
    redo: () => engine.getState().redo(),
    escape: () => { const s = engine.getState(); if (s.constructionPoints.length) s.clearConstruction(); else if (s.pickingPlayerTrack) s.setPicking(false); else if (s.correctingPlayer) s.setCorrectingPlayer(false); else s.select(null, time); },
  }), [engine, state.sheet, fieldOpen, pause, togglePlayback, seek, time, clip.startSeconds, annotationEnd]));

  const [bodyRef, layout] = useLayoutMetrics<HTMLDivElement>();
  const landscape = layout.isLandscape && layout.width >= 640;
  const [workspaceSize, setWorkspaceSize] = useState<number | null>(null);
  const dividerDrag = useRef<{ start: number; size: number } | null>(null);
  const defaultWorkspace = landscape ? Math.min(390, Math.max(300, layout.width * 0.38)) : Math.max(260, Math.min(layout.height * 0.45, 320));
  const size = Math.max(landscape ? 300 : 260, Math.min(workspaceSize ?? defaultWorkspace, landscape ? Math.max(300, layout.width - 240) : Math.max(260, layout.height - 180)));

  const canvasHint = (() => {
    const s = state;
    if (s.pickingPlayerTrack) return s.placingPlayer && s.correctingTrackID ? `Tap or draw around ${selectedPlayerName} to place it at this frame` : s.correctingTrackID == null ? "Tap or draw around a new player to track" : "Tap or draw around the same player to continue its track";
    if (s.tool === "connection" || (s.tool === "zone" && s.areaUsesPlayers)) return "Tap players in order, then Finish";
    if (s.tool === "zone") return "Tap polygon corners, then Finish";
    if (s.tool === "zoom") return "Tap where to zoom · trim its layer to set the duration";
    if (s.tool === "loupe") return "Tap a player to follow, or tap anywhere for a static loupe";
    if (s.correctingPlayer) return "Tap or draw around the same player";
    if (s.tool === "select" && selected) return selected.tool === "zoom" ? "Drag the focus · Preview effect to see the zoom" : selected.keyframes.length ? "Scrub, then drag a handle to set a keyframe" : "";
    if (s.tool === "select") return "";
    if (s.tool === "player" || s.tool === "spotlight") return "Tap a player or draw around one";
    return s.tool === "text" ? "Tap to place text" : "";
  })();
  const inspecting = Math.abs(state.inspection.zoom - 1) > 0.01 || Math.hypot(state.inspection.center.x - 0.5, state.inspection.center.y - 0.5) > 0.01;
  const cameraStatus = hasFullCameraTrack(clip) ? "First to last frame · shared camera track" : (() => { const c = sharedCamera(clip.trackingLibrary); const first = c?.samples[0]?.time, last = c?.samples[c.samples.length - 1]?.time; return first == null || last == null ? "Camera not tracked yet" : `Partial coverage · ${formatTimecode(first - clip.startSeconds)}–${formatTimecode(last - clip.startSeconds)}`; })();

  return (
    <div className="an-screen" data-surface="dark">
      <header className="an-bar">
        <button type="button" className="an-icon-button" aria-label="Cancel analysis" data-testid="cancel-analysis-workspace" onClick={() => navigate(-1)}><AnalysisIcon.back /></button>
        <span className="an-bar-title">{frozen ? "Freeze frame" : "Analyse"}</span>
        <Menu label="Clip tracks" trigger={<AnalysisIcon.tracks />} side="down" disabled={busy || state.constructionPoints.length > 0}>
          {(close) => (
            <>
              {!frozen && <MenuItem close={close} onClick={() => engine.getState().setPicking(true)} icon={<AnalysisIcon.personPlus />}>Track new player</MenuItem>}
              {!frozen && <MenuItem close={close} onClick={() => tracking.trackAllPlayers()} icon={<AnalysisIcon.people />}>Track all players</MenuItem>}
              {!frozen && <MenuItem close={close} onClick={() => { pause(); engine.getState().openSheet("playerTracks"); }} icon={<AnalysisIcon.person2 />}>Manage player tracks</MenuItem>}
              <MenuItem close={close} onClick={openMeasurements} icon={<AnalysisIcon.ruler />}>Measurements &amp; ground</MenuItem>
              {!frozen && <div className="an-menu-title">Clip camera · shared by all layers</div>}
              {!frozen && <div className="an-menu-note">{cameraStatus}</div>}
              {!frozen && <MenuItem close={close} onClick={() => tracking.ensureSharedCameraTracking(hasFullCameraTrack(clip))} icon={<AnalysisIcon.camera />}>{hasFullCameraTrack(clip) ? "Re-track entire clip" : "Track entire clip"}</MenuItem>}
              {!frozen && selected && <MenuItem close={close} onClick={() => tracking.beginCameraTracking(time)} icon={<AnalysisIcon.link />}>Follow clip camera</MenuItem>}
            </>
          )}
        </Menu>
        <button type="button" className="an-icon-button" aria-label="Tools" title={`Tools · ${toolRegistry[state.tool].title}`} data-testid="analysis-tools" disabled={busy} onClick={() => { pause(); engine.getState().openSheet("tools"); }}><ToolIcon tool={state.tool} /></button>
        <button type="button" className="an-icon-button" aria-label="Drawing style" data-testid="analysis-drawing-style" onClick={() => engine.getState().openSheet("inspector")}><AnalysisIcon.sliders /></button>
        <button type="button" className="an-icon-button" aria-label="Save" data-testid="save-analysis-workspace" data-active="true" disabled={busy} onClick={save}><AnalysisIcon.check /></button>
      </header>
      <div ref={bodyRef} className="an-body" data-landscape={landscape}>
        <section className="an-preview" style={landscape ? undefined : { height: Math.max(120, layout.height - size - 12) }}>
          <SequencePreview player={player} aspectRatio="original" renderOverlay={(ctx) => (
            <OverlayCanvas engine={engine} time={time} isPlaying={isPlaying} size={ctx.size} displayAspect={displayAspect} video={player.activeElement} still={null} detections={detections}
              tracking={tracking} pause={pause} seek={seek} onError={(m) => engine.getState().setError(m)} onRequestDetections={requestDetections} />
          )}>
            <div className="an-transport">
              <button type="button" className="an-transport-button" aria-label="Previous frame" disabled={!playback.isReady} onClick={() => { pause(); seek(time - 1 / 30); }}><AnalysisIcon.stepBack /></button>
              <button type="button" className="an-transport-button" aria-label={isPlaying ? "Pause" : "Play"} data-testid="analysis-play-pause" disabled={!playback.isReady || frozen || busy || state.constructionPoints.length > 0} onClick={togglePlayback}>{isPlaying ? <AnalysisIcon.pause /> : <AnalysisIcon.play />}</button>
              <button type="button" className="an-transport-button" aria-label="Next frame" disabled={!playback.isReady} onClick={() => { pause(); seek(time + 1 / 30); }}><AnalysisIcon.stepForward /></button>
              <span className="an-time" data-testid="analysis-current-time">{formatTimecode(time - clip.startSeconds, true)} / {formatTimecode(annotationEnd - clip.startSeconds, true)}</span>
            </div>
          </SequencePreview>
          <div className="an-hint-row">
            {canvasHint && <span className="an-hint">{canvasHint}</span>}
            {inspecting && <button type="button" className="an-control" aria-label="Fit preview" data-testid="analysis-inspect-fit" onClick={() => engine.getState().setInspection(DEFAULT_INSPECTION)}><span><AnalysisIcon.fit /></span></button>}
          </div>
        </section>
        <div className="an-divider" data-vertical={landscape} role="separator" aria-label="Workspace" aria-orientation={landscape ? "vertical" : "horizontal"}
          onPointerDown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); dividerDrag.current = { start: landscape ? e.clientX : e.clientY, size }; }}
          onPointerMove={(e) => { const d = dividerDrag.current; if (!d) return; const delta = (landscape ? e.clientX : e.clientY) - d.start; setWorkspaceSize(d.size - delta); }}
          onPointerUp={() => { dividerDrag.current = null; }} />
        <section className="an-workspace" style={landscape ? { width: size } : { height: size }}>
          <TopStrip engine={engine} time={time} seek={seek} tracking={tracking} />
          <LayerTimeline annotations={clip.annotations} bounds={[clip.startSeconds, annotationEnd]} time={time} selectedID={state.selectedID} selectedKeyframe={state.selectedKeyframe}
            zoom={state.timelineZoom} setZoom={(z) => engine.getState().setTimelineZoom(z)}
            select={(id) => { pause(); engine.getState().select(id, time); const mark = clip.annotations.find((a) => a.id === id); if (mark && (time < mark.start || time >= mark.end)) seek(Math.min(annotationEnd - 0.02, Math.max(clip.startSeconds, mark.start))); }}
            seek={seek} previewSeek={previewSeek}
            beginEdit={() => { pause(); engine.getState().checkpoint(); }}
            edit={(mark, finished) => {
              const s = engine.getState();
              const previous = s.clip.annotations.find((a) => a.id === mark.id);
              s.editTimelineLayer(mark);
              const keyframe = mark.keyframes.find((k) => k.id === s.selectedKeyframe);
              if (keyframe && previous?.keyframes.find((k) => k.id === keyframe.id)?.time !== keyframe.time) seek(keyframe.time);
              if (!finished) return;
              if (mark.linkedPlayers && mark.linkedPlayers.every((l) => l.lostAt == null) && mark.linkedPlayers.some((l) => (l.samples[l.samples.length - 1]?.time ?? mark.start) < mark.end - 0.12)) {
                tracking.beginLinkedTracking(mark.id, mark.linkedPlayers.map((l) => l.samples[l.samples.length - 1]!).filter(Boolean)); return;
              }
              if (mark.cameraMotion && mark.cameraMotion.lostAt == null && (mark.cameraMotion.samples[mark.cameraMotion.samples.length - 1]?.time ?? mark.start) < mark.end - 0.15) { tracking.beginCameraTracking(time, false); return; }
              const motion = mark.playerMotion, last = motion?.samples[motion.samples.length - 1];
              if (motion && motion.lostAt == null && last && mark.end > last.time + 0.12) tracking.beginTracking(mark.id, last.box, last.time);
            }}
            selectKeyframe={(layer, keyframe, at) => { pause(); engine.getState().selectKeyframe(layer, keyframe); seek(at); }}
            toggleHidden={(id) => engine.getState().toggleHidden(id)} toggleLocked={(id) => engine.getState().toggleLocked(id)} reorder={(id, d) => engine.getState().reorder(id, d)}
            undo={state.undoStack.length ? () => engine.getState().undo() : null} redo={state.redoStack.length ? () => engine.getState().redo() : null}
            recordingID={recording.id} freezeTime={frozen ? clip.startSeconds : null} showsFilmstrip={false} />
          <BottomRow engine={engine} time={time} tracking={tracking} seek={seek} pause={pause} previewEffect={previewEffect} activePlayer={activePlayer} openPlayerEffects={openPlayerEffects} />
        </section>
      </div>

      {state.sheet === "tools" && <ToolPickerSheet tool={state.tool} fieldPreview={state.fieldPreviewEnabled} hasField={!!clip.groundCalibration} choose={(tool) => { const s = engine.getState(); if (tool === "player" && s.selectedPlayer) { s.openSheet("playerEffects"); return; } s.chooseTool(tool); }} measure={openMeasurements} field={toggleFieldPreview} onClose={() => engine.getState().openSheet(null)} />}
      {state.sheet === "inspector" && <InspectorSheet engine={engine} time={time} onClose={() => engine.getState().openSheet(null)} previewEffect={(mark) => previewEffect(mark.start, mark.end)}
        onEditTiming={(mark) => {
          if (mark.linkedPlayers || mark.cameraMotion) return;
          const motion = mark.playerMotion, last = motion?.samples[motion.samples.length - 1];
          if (motion && motion.lostAt == null && last && mark.end > last.time + 0.12) tracking.beginTracking(mark.id, last.box, last.time);
        }} />}
      {state.sheet === "playerTracks" && (
        <PlayerTracksSheet players={clip.trackingLibrary?.players ?? []} clipStart={clip.startSeconds} clipEnd={clip.endSeconds} selectedID={selected?.playerMotion?.trackID ?? state.selectedPlayerTrackID} choosingForLayer={state.playerPickerLayerID !== null}
          onSelect={chooseSavedPlayer} onAdd={() => { if (state.playerPickerLayerID) pickLayerPlayer(); else engine.getState().setPicking(true); }} onTrackAll={() => tracking.trackAllPlayers()}
          onCorrect={(id) => engine.getState().setPicking(true, id)} onTrackToEnd={(id) => tracking.trackPlayerToEnd(id)} onTrackWholeClip={(id) => tracking.trackPlayerBackward(id, true, time)}
          onRename={(id, name) => engine.getState().renamePlayerTrack(id, name)} onRemove={(id) => engine.getState().removePlayerTrack(id)} canRemove={(id) => !clip.annotations.some((a) => a.playerMotion?.trackID === id || a.linkedPlayers?.some((l) => l.trackID === id))}
          onClose={() => engine.getState().openSheet(null)} />
      )}
      {state.sheet === "playerTracking" && activePlayer && (
        <PlayerTrackingSheet player={activePlayer} clipRange={[clip.startSeconds, clip.endSeconds]} time={time} isBusy={busy} layer={selected?.playerMotion ? selected : null}
          onTrackWholeClip={() => tracking.trackPlayerBackward(activePlayer.id, true, time)} onTrackToEnd={() => tracking.trackPlayerToEnd(activePlayer.id)} onTrackBackToStart={() => tracking.trackPlayerBackward(activePlayer.id, false, time)}
          onFixFromHere={() => engine.getState().setPicking(true, activePlayer.id)} onPlaceHere={() => engine.getState().setPicking(true, activePlayer.id, true)} seek={seek}
          onBridge={(v) => { if (selected) { engine.getState().checkpoint(); engine.getState().setGapBridging(v); } }} onSmoothing={(v) => { if (selected) { engine.getState().checkpoint(); engine.getState().setTrackingSmoothing(v); } }}
          onRename={(name) => engine.getState().renamePlayerTrack(activePlayer.id, name)} onRemove={clip.annotations.some((a) => a.playerMotion?.trackID === activePlayer.id || a.linkedPlayers?.some((l) => l.trackID === activePlayer.id)) ? null : () => engine.getState().removePlayerTrack(activePlayer.id)}
          onClose={() => engine.getState().openSheet(null)} />
      )}
      {state.sheet === "playerEffects" && <PlayerEffectsSheet name={selectedPlayerName} existing={effectLayers} allowsTrajectory={!frozen} measurementStatus={measurementStatus(clip.groundCalibration)} apply={applyEffects} onClose={() => engine.getState().openSheet(null)} />}
      {fieldOpen && (
        <Sheet title="Field" onClose={() => setFieldOpen(false)} tall>
          <GroundCalibrationSheet clip={clip} time={frozen ? clip.startSeconds : clip.groundCalibration?.referenceTime ?? time} onClose={() => setFieldOpen(false)} onApply={(calibration) => {
            setFieldOpen(false);
            engine.getState().setGroundCalibration(calibration);
            if (calibration && !frozen) seek(calibration.referenceTime);
            if (calibration && !calibration.fixedCamera && !frozen) tracking.ensureSharedCameraTracking();
          }} />
        </Sheet>
      )}
      {state.error && <div className="an-toast" role="alert"><span>{state.error}</span><button type="button" onClick={() => engine.getState().setError(null)}>OK</button></div>}
    </div>
  );
}

function overlapRatio(a: Rect, b: Rect): number {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.width, b.x + b.width) - x, h = Math.min(a.y + a.height, b.y + b.height) - y;
  if (w <= 0 || h <= 0) return 0;
  const inter = w * h;
  return inter / Math.max(1e-9, a.width * a.height + b.width * b.height - inter);
}
