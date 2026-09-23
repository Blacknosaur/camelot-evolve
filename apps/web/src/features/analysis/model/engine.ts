import { createStore, type StoreApi } from "zustand/vanilla";
import type { Point, Rect } from "@/domain/geometry";
import type { CompositionClip } from "@/domain/records";
import type { UUID } from "@/domain/ids";
import { newId } from "@/domain/ids";
import type { AnalysisAnnotation, AnalysisDrawingTool, AnnotationColor } from "@/domain/annotation";
import { ANNOTATION_YELLOW } from "@/domain/annotation";
import type { AnalysisTrackingLibraryPlayer, PlayerMotion } from "@/domain/tracking";
import { boxAt } from "@/features/analysis/tracking/motion";
import { applyTimelineEdit, enableKeyframes, makeStatic, motionMode, pointsAt, setKeyframe, type AnnotationTimelineEdit, type AnnotationMotionMode } from "./annotation";
import { clipAnnotationEnd } from "@/domain/records";
import { followSavedPlayer, importAnnotationTracks, placePlayerSample, removePlayerTrack, setGapBridging, storePlayerTrack, storeSharedCameraTrack, refreshSharedCameraBindings } from "@/features/analysis/tracking/library";
import { applyPlayerEffects, type PlayerEffectOptions } from "./player-effects";
import { DEFAULT_INSPECTION, type InspectionViewport } from "./viewport";

/* The analysis editing engine: the clip under edit, undo/redo history, selection, tool state and
   every layer operation from AnalysisOverlayView.swift, as a framework-free zustand store so the
   workspace, tests and background tracking share one source of truth. Playback time is owned by
   the sequence player; actions that depend on it take `time` as an argument. */

export interface PlayerSample { time: number; box: Rect }
export type AnalysisSheet = "tools" | "inspector" | "playerTracks" | "playerTracking" | "playerEffects" | "field" | null;

export interface TrackingJob { id: UUID; progress: number; label: string }

export interface AnalysisState {
  clip: CompositionClip;
  undoStack: CompositionClip[];
  redoStack: CompositionClip[];
  selectedID: UUID | null;
  selectedKeyframe: UUID | null;
  selectedVertex: number | null;
  tool: AnalysisDrawingTool;
  color: AnnotationColor;
  width: number;
  /** Provisional drawing or drag preview, drawn on top of the saved layers. */
  draft: AnalysisAnnotation | null;
  constructionPoints: Point[];
  constructionPlayers: PlayerSample[];
  constructionID: UUID;
  areaUsesPlayers: boolean;
  selectedPlayer: PlayerSample | null;
  selectedPlayerTrackID: UUID | null;
  pickingPlayerTrack: boolean;
  correctingTrackID: UUID | null;
  placingPlayer: boolean;
  correctingPlayer: boolean;
  correctingAnchor: number | null;
  tracking: TrackingJob | null;
  inspection: InspectionViewport;
  fieldPreviewEnabled: boolean;
  showsPlayers: boolean;
  sheet: AnalysisSheet;
  playerPickerLayerID: UUID | null;
  timelineZoom: number;
  error: string | null;
}

