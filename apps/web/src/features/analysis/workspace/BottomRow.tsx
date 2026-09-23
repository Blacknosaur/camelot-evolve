import { useStore } from "zustand";
import { annotationCss } from "@/domain/annotation";
import type { UUID } from "@/domain/ids";
import type { AnalysisTrackingLibraryPlayer } from "@/domain/tracking";
import { isMissing, missingIntervals } from "@/features/analysis/tracking/motion";
import { playerKitColor, playerNumber } from "@/features/analysis/tracking/library";
import type { AnalysisEngine } from "../model/engine";
import { connectionAnchors, motionMode, motionModeTitle, insertPolygonCorner, removePolygonCorner } from "../model/annotation";
import { AnalysisIcon } from "./icons";
import { Menu, MenuItem } from "./Menu";
import { formatTimecode } from "./format";
import type { TrackingController } from "./useTracking";

/* The single bottom row of the workspace (port of `analysisWorkspace` in AnalysisOverlayView.swift):
   exactly one of the running pass, the pick prompt, the correction row, the player bar, the new-player
   bar or the selected layer's controls. `TopStrip` holds what sits above the timeline. */

export interface RowProps {
  engine: AnalysisEngine;
  time: number;
  tracking: TrackingController;
  seek(time: number): void;
  pause(): void;
  previewEffect(start: number, end: number): void;
  activePlayer: AnalysisTrackingLibraryPlayer | null;
  openPlayerEffects(player: AnalysisTrackingLibraryPlayer | null): void;
}

export function TopStrip({ engine, time, seek, tracking }: Pick<RowProps, "engine" | "time" | "seek" | "tracking">) {
  const s = useStore(engine);
  const selected = s.clip.annotations.find((a) => a.id === s.selectedID) ?? null;
  const anchors = selected?.linkedPlayers ? connectionAnchors(selected, time, (id, i) => s.clip.trackingLibrary?.players.find((p) => p.id === id)?.name ?? `Player ${i + 1}`) : [];
  const correcting = anchors.find((a) => a.id === s.correctingAnchor);
  const constructing = s.tool === "connection" || s.tool === "zone";
  return (
    <>
      {s.correctingPlayer && correcting && (
        <div className="an-row" data-testid="analysis-connection-correction">
          <div className="grow" style={{ display: "flex", flexDirection: "column", gap: 3 }}>
            <span className="an-caption" style={{ color: "var(--event-foul)" }}>Reselect {correcting.title}</span>
            <span className="an-caption secondary">{correcting.lastSeen ? `Reference: ${formatTimecode(correcting.lastSeen.time - s.clip.startSeconds, true)} · same player` : "Choose the same player for this numbered endpoint."}</span>
          </div>
          {correcting.lastSeen && <button type="button" className="an-control" aria-label="Show last confirmed frame" data-testid="analysis-anchor-last-seen" onClick={() => seek(correcting.lastSeen!.time)}><span><AnalysisIcon.stepBack /></span></button>}
        </div>
      )}
      {constructing && (
        <div className="an-row" style={{ minHeight: 40 }}>
          {s.tool === "zone" && (
            <label className="an-caption" style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
              <input type="checkbox" checked={s.areaUsesPlayers} onChange={(e) => s.setAreaUsesPlayers(e.target.checked)} /> Players
            </label>
          )}
          <span className="an-caption secondary" data-testid="analysis-construction-count">{s.constructionPoints.length} {s.tool === "connection" || s.areaUsesPlayers ? "player" : "corner"}{s.constructionPoints.length === 1 ? "" : "s"}</span>
          <span className="grow" />
          <button type="button" className="an-control" aria-label="Remove last point" disabled={s.constructionPoints.length === 0} onClick={() => s.removeLastConstructionPoint()}><span><AnalysisIcon.undo /></span></button>
          <FinishButton engine={engine} time={time} tracking={tracking} />
        </div>
      )}
      {selected?.linkedPlayers && !s.correctingPlayer && (
        <div className="an-anchor-strip" data-testid="analysis-connection-players">
          {anchors.map((anchor) => (
            <button key={anchor.id} type="button" className="an-anchor" data-selected={s.correctingAnchor === anchor.id} data-missing={anchor.isMissing} disabled={s.tracking !== null || selected.isLocked === true} data-testid={`analysis-correct-anchor-${anchor.id}`}
              aria-label={`Correct ${anchor.title}, ${anchor.isMissing ? "needs correction" : "tracked"}`} onClick={() => s.setCorrectingPlayer(true, anchor.id)}>
              <span className="num">{anchor.id + 1}</span>
              <span>{anchor.name}<small>{anchor.isMissing ? "Needs correction" : "Tracked"}</small></span>
            </button>
          ))}
        </div>
      )}
    </>
  );
}

function FinishButton({ engine, time, tracking }: { engine: AnalysisEngine; time: number; tracking: TrackingController }) {
  const s = useStore(engine);
  const needed = s.tool === "zone" ? 3 : 2;
  return <button type="button" className="an-control" data-prominent="true" data-testid="analysis-finish-construction" disabled={s.constructionPoints.length < needed} onClick={() => { const result = s.finishConstruction(time); if (result && result.seeds.length > 0 && s.clip.freezeDuration == null) tracking.beginLinkedTracking(result.mark.id, result.seeds); }}><span>Finish</span></button>;
}

