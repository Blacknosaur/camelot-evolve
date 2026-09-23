import { useState } from "react";
import type { AnalysisAnnotation, AnalysisDrawingTool, AnnotationEffect } from "@/domain/annotation";
import { annotationCss } from "@/domain/annotation";
import type { UUID } from "@/domain/ids";
import type { AnalysisTrackingLibraryPlayer, PlayerMotion, TimeRange } from "@/domain/tracking";
import { isMissing, missingIntervals, nextMissing, previousMissing } from "@/features/analysis/tracking/motion";
import { playerKitColor, playerNumber } from "@/features/analysis/tracking/library";
import { playerEffectOptions, playerEffectTools, type PlayerEffectOptions } from "../model/player-effects";
import { FieldButton, Section, Sheet, Toggle, Segmented } from "./Sheet";
import { ColorField, LoupeControls, TextControls, TrackingBridgeControls, TrackingSmoothingControls, TrajectoryControls } from "./controls";
import { AnalysisIcon } from "./icons";
import { Menu, MenuItem } from "./Menu";
import { formatTimecode } from "./format";

/* Ports of AnalysisPlayerEffectsSheet.swift, AnalysisPlayerTracksSheet.swift and AnalysisPlayerTrackingSheet.swift. */

const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export function PlayerEffectsSheet({ name, existing, allowsTrajectory, measurementStatus, apply, onClose }: { name: string; existing: AnalysisAnnotation[]; allowsTrajectory: boolean; measurementStatus: string | null; apply(options: PlayerEffectOptions): void; onClose(): void }) {
  const [options, setOptions] = useState(() => playerEffectOptions(existing, name));
  const [page, setPage] = useState<"main" | "loupe" | "text" | "trail">("main");
  const locked = (tool: AnalysisDrawingTool) => existing.some((a) => a.tool === tool && a.isLocked === true);
  const set = (patch: Partial<PlayerEffectOptions>) => setOptions((o) => ({ ...o, ...patch }));
  const ringStyles: AnnotationEffect[] = ["clean", "neon", "pulse", "radar"];
  if (page !== "main") {
    return (
      <Sheet title={page === "loupe" ? "Loupe" : page === "text" ? "Text formatting" : "Trajectory"} onClose={() => setPage("main")} actionTitle="Back" tall>
        <Section>
          {page === "loupe" && <LoupeControls style={options.loupeStyle} onChange={(loupeStyle) => set({ loupeStyle })} beginEdit={() => {}} disabled={locked("loupe")} />}
          {page === "text" && <TextControls style={options.textStyle} onChange={(textStyle) => set({ textStyle })} disabled={locked("text")} />}
          {page === "trail" && <TrajectoryControls style={options.trajectoryStyle} onChange={(trajectoryStyle) => set({ trajectoryStyle })} disabled={locked("trajectory")} />}
        </Section>
      </Sheet>
    );
  }
  return (
    <Sheet title={name} onClose={onClose} cancel={onClose} actionTitle={existing.length === 0 ? "Add" : "Apply"} actionDisabled={existing.length === 0 && playerEffectTools(options).length === 0} onAction={() => { apply(options); onClose(); }} tall>
      <Section title="Player effects" footer="Combine any options. They share one player track, with separate layers for timing and placement.">
        <Toggle label="Ring" checked={options.ring} disabled={locked("player")} onChange={(ring) => set({ ring })} id="analysis-player-ring" />
        {options.ring && <div className="an-field column"><span>Ring style</span><Segmented options={ringStyles.map((e) => ({ value: e, label: capitalize(e) }))} value={options.ringStyle} onChange={(ringStyle) => set({ ringStyle })} title={capitalize} disabled={locked("player")} /></div>}
        <Toggle label="Spotlight" checked={options.spotlight} disabled={locked("spotlight")} onChange={(spotlight) => set({ spotlight })} id="analysis-player-spotlight" />
        {options.spotlight && <div className="an-field column"><span>Spotlight style</span><Segmented options={[{ value: "neon" as const, label: "Sky beam" }, { value: "pulse" as const, label: "Pulse" }, { value: "clean" as const, label: "Dim background" }]} value={options.spotlightStyle} onChange={(spotlightStyle) => set({ spotlightStyle })} title={capitalize} disabled={locked("spotlight")} /></div>}
        <Toggle label="Loupe" checked={options.loupe} disabled={locked("loupe")} onChange={(loupe) => set({ loupe })} id="analysis-player-loupe" />
        {options.loupe && <FieldButton onClick={() => setPage("loupe")}>Loupe settings</FieldButton>}
        <Toggle label="Name label" checked={options.label} disabled={locked("text")} onChange={(label) => set({ label })} id="analysis-player-label" />
        {options.label && (
          <>
            <div className="an-field"><input type="text" placeholder="Player name or number" value={options.text} disabled={locked("text")} aria-label="Player name or number" onChange={(e) => set({ text: e.target.value })} /></div>
            {allowsTrajectory && <Toggle label="Show speed · km/h" checked={options.showsSpeed} disabled={locked("text")} onChange={(showsSpeed) => set({ showsSpeed })} />}
            {allowsTrajectory && options.showsSpeed && <p style={{ margin: "0 12px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>{measurementStatus ?? "Set a reference in Measurements to show speed. Until calibrated, the label shows —."}</p>}
            <FieldButton onClick={() => setPage("text")}>Text formatting</FieldButton>
          </>
        )}
      </Section>
      {(allowsTrajectory || options.trajectory) && (
        <Section title="Movement trail">
          <Toggle label="Trajectory" checked={options.trajectory} disabled={locked("trajectory")} onChange={(trajectory) => set({ trajectory })} id="analysis-player-trajectory" />
          {options.trajectory && <FieldButton onClick={() => setPage("trail")}>Trail settings</FieldButton>}
        </Section>
      )}
      <Section title="Appearance" footer="Locked layers are unchanged. Use each layer's Drawing style controls for finer adjustments.">
        <ColorField label="Color" color={options.color} onChange={(color) => set({ color })} />
      </Section>
    </Sheet>
  );
}

function coverage(motion: PlayerMotion, clipStart: number, clipEnd: number): string {
  const start = formatTimecode((motion.samples[0]?.time ?? clipStart) - clipStart, true);
  const end = formatTimecode((motion.samples[motion.samples.length - 1]?.time ?? clipStart) - clipStart, true);
  const missing = missingIntervals(motion, [clipStart, clipEnd]).length;
  let status = `${start} – ${end}`;
  if (motion.lostAt != null) status += " · Needs correction";
  else if (missing > 0) status += ` · ${missing} ${missing === 1 ? "gap" : "gaps"}`;
  return status;
}

function Swatch({ player, selected }: { player: AnalysisTrackingLibraryPlayer; selected: boolean }) {
  const kit = playerKitColor(player);
  return (
    <span className="an-swatch" style={{ width: 26, height: 26, background: kit ? annotationCss(kit) : "rgb(255 255 255 / 0.12)", display: "inline-flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 12 }}>
      {selected ? "✓" : null}
    </span>
  );
}

export function PlayerTracksSheet({ players, clipStart, clipEnd, selectedID, choosingForLayer, onSelect, onAdd, onTrackAll, onCorrect, onTrackToEnd, onTrackWholeClip, onRename, onRemove, canRemove, onClose }: {
  players: AnalysisTrackingLibraryPlayer[]; clipStart: number; clipEnd: number; selectedID: UUID | null; choosingForLayer: boolean;
  onSelect(player: AnalysisTrackingLibraryPlayer): void; onAdd(): void; onTrackAll(): void; onCorrect(id: UUID): void; onTrackToEnd(id: UUID): void; onTrackWholeClip(id: UUID): void; onRename(id: UUID, name: string): void; onRemove(id: UUID): void; canRemove(id: UUID): boolean; onClose(): void;
}) {
  const [renaming, setRenaming] = useState<UUID | null>(null);
  const [draft, setDraft] = useState("");
  return (
    <Sheet title={choosingForLayer ? "Follow player" : "Player tracks"} onClose={onClose} tall>
      <Section footer="Track all follows everyone in the clip at once and remembers each player's kit and shirt number, so a player who leaves the picture keeps the same identity on return.">
        <FieldButton onClick={() => { onClose(); onTrackAll(); }} icon={<AnalysisIcon.people />}>Track all players</FieldButton>
        <FieldButton onClick={() => { onClose(); onAdd(); }} icon={<AnalysisIcon.personPlus />}>Track new player</FieldButton>
      </Section>
      <Section title={`Saved players · ${players.length}`} footer="Tracks are reused across effects. Choosing a saved player does not run tracking again. Players used by a drawing cannot be removed.">
        {players.length === 0 && <div className="an-field"><span style={{ color: "var(--fg-secondary)" }}>Track players once, then reuse their motion for rings, spotlights, labels and connections.</span></div>}
        {players.map((player) => (
          <div key={player.id} className="an-player-row">
            {renaming === player.id ? (
              <>
                <input type="text" value={draft} autoFocus aria-label="Name" onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { onRename(player.id, draft); setRenaming(null); } if (e.key === "Escape") setRenaming(null); }} style={{ flex: 1, padding: "8px 10px", borderRadius: 8, border: "1px solid var(--ink-stroke)", background: "rgb(0 0 0 / 0.3)", color: "var(--fg)" }} />
                <button type="button" className="an-control" onClick={() => { onRename(player.id, draft); setRenaming(null); }}><span>Save</span></button>
              </>
            ) : (
              <>
                <button type="button" className="grow" data-testid={`analysis-use-player-${player.id}`} onClick={() => { onSelect(player); onClose(); }}>
                  <Swatch player={player} selected={selectedID === player.id} />
                  <span style={{ display: "flex", flexDirection: "column", gap: 2, minWidth: 0 }}>
                    <span className="name">{player.name} {playerNumber(player) && <span className="an-badge">#{playerNumber(player)}</span>}</span>
                    <span className="meta">{coverage(player.motion, clipStart, clipEnd)}</span>
                  </span>
                </button>
                {!choosingForLayer && (
                  <Menu label="Player options" trigger={<AnalysisIcon.more />} side="down">
                    {(close) => (
                      <>
                        <MenuItem close={close} onClick={() => { onClose(); onCorrect(player.id); }} icon={<AnalysisIcon.scope />}>Correct track</MenuItem>
                        <MenuItem close={close} onClick={() => { onClose(); onTrackWholeClip(player.id); }}>Track whole clip</MenuItem>
                        {((player.motion.samples[player.motion.samples.length - 1]?.time ?? clipEnd) < clipEnd - 0.1 || player.motion.lostAt != null) && <MenuItem close={close} onClick={() => { onClose(); onTrackToEnd(player.id); }}>Track to end of clip</MenuItem>}
                        <MenuItem close={close} onClick={() => { setRenaming(player.id); setDraft(player.name); }} icon={<AnalysisIcon.pencil />}>Rename</MenuItem>
                        {canRemove(player.id) && <MenuItem close={close} destructive onClick={() => onRemove(player.id)} icon={<AnalysisIcon.trash />}>Remove track</MenuItem>}
                      </>
                    )}
                  </Menu>
                )}
              </>
            )}
          </div>
        ))}
      </Section>
    </Sheet>
  );
}

export function PlayerTrackingSheet({ player, clipRange, time, isBusy, layer, onTrackWholeClip, onTrackToEnd, onTrackBackToStart, onFixFromHere, onPlaceHere, seek, onBridge, onSmoothing, onRename, onRemove, onClose }: {
  player: AnalysisTrackingLibraryPlayer; clipRange: TimeRange; time: number; isBusy: boolean; layer: AnalysisAnnotation | null;
  onTrackWholeClip(): void; onTrackToEnd(): void; onTrackBackToStart(): void; onFixFromHere(): void; onPlaceHere(): void; seek(time: number): void; onBridge(value: number): void; onSmoothing(value: number): void; onRename(name: string): void; onRemove: (() => void) | null; onClose(): void;
}) {
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(player.name);
  const motion = player.motion;
  const missing = missingIntervals(motion, clipRange);
  const trackedHere = !isMissing(motion, time);
  const coversClip = missing.length === 0;
  const first = motion.samples[0]?.time, last = motion.samples[motion.samples.length - 1]?.time;
  const status = first == null || last == null ? "Not tracked yet." : (() => {
    const span = `${formatTimecode(first - clipRange[0], true)} – ${formatTimecode(Math.min(last, motion.lostAt ?? last) - clipRange[0], true)}`;
    return coversClip ? `Tracked ${span}, no gaps.` : `Tracked ${span} · ${missing.length} untracked ${missing.length === 1 ? "section" : "sections"} shown in orange.`;
  })();
  const span = Math.max(0.01, clipRange[1] - clipRange[0]);
  const x = (seconds: number) => `${((Math.min(clipRange[1], Math.max(clipRange[0], seconds)) - clipRange[0]) / span) * 100}%`;
  const previous = previousMissing(motion, time, clipRange), next = nextMissing(motion, time, clipRange);
  return (
    <Sheet title={player.name} onClose={onClose} tall>
      <fieldset disabled={isBusy} style={{ border: 0, padding: 0, margin: 0 }}>
        <Section>
          <div className="an-field column">
            <div className="an-coverage" role="slider" aria-label="Tracking coverage" aria-valuetext={status} onClick={(e) => { const rect = e.currentTarget.getBoundingClientRect(); seek(clipRange[0] + ((e.clientX - rect.left) / rect.width) * span); }}>
              <div className="base" />
              {missing.map((gap, i) => <div key={i} className="gap" style={{ left: x(gap[0]), width: `max(3px, calc(${x(gap[1])} - ${x(gap[0])}))` }} />)}
              <div className="now" style={{ left: x(time) }} />
            </div>
            <span style={{ fontSize: 12, color: "var(--fg-secondary)" }}>{status}</span>
          </div>
        </Section>
        <Section title="Tracking" footer={coversClip ? "This player is tracked for the whole clip." : "Tracking follows the player automatically and remembers the kit, so it can pick the player up again after leaving the picture."}>
          {!coversClip && <FieldButton prominent onClick={() => { onClose(); onTrackWholeClip(); }}>Track whole clip</FieldButton>}
          {last != null && (last < clipRange[1] - 0.1 || motion.lostAt != null) && <FieldButton onClick={() => { onClose(); onTrackToEnd(); }}>Track to the end</FieldButton>}
          {first != null && first > clipRange[0] + 0.1 && <FieldButton onClick={() => { onClose(); onTrackBackToStart(); }}>Track back to the start</FieldButton>}
        </Section>
        <Section title="Fix a wrong or missing section" footer="Fix re-tracks from this frame after you tap the right player. Place sets the position on this frame only; effects bridge to it.">
          <div className="an-field">
            <button type="button" className="an-control" aria-label="Previous gap" disabled={previous == null} onClick={() => { if (previous != null) seek(previous); }}><span>‹</span></button>
            <span style={{ flex: 1, textAlign: "center", fontSize: 12, color: trackedHere ? "var(--fg-secondary)" : "var(--event-foul)" }}>{trackedHere ? "Tracked at this frame" : "Not tracked at this frame"}</span>
            <button type="button" className="an-control" aria-label="Next gap" disabled={next == null} onClick={() => { if (next != null) seek(next); }}><span>›</span></button>
          </div>
          <FieldButton disabled={time >= clipRange[1] - 0.05} onClick={() => { onClose(); onFixFromHere(); }} icon={<AnalysisIcon.scope />}>Fix from this frame</FieldButton>
          <FieldButton onClick={() => { onClose(); onPlaceHere(); }} icon={<AnalysisIcon.pin />}>Place on this frame by hand</FieldButton>
        </Section>
        {layer && (
          <Section title="How the effect follows">
            <TrackingBridgeControls mark={layer} onChange={onBridge} beginEdit={() => {}} />
            <TrackingSmoothingControls mark={layer} onChange={onSmoothing} beginEdit={() => {}} />
          </Section>
        )}
        <Section>
          {renaming ? (
            <div className="an-field"><input type="text" value={draft} autoFocus aria-label="Name" onChange={(e) => setDraft(e.target.value)} /><button type="button" className="an-control" onClick={() => { onRename(draft); setRenaming(false); }}><span>Save</span></button></div>
          ) : <FieldButton onClick={() => { setDraft(player.name); setRenaming(true); }} icon={<AnalysisIcon.pencil />}>Rename player</FieldButton>}
          {onRemove && <FieldButton destructive onClick={() => { onClose(); onRemove(); }} icon={<AnalysisIcon.trash />}>Remove player track</FieldButton>}
        </Section>
      </fieldset>
    </Sheet>
  );
}