export interface AnalysisActions {
  // History
  checkpoint(): void;
  undo(): void;
  redo(): void;
  setClip(clip: CompositionClip, recordUndo?: boolean): void;
  updateSelected(change: (mark: AnalysisAnnotation) => AnalysisAnnotation, recordUndo?: boolean): void;
  updateLayer(id: UUID, change: (mark: AnalysisAnnotation) => AnalysisAnnotation, recordUndo?: boolean): void;
  // Selection & tools
  select(id: UUID | null, time: number): void;
  selectKeyframe(layer: UUID, keyframe: UUID | null): void;
  setSelectedVertex(index: number | null): void;
  chooseTool(tool: AnalysisDrawingTool): void;
  setColor(color: AnnotationColor): void;
  setWidth(width: number): void;
  setDraft(draft: AnalysisAnnotation | null): void;
  // Construction (polygon / connection)
  appendConstructionPoint(point: Point): void;
  appendConstructionPlayer(sample: PlayerSample): void;
  removeLastConstructionPoint(): void;
  clearConstruction(): void;
  setAreaUsesPlayers(value: boolean): void;
  finishConstruction(time: number): { mark: AnalysisAnnotation; seeds: PlayerSample[] } | null;
  // Layers
  insertMark(mark: AnalysisAnnotation, time: number): AnalysisAnnotation;
  deleteLayer(id: UUID): void;
  toggleHidden(id: UUID): void;
  toggleLocked(id: UUID): void;
  reorder(id: UUID, direction: number): void;
  duplicate(): void;
  rename(id: UUID, name: string): void;
  editTimelineLayer(mark: AnalysisAnnotation): void;
  applyTimelineEdit(id: UUID, edit: AnnotationTimelineEdit): void;
  setMotionMode(mode: AnnotationMotionMode, time: number): "pickPlayer" | "camera" | "done";
  addKeyframe(time: number): void;
  deleteKeyframe(time: number): void;
  stepKeyframe(direction: number, time: number): { keyframe: UUID; time: number } | null;
  // Player state
  setSelectedPlayer(sample: PlayerSample | null, trackID?: UUID | null): void;
  setPicking(picking: boolean, correctingTrackID?: UUID | null, placing?: boolean): void;
  setCorrectingPlayer(value: boolean, anchor?: number | null): void;
  setTracking(job: TrackingJob | null): void;
  setTrackingProgress(progress: number): void;
  applyPlayerEffects(options: PlayerEffectOptions, replacing: ReadonlySet<UUID>, box: Rect, motion: PlayerMotion | null, time: number): UUID | null;
  storePlayerTrack(motion: PlayerMotion, recordUndo?: boolean): void;
  storeSharedCameraTrack(motion: import("@/domain/tracking").AnnotationCameraMotion): boolean;
  followSavedPlayer(player: AnalysisTrackingLibraryPlayer, layerID: UUID, time: number): boolean;
  placePlayer(trackID: UUID, box: Rect, time: number): boolean;
  removePlayerTrack(id: UUID): void;
  renamePlayerTrack(id: UUID, name: string): void;
  setGapBridging(seconds: number): void;
  setTrackingSmoothing(value: number): void;
  setGroundCalibration(calibration: CompositionClip["groundCalibration"] | null): void;
  setFreezeDuration(seconds: number): void;
  // View
  setInspection(viewport: InspectionViewport): void;
  setFieldPreview(enabled: boolean): void;
  setShowsPlayers(value: boolean): void;
  openSheet(sheet: AnalysisSheet, playerPickerLayerID?: UUID | null): void;
  setTimelineZoom(zoom: number): void;
  setError(message: string | null): void;
}

export type AnalysisEngine = StoreApi<AnalysisState & AnalysisActions>;

const HISTORY_LIMIT = 60;