export function BottomRow(p: RowProps) {
  const s = useStore(p.engine);
  const selected = s.clip.annotations.find((a) => a.id === s.selectedID) ?? null;
  const frozen = s.clip.freezeDuration != null;
  const busy = s.tracking !== null;

  if (s.tracking) {
    return (
      <div className="an-row">
        <div className="an-progress"><i style={{ width: `${Math.round(s.tracking.progress * 100)}%` }} /></div>
        <span className="an-caption mono">{s.tracking.label} · {Math.round(s.tracking.progress * 100)}%</span>
        <span className="grow" />
        <button type="button" className="an-control" onClick={() => p.tracking.cancel()}><span>Cancel</span></button>
      </div>
    );
  }
  if (s.pickingPlayerTrack) {
    return (
      <div className="an-row">
        <span className="an-caption">{s.placingPlayer && s.correctingTrackID ? "Place player here" : s.correctingTrackID == null ? "New player track" : "Correct player track"}</span>
        <span className="grow" />
        <button type="button" className="an-control" onClick={() => s.setPicking(false)}><span>Cancel pick</span></button>
      </div>
    );
  }
  if (selected && s.correctingPlayer && !selected.linkedPlayers) {
    return (
      <div className="an-row">
        <span className="an-caption">Tap or draw around the player</span>
        <span className="grow" />
        <button type="button" className="an-control" data-testid="analysis-correct-tracking" onClick={() => s.setCorrectingPlayer(false)}><span>Cancel pick</span></button>
      </div>
    );
  }

  const layerMenu = selected && (
    <Menu label="Layer actions" trigger={<AnalysisIcon.more />}>
      {(close) => (
        <>
          <MenuItem close={close} onClick={() => s.openSheet("inspector")} icon={<AnalysisIcon.sliders />}>Layer style</MenuItem>
          {selected.playerMotion && <MenuItem close={close} onClick={() => s.openSheet("playerTracks", selected.id)} icon={<AnalysisIcon.person2 />}>Follow another player</MenuItem>}
          {selected.playerMotion && <MenuItem close={close} onClick={() => s.setMotionMode("still", p.time)} icon={<AnalysisIcon.pause />}>Stop following · keep position</MenuItem>}
          {!frozen && <MenuItem close={close} onClick={() => p.previewEffect(selected.start, selected.end)} icon={<AnalysisIcon.play />}>Preview effect</MenuItem>}
          <MenuItem close={close} onClick={() => s.duplicate()} icon={<AnalysisIcon.duplicate />}>Duplicate</MenuItem>
          {!frozen && !selected.playerMotion && <MenuItem close={close} disabled={selected.isLocked === true} onClick={() => p.tracking.beginCameraTracking(p.time)} icon={<AnalysisIcon.camera />}>Follow clip camera</MenuItem>}
          <MenuItem close={close} onClick={() => s.toggleLocked(selected.id)} icon={<AnalysisIcon.lock />}>{selected.isLocked === true ? "Unlock layer" : "Lock layer"}</MenuItem>
          <MenuItem close={close} destructive disabled={selected.isLocked === true} onClick={() => s.deleteLayer(selected.id)} icon={<AnalysisIcon.trash />}>Delete layer</MenuItem>
        </>
      )}
    </Menu>
  );

  if (p.activePlayer) {
    const player = p.activePlayer, kit = playerKitColor(player), number = playerNumber(player);
    const missing = missingIntervals(player.motion, [s.clip.startSeconds, s.clip.endSeconds]);
    return (
      <div className="an-row">
        <button type="button" className="an-control" data-testid="analysis-active-player-track" style={{ padding: 0 }} onClick={() => { p.pause(); s.openSheet("playerTracks", selected?.playerMotion ? selected.id : null); }}>
          <span style={{ background: "transparent", border: 0 }}><i className="an-swatch" style={{ background: kit ? annotationCss(kit) : "rgb(255 255 255 / 0.2)" }} />{number ? `${player.name} · #${number}` : player.name}</span>
        </button>
        <span className="grow" />
        <button type="button" className="an-control" data-testid="analysis-player-effects" disabled={busy} onClick={() => p.openPlayerEffects(player)}><span><AnalysisIcon.sparkles />Effects</span></button>
        <button type="button" className="an-control" data-testid="analysis-player-tracking" data-prominent={isMissing(player.motion, p.time) || undefined} disabled={busy} title={missing.length ? `${missing.length} untracked sections` : "Tracked for the whole clip"} onClick={() => { p.pause(); s.openSheet("playerTracking"); }}><span><AnalysisIcon.run />Tracking</span></button>
        {layerMenu}
      </div>
    );
  }

  if (s.selectedPlayer && !selected) {
    return (
      <div className="an-row">
        <span className="an-caption"><AnalysisIcon.personPlus style={{ verticalAlign: "middle", marginRight: 6 }} />New player</span>
        <span className="grow" />
        <button type="button" className="an-control" data-testid="analysis-player-effects" onClick={() => p.openPlayerEffects(null)}><span><AnalysisIcon.sparkles />Effects</span></button>
        <button type="button" className="an-control" data-prominent="true" data-testid="analysis-track-selected-player" disabled={frozen} onClick={() => p.tracking.trackIndependentPlayer(s.selectedPlayer!.box, p.time)}><span><AnalysisIcon.run />Track</span></button>
      </div>
    );
  }

  if (!selected) return null;
  const mode = motionMode(selected);
  const locked = selected.isLocked === true;
  return (
    <div className="an-row-stack">
      <div className="an-row">
        {selected.tool === "trajectory" ? <span className="an-caption grow"><AnalysisIcon.run style={{ verticalAlign: "middle", marginRight: 6 }} />Follows player track</span> : (
          <Menu label="Layer motion" align="left" disabled={locked} trigger={<><AnalysisIcon.move />{motionModeTitle(mode)}</>}>
            {(close) => (
              <>
                <MenuItem close={close} onClick={() => s.setMotionMode("still", p.time)} icon={<AnalysisIcon.pause />}>Static</MenuItem>
                <MenuItem close={close} onClick={() => s.setMotionMode("keyframes", p.time)} icon={<AnalysisIcon.diamond />}>Keyframes</MenuItem>
                {!frozen && <MenuItem close={close} onClick={() => { if (s.setMotionMode("player", p.time) === "pickPlayer") p.pause(); }} icon={<AnalysisIcon.run />}>Follow player</MenuItem>}
                {!frozen && <MenuItem close={close} onClick={() => p.tracking.beginCameraTracking(p.time)} icon={<AnalysisIcon.camera />}>Follow clip camera</MenuItem>}
              </>
            )}
          </Menu>
        )}
        <span className="grow" />
        {mode === "camera" && !frozen && <button type="button" className="an-transport-button" aria-label="Re-track camera" data-testid="analysis-correct-tracking" disabled={locked} onClick={() => p.tracking.ensureSharedCameraTracking(true)}><AnalysisIcon.scope /></button>}
        {selected.tool !== "trajectory" && <button type="button" className="an-control" onClick={() => s.openSheet("inspector")}><span><AnalysisIcon.sliders />Style</span></button>}
        {layerMenu}
      </div>
      {selected.tool === "zone" && selected.fieldLines !== true && !selected.linkedPlayers && (
        <div className="an-row">
          <span className="an-caption secondary">{s.selectedVertex != null ? `Corner ${s.selectedVertex + 1}` : "Tap a corner to edit"}</span>
          <span className="grow" />
          <button type="button" className="an-control" disabled={locked || selected.points.length >= 12} onClick={() => { const index = s.selectedVertex ?? Math.max(0, selected.points.length - 1); s.updateSelected((m) => insertPolygonCorner(m, index)); s.setSelectedVertex(index + 1); }}><span><AnalysisIcon.plus />Add corner</span></button>
          <button type="button" className="an-control" aria-label="Remove corner" disabled={locked || s.selectedVertex == null || selected.points.length <= 3} onClick={() => { if (s.selectedVertex != null) { s.updateSelected((m) => removePolygonCorner(m, s.selectedVertex!)); s.setSelectedVertex(null); } }}><span>−</span></button>
        </div>
      )}
      {mode === "keyframes" && (
        <div className="an-row">
          <fieldset disabled={locked || p.time < selected.start || p.time > selected.end} style={{ display: "contents", border: 0, padding: 0, margin: 0 }}>
            <button type="button" className="an-control" aria-label="Previous keyframe" onClick={() => { const r = s.stepKeyframe(-1, p.time); if (r) p.seek(r.time); }}><span><AnalysisIcon.stepBack /></span></button>
            <button type="button" className="an-control" data-testid="analysis-add-keyframe" onClick={() => { p.pause(); s.addKeyframe(p.time); }}><span><AnalysisIcon.diamond />Add keyframe</span></button>
            <button type="button" className="an-control" aria-label="Next keyframe" onClick={() => { const r = s.stepKeyframe(1, p.time); if (r) p.seek(r.time); }}><span><AnalysisIcon.stepForward /></span></button>
            <span className="grow" />
            <button type="button" className="an-control" aria-label="Delete keyframe" disabled={s.selectedKeyframe == null} onClick={() => s.deleteKeyframe(p.time)}><span><AnalysisIcon.trash /></span></button>
          </fieldset>
        </div>
      )}
    </div>
  );
}

export const playerForSelection = (engine: AnalysisEngine): AnalysisTrackingLibraryPlayer | null => {
  const s = engine.getState();
  const selected = s.clip.annotations.find((a) => a.id === s.selectedID);
  const id: UUID | null | undefined = selected ? selected.playerMotion?.trackID : s.selectedPlayerTrackID;
  if ((selected && !selected.playerMotion) || !id) return null;
  return s.clip.trackingLibrary?.players.find((p) => p.id === id) ?? null;
};