export function createAnalysisEngine(initialClip: CompositionClip, selectedID: UUID | null = null): AnalysisEngine {
  return createStore<AnalysisState & AnalysisActions>()((set, get) => {
    const layer = (id: UUID | null) => (id ? get().clip.annotations.find((a) => a.id === id) ?? null : null);
    const replace = (id: UUID, mark: AnalysisAnnotation) => set((s) => ({ clip: { ...s.clip, annotations: s.clip.annotations.map((a) => (a.id === id ? mark : a)) } }));
    const checkpoint = () => set((s) => ({ undoStack: [...s.undoStack.slice(-(HISTORY_LIMIT - 1)), s.clip], redoStack: [] }));
    const resetPick = () => ({ pickingPlayerTrack: false, correctingTrackID: null, placingPlayer: false, constructionPoints: [], constructionPlayers: [] });

    return {
      clip: importAnnotationTracks(initialClip),
      undoStack: [], redoStack: [],
      selectedID, selectedKeyframe: null, selectedVertex: null,
      tool: "select", color: ANNOTATION_YELLOW, width: 0.006,
      draft: null, constructionPoints: [], constructionPlayers: [], constructionID: newId(), areaUsesPlayers: false,
      selectedPlayer: null, selectedPlayerTrackID: null,
      pickingPlayerTrack: false, correctingTrackID: null, placingPlayer: false, correctingPlayer: false, correctingAnchor: null,
      tracking: null, inspection: DEFAULT_INSPECTION, fieldPreviewEnabled: false, showsPlayers: true,
      sheet: null, playerPickerLayerID: null, timelineZoom: 1, error: null,

      checkpoint,
      undo() { set((s) => { const previous = s.undoStack[s.undoStack.length - 1]; return previous ? { clip: previous, undoStack: s.undoStack.slice(0, -1), redoStack: [...s.redoStack, s.clip], selectedID: null, selectedKeyframe: null, selectedVertex: null } : {}; }); },
      redo() { set((s) => { const next = s.redoStack[s.redoStack.length - 1]; return next ? { clip: next, redoStack: s.redoStack.slice(0, -1), undoStack: [...s.undoStack, s.clip], selectedID: null, selectedKeyframe: null, selectedVertex: null } : {}; }); },
      setClip(clip, recordUndo = true) { if (recordUndo) checkpoint(); set({ clip }); },
      updateSelected(change, recordUndo = true) { const id = get().selectedID; if (id) get().updateLayer(id, change, recordUndo); },
      updateLayer(id, change, recordUndo = true) {
        const mark = layer(id);
        if (!mark || mark.isLocked === true) return;
        if (recordUndo) checkpoint();
        replace(id, change(mark));
      },

      select(id, time) {
        const mark = layer(id);
        if (!mark) { set({ selectedID: null, selectedPlayer: null, selectedKeyframe: null, selectedVertex: null, correctingAnchor: null, correctingPlayer: false }); return; }
        const box = mark.playerMotion ? boxAt(mark.playerMotion, time) : mark.playerEffectBox ?? null;
        set({ ...resetPick(), selectedID: id, tool: "select", selectedKeyframe: mark.keyframes.some((k) => k.id === get().selectedKeyframe) ? get().selectedKeyframe : null, selectedVertex: null, correctingAnchor: null, correctingPlayer: false,
          selectedPlayer: box ? { time, box } : null, selectedPlayerTrackID: mark.playerMotion?.trackID ?? null });
      },
      selectKeyframe(layerID, keyframe) { set({ ...resetPick(), selectedID: layerID, selectedKeyframe: keyframe, tool: "select" }); },
      setSelectedVertex(index) { set({ selectedVertex: index }); },
      chooseTool(tool) {
        const patch: Partial<AnalysisState> = { ...resetPick(), correctingPlayer: false, draft: null };
        if (tool === "zoom") Object.assign(patch, { selectedID: null, selectedPlayer: null, inspection: DEFAULT_INSPECTION });
        if (tool === "zone" || tool === "connection") Object.assign(patch, { selectedID: null, selectedPlayer: null });
        if (tool === "text" || tool === "player" || tool === "loupe") Object.assign(patch, { selectedID: null, selectedPlayer: null, selectedPlayerTrackID: null });
        set({ ...patch, tool });
      },
      setColor(color) { set({ color }); get().updateSelected((m) => ({ ...m, color })); },
      setWidth(width) { set({ width }); get().updateSelected((m) => ({ ...m, width }), false); },
      setDraft(draft) { set({ draft }); },

      appendConstructionPoint(point) { set((s) => (s.constructionPoints.length >= 12 ? {} : { constructionPoints: [...s.constructionPoints, point] })); },
      appendConstructionPlayer(sample) {
        set((s) => (s.constructionPoints.length >= 12 || s.constructionPlayers.some((p) => boxOverlapRatio(p.box, sample.box) > 0.7) ? {} : {
          constructionPlayers: [...s.constructionPlayers, sample],
          constructionPoints: [...s.constructionPoints, { x: sample.box.x + sample.box.width / 2, y: sample.box.y + sample.box.height }],
        }));
      },
      removeLastConstructionPoint() { set((s) => ({ constructionPoints: s.constructionPoints.slice(0, -1), constructionPlayers: s.constructionPlayers.slice(0, -1) })); },
      clearConstruction() { set({ constructionPoints: [], constructionPlayers: [], constructionID: newId() }); },
      setAreaUsesPlayers(value) { set({ areaUsesPlayers: value, constructionPoints: [], constructionPlayers: [] }); },
      finishConstruction(time) {
        const s = get();
        const needed = s.tool === "zone" ? 3 : 2;
        if (s.constructionPoints.length < needed) return null;
        const end = clipAnnotationEnd(s.clip);
        const mark: AnalysisAnnotation = { id: newId(), tool: s.tool, points: s.constructionPoints, color: s.color, width: s.width, text: "", start: Math.min(time, end - 0.05), end: Math.min(end, time + 6), fade: false, keyframes: [], effect: "neon" };
        const seeds = s.constructionPlayers;
        set({ constructionPoints: [], constructionPlayers: [], constructionID: newId(), selectedPlayer: null });
        get().insertMark(mark, time);
        return { mark, seeds };
      },

      insertMark(input, _time) {
        let mark = { ...input };
        if (mark.tool === "zoom") { mark.zoomScale = 2; mark.zoomRamp = 0.35; }
        if (mark.tool === "player" && mark.effect == null) mark.effect = "radar";
        if (mark.tool === "loupe") mark.loupeStyle = mark.loupeStyle ?? { magnification: 2, diameter: 0.22, offset: { x: 0, y: -0.18 } };
        checkpoint();
        set((s) => ({ clip: { ...s.clip, annotations: [...s.clip.annotations, mark] }, selectedID: mark.id, tool: "select", draft: null, selectedPlayer: mark.tool === "zoom" ? null : s.selectedPlayer }));
        return mark;
      },
      deleteLayer(id) {
        const mark = layer(id);
        if (!mark || mark.isLocked === true) return;
        checkpoint();
        set((s) => ({ clip: { ...s.clip, annotations: s.clip.annotations.filter((a) => a.id !== id) }, selectedID: s.selectedID === id ? null : s.selectedID, selectedKeyframe: null, sheet: s.sheet === "inspector" ? null : s.sheet }));
      },
      toggleHidden(id) { const mark = layer(id); if (!mark) return; checkpoint(); replace(id, { ...mark, isHidden: mark.isHidden !== true }); },
      toggleLocked(id) { const mark = layer(id); if (!mark) return; checkpoint(); replace(id, { ...mark, isLocked: mark.isLocked !== true }); },
      reorder(id, direction) {
        const list = get().clip.annotations, index = list.findIndex((a) => a.id === id);
        if (index < 0 || list[index]!.isLocked === true) return;
        const destination = Math.min(list.length - 1, Math.max(0, index + direction));
        if (destination === index) return;
        checkpoint();
        const next = [...list]; [next[index], next[destination]] = [next[destination]!, next[index]!];
        set((s) => ({ clip: { ...s.clip, annotations: next } }));
      },
      duplicate() {
        const mark = layer(get().selectedID);
        if (!mark) return;
        checkpoint();
        const shift = (p: Point) => ({ x: p.x + 0.025, y: p.y + 0.025 });
        const copy: AnalysisAnnotation = { ...mark, id: newId(), points: mark.points.map(shift), keyframes: mark.keyframes.map((k) => ({ id: newId(), time: k.time, points: k.points.map(shift) })) };
        set((s) => ({ clip: { ...s.clip, annotations: [...s.clip.annotations, copy] }, selectedID: copy.id }));
      },
      rename(id, name) { get().updateLayer(id, (m) => ({ ...m, layerName: name })); },
      editTimelineLayer(mark) { replace(mark.id, mark); },
      applyTimelineEdit(id, edit) {
        const mark = layer(id);
        if (!mark) return;
        const clip = get().clip;
        replace(id, applyTimelineEdit(mark, edit, clip.startSeconds, clipAnnotationEnd(clip)));
      },
      setMotionMode(mode, time) {
        const mark = layer(get().selectedID);
        if (!mark || mark.isLocked === true) return "done";
        set({ tool: "select", selectedKeyframe: null });
        switch (mode) {
          case "still": set({ correctingPlayer: false, selectedPlayer: null }); get().updateSelected((m) => makeStatic(m, time)); return "done";
          case "keyframes": set({ correctingPlayer: false, selectedPlayer: null }); get().updateSelected((m) => enableKeyframes(m, time)); return "done";
          case "player":
            if (get().clip.freezeDuration != null) return "done";
            if (mark.linkedPlayers) { set((s) => ({ correctingAnchor: s.correctingAnchor ?? 0, correctingPlayer: true })); return "done"; }
            set({ playerPickerLayerID: mark.id, sheet: "playerTracks" });
            return "pickPlayer";
          case "camera": return "camera";
        }
      },
      addKeyframe(time) {
        const mark = layer(get().selectedID);
        if (!mark || time < mark.start || time > mark.end) return;
        get().updateSelected((m) => setKeyframe(m, time, pointsAt(m, time)));
        set({ selectedKeyframe: layer(get().selectedID)?.keyframes.find((k) => Math.abs(k.time - time) < 1 / 60)?.id ?? null });
      },
      deleteKeyframe(time) {
        const id = get().selectedKeyframe;
        if (!id) return;
        get().updateSelected((m) => {
          const position = pointsAt(m, time);
          const keyframes = m.keyframes.filter((k) => k.id !== id);
          return { ...m, keyframes, points: keyframes.length === 0 ? position : m.points };
        });
        set({ selectedKeyframe: null });
      },
      stepKeyframe(direction, time) {
        const mark = layer(get().selectedID);
        if (!mark) return null;
        const frame = direction < 0 ? [...mark.keyframes].reverse().find((k) => k.time < time - 0.02) : mark.keyframes.find((k) => k.time > time + 0.02);
        if (!frame) return null;
        set({ ...resetPick(), selectedKeyframe: frame.id, tool: "select" });
        return { keyframe: frame.id, time: frame.time };
      },

      setSelectedPlayer(sample, trackID) { set((s) => ({ selectedPlayer: sample, selectedPlayerTrackID: trackID === undefined ? s.selectedPlayerTrackID : trackID })); },
      setPicking(picking, correctingTrackID = null, placing = false) {
        set(picking
          ? { pickingPlayerTrack: true, correctingTrackID, placingPlayer: placing, selectedID: null, selectedPlayer: null, selectedPlayerTrackID: placing ? correctingTrackID : null, tool: "select", correctingPlayer: false, constructionPoints: [], constructionPlayers: [], showsPlayers: true }
          : { pickingPlayerTrack: false, correctingTrackID: null, placingPlayer: false });
      },
      setCorrectingPlayer(value, anchor = null) { set({ correctingPlayer: value, correctingAnchor: value ? anchor : null, tool: "select" }); },
      setTracking(job) { set({ tracking: job }); },
      setTrackingProgress(progress) { set((s) => (s.tracking && Math.floor(s.tracking.progress * 100) !== Math.floor(progress * 100) ? { tracking: { ...s.tracking, progress } } : {})); },
      applyPlayerEffects(options, replacing, box, motion, time) {
        checkpoint();
        const result = applyPlayerEffects(get().clip, options, replacing, box, motion, time);
        set({ clip: result.clip, selectedID: result.selected, tool: "select" });
        return result.selected;
      },
      storePlayerTrack(motion, recordUndo = true) { if (recordUndo) checkpoint(); set((s) => ({ clip: storePlayerTrack(s.clip, motion) })); },
      storeSharedCameraTrack(motion) { const next = storeSharedCameraTrack(get().clip, motion); if (next) set({ clip: next }); return next !== null; },
      followSavedPlayer(player, layerID, time) {
        const next = followSavedPlayer(get().clip, player, layerID, time, makeStatic);
        if (!next) return false;
        checkpoint();
        set({ clip: next, selectedID: layerID, selectedPlayerTrackID: player.id, correctingPlayer: false, pickingPlayerTrack: false, tool: "select", playerPickerLayerID: null });
        return true;
      },
      placePlayer(trackID, box, time) {
        const next = placePlayerSample(get().clip, trackID, box, time);
        if (!next) return false;
        checkpoint();
        set({ clip: next, pickingPlayerTrack: false, correctingTrackID: null, placingPlayer: false, selectedPlayerTrackID: trackID, selectedPlayer: { time, box } });
        return true;
      },
      removePlayerTrack(id) { const next = removePlayerTrack(get().clip, id); if (!next) return; checkpoint(); set((s) => ({ clip: next, selectedPlayerTrackID: s.selectedPlayerTrackID === id ? null : s.selectedPlayerTrackID, selectedPlayer: s.selectedPlayerTrackID === id ? null : s.selectedPlayer })); },
      renamePlayerTrack(id, name) { if (layerName(get().clip, id) === name || !get().clip.trackingLibrary) return; checkpoint(); set((s) => ({ clip: { ...s.clip, trackingLibrary: { ...s.clip.trackingLibrary!, players: s.clip.trackingLibrary!.players.map((p) => (p.id === id ? { ...p, name } : p)) } } })); },
      setGapBridging(seconds) { const id = get().selectedID; if (id) set((s) => ({ clip: setGapBridging(s.clip, seconds, id) })); },
      setTrackingSmoothing(value) {
        get().updateSelected((m) => ({ ...m, playerMotion: m.playerMotion ? { ...m.playerMotion, smoothing: value } : m.playerMotion, linkedPlayers: m.linkedPlayers?.map((l) => ({ ...l, smoothing: value })) }), false);
      },
      setGroundCalibration(calibration) {
        checkpoint();
        set((s) => ({ clip: refreshSharedCameraBindings({ ...s.clip, groundCalibration: calibration ?? undefined }) }));
      },
      setFreezeDuration(seconds) {
        set((s) => {
          const oldEnd = clipAnnotationEnd(s.clip);
          const clip = { ...s.clip, freezeDuration: seconds };
          const end = clipAnnotationEnd(clip);
          return { clip: { ...clip, annotations: clip.annotations.map((a) => (a.end >= oldEnd - 0.01 ? { ...a, end } : a)) } };
        });
      },

      setInspection(inspection) { set({ inspection }); },
      setFieldPreview(enabled) { set({ fieldPreviewEnabled: enabled }); },
      setShowsPlayers(value) { set({ showsPlayers: value }); },
      openSheet(sheet, playerPickerLayerID = null) { set({ sheet, playerPickerLayerID: sheet === "playerTracks" ? playerPickerLayerID : null }); },
      setTimelineZoom(zoom) { set((s) => ({ timelineZoom: Math.min(Math.max(64, clipAnnotationEnd(s.clip) - s.clip.startSeconds), Math.max(1, zoom)) })); },
      setError(message) { set({ error: message }); },
    };
  });
}

const layerName = (clip: CompositionClip, id: UUID) => clip.trackingLibrary?.players.find((p) => p.id === id)?.name;

function boxOverlapRatio(a: Rect, b: Rect): number {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.width, b.x + b.width) - x, h = Math.min(a.y + a.height, b.y + b.height) - y;
  if (w <= 0 || h <= 0) return 0;
  const inter = w * h;
  return inter / Math.max(1e-9, a.width * a.height + b.width * b.height - inter);
}

/** Layers the Player panel edits: effects on the same player/group as the current selection. */
export function playerEffectLayers(s: Pick<AnalysisState, "clip" | "selectedID" | "selectedPlayerTrackID">, time: number, isActive: (a: AnalysisAnnotation, time: number) => boolean): AnalysisAnnotation[] {
  const selected = s.clip.annotations.find((a) => a.id === s.selectedID);
  return s.clip.annotations.filter((mark) =>
    ["player", "spotlight", "text", "trajectory", "loupe"].includes(mark.tool) && isActive(mark, time) &&
    (s.selectedPlayerTrackID ? mark.playerMotion?.trackID === s.selectedPlayerTrackID : selected?.playerEffectGroupID ? mark.playerEffectGroupID === selected.playerEffectGroupID : mark.id === s.selectedID));
}

export const selectedAnnotation = (s: Pick<AnalysisState, "clip" | "selectedID">) => s.clip.annotations.find((a) => a.id === s.selectedID) ?? null;
export const annotationMotionMode = motionMode;
