import { useCallback, useEffect, useMemo, useRef } from "react";
import { useStore } from "zustand";
import type { Point, Rect } from "@/domain/geometry";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { clipAnnotationEnd } from "@/domain/records";
import { boxAt } from "@/features/analysis/tracking/motion";
import { playerMatching } from "@/features/analysis/tracking/library";
import type { AnalysisEngine } from "../model/engine";
import { connectionAnchors, handleIndexAt, hitTest, moveDrawing, newAnnotation, reshaped } from "../model/annotation";
import { AFFINE_IDENTITY, applyAffineRect, concatAffine, inspectionTransform, navigateViewport, sourcePoint, zoomTransform, type Affine } from "../model/viewport";
import { drawAnnotations } from "../render/draw";
import { drawEditorOverlay } from "../render/editor-overlay";
import { toolRegistry } from "../render/toolRegistry";
import type { TrackingController } from "./useTracking";

/* The drawing surface over the video: renders the shared annotation renderer plus editor chrome, and
   turns pointer input into engine actions. One pointer draws or selects; two pointers pan and pinch
   the inspection viewport (0.25–8×). Adding a second finger cancels the provisional drawing. */

export interface OverlayCanvasProps {
  engine: AnalysisEngine;
  time: number;
  isPlaying: boolean;
  size: { width: number; height: number };
  displayAspect: number;
  /** Active <video> for the zoomed preview and loupes; null for a still. */
  video: HTMLVideoElement | null;
  still: CanvasImageSource | null;
  detections: readonly Rect[];
  tracking: TrackingController;
  pause(): void;
  seek(time: number): void;
  onError(message: string): void;
  onRequestDetections(): void;
}

interface Touch { start: Point; current: Point; frame: Rect; dragging: boolean }
interface Navigation { zoom: number; center: Point; startDistance: number; startMid: Point; anchorFrame: Rect }

export function OverlayCanvas({ engine, time, isPlaying, size, displayAspect, video, still, detections, tracking, pause, seek, onError, onRequestDetections }: OverlayCanvasProps) {
  const state = useStore(engine);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const pointers = useRef(new Map<number, Point>());
  const touch = useRef<Touch | null>(null);
  const navigation = useRef<Navigation | null>(null);
  const dragOriginal = useRef<AnalysisAnnotation | null>(null);
  const dragVertex = useRef<number | null>(null);
  const dragFrame = useRef<Rect | null>(null);

  const clip = state.clip, selected = clip.annotations.find((a) => a.id === state.selectedID) ?? null;
  const fitted: Rect = useMemo(() => ({ x: 0, y: 0, width: size.width, height: size.height }), [size.width, size.height]);
  const editsZoom = !isPlaying && (state.tool === "zoom" || selected?.tool === "zoom");
  const zoom: Affine = editsZoom ? AFFINE_IDENTITY : zoomTransform(clip.annotations, time, fitted, fitted);
  const inspection = inspectionTransform(fitted, state.inspection.zoom, state.inspection.center);
  const frame = dragFrame.current ?? applyAffineRect(concatAffine(zoom, inspection), fitted);
  const transformed = Math.abs(frame.x) > 0.5 || Math.abs(frame.y) > 0.5 || Math.abs(frame.width - fitted.width) > 0.5;
  const pickingConnection = state.tool === "connection" || (state.tool === "zone" && state.areaUsesPlayers);
  const showsDetections = state.showsPlayers && !isPlaying && !state.tracking &&
    (state.selectedID == null || state.correctingPlayer || pickingConnection) &&
    (["player", "spotlight", "select"].includes(state.tool) || pickingConnection || state.pickingPlayerTrack);
  const playerName = useCallback((trackID: string | undefined, index: number) => clip.trackingLibrary?.players.find((p) => p.id === trackID)?.name ?? `Player ${index + 1}`, [clip.trackingLibrary]);
  const anchors = useMemo(() => (selected && !isPlaying && selected.isHidden !== true ? connectionAnchors(selected, time, playerName) : []), [selected, time, isPlaying, playerName]);

  /* ---- Rendering ---- */
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || size.width <= 0) return;
    const scale = Math.min(3, window.devicePixelRatio || 1);
    const w = Math.round(size.width * scale), h = Math.round(size.height * scale);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    ctx.clearRect(0, 0, size.width, size.height);
    const source: CanvasImageSource | null = still ?? (video && video.readyState >= 2 ? video : null);
    if (transformed && source) {
      ctx.fillStyle = "#000"; ctx.fillRect(0, 0, size.width, size.height);
      try { ctx.drawImage(source, frame.x, frame.y, frame.width, frame.height); } catch { /* not decodable yet */ }
    }
    const marks: AnalysisAnnotation[] = clip.annotations.filter((a) => a.id !== state.draft?.id);
    if (state.draft) marks.push(state.draft);
    if (state.constructionPoints.length > 0) {
      marks.push({ ...newAnnotation(state.tool, state.constructionPoints, time, time + 1, { id: state.constructionID, color: state.color, width: state.width }), effect: "neon" });
    }
    drawAnnotations(ctx, marks, time, size, { ground: clip.groundCalibration ?? null, bounds: fitted, frame, editing: true, source });
    if (!isPlaying) {
      drawEditorOverlay(ctx, {
        frame, bounds: fitted, time, ground: clip.groundCalibration ?? null,
        selected: isPlaying ? null : selected,
        detections: showsDetections ? detections : [],
        selectedPlayer: state.selectedPlayer?.box ?? null,
        constructionPoints: state.constructionPoints,
        anchors, correctingAnchor: state.correctingPlayer ? state.correctingAnchor : null,
      });
    }
  });

  /* ---- Helpers ---- */
  const editsOffscreenField = state.tool === "select" && selected?.fieldLines === true && !state.correctingPlayer && !state.pickingPlayerTrack;
  const normalise = (point: Point, inFrame: Rect) => sourcePoint(point, inFrame, editsOffscreenField);
  const inside = (point: Point, inFrame: Rect) => point.x >= inFrame.x && point.x <= inFrame.x + inFrame.width && point.y >= inFrame.y && point.y <= inFrame.y + inFrame.height;
  const annotationEnd = clipAnnotationEnd(clip);
  const playerBoxes = useCallback((): Rect[] => {
    const saved = (clip.trackingLibrary?.players ?? []).map((p) => boxAt(p.motion, time)).filter((b): b is Rect => b !== null);
    return [...detections, ...saved];
  }, [clip.trackingLibrary, detections, time]);
  const playerAt = (point: Point): Rect | null => {
    const candidates = playerBoxes().filter((r) => point.x >= r.x - 0.014 && point.x <= r.x + r.width + 0.014 && point.y >= r.y - 0.014 && point.y <= r.y + r.height + 0.014);
    return candidates.sort((a, b) => a.width * a.height - b.width * b.height)[0] ?? null;
  };
  const rectFrom = (a: Point, b: Point): Rect => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) });

  const selectPlayer = (box: Rect) => {
    const s = engine.getState();
    if (s.pickingPlayerTrack) { tracking.trackIndependentPlayer(box, time); return; }
    pause();
    const saved = clip.trackingLibrary ? playerMatching(clip.trackingLibrary, box, time) : null;
    s.setSelectedPlayer({ time, box }, saved?.id ?? null);
    if (s.tool === "player" && !s.correctingPlayer) { s.select(null, time); s.setSelectedPlayer({ time, box }, saved?.id ?? null); s.chooseTool("select"); s.openSheet("playerEffects"); return; }
    if (s.correctingPlayer && s.selectedID) {
      const mark = selected;
      if (mark?.linkedPlayers) {
        const links = mark.linkedPlayers;
        const closest = s.correctingAnchor ?? links.map((m, i) => { const b = boxAt(m, time) ?? m.samples[m.samples.length - 1]?.box ?? { x: 0, y: 0, width: 0, height: 0 }; return { i, d: Math.hypot(b.x + b.width / 2 - (box.x + box.width / 2), b.y + b.height - (box.y + box.height)) }; }).sort((a, b) => a.d - b.d)[0]?.i;
        if (closest != null) { s.setCorrectingPlayer(false); tracking.beginLinkedTracking(mark.id, [{ time, box }], closest); }
        return;
      }
      s.checkpoint(); s.setCorrectingPlayer(false);
      if (!mark?.playerMotion) tracking.attachOrTrack(s.selectedID, box, time); else tracking.beginTracking(s.selectedID, box, time);
      return;
    }
    const hit = hitTest(clip.annotations, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, time, clip.groundCalibration, displayAspect);
    if (hit) s.select(hit.id, time); else { s.select(null, time); s.setSelectedPlayer({ time, box }, saved?.id ?? null); }
  };

  const insertMark = (mark: AnalysisAnnotation) => {
    const s = engine.getState();
    const inserted = s.insertMark(mark, time);
    if (inserted.tool === "text" || inserted.tool === "zoom" || (inserted.tool === "loupe" && !s.selectedPlayer)) engine.getState().openSheet("inspector");
    if (inserted.tool === "zoom") return;
    if (clip.freezeDuration != null || inserted.playerMotion) return;
    const first = inserted.points[0], last = inserted.points[inserted.points.length - 1];
    if ((inserted.tool === "player" || inserted.tool === "spotlight") && first && last) {
      const seed = rectFrom(first, last);
      engine.getState().setSelectedPlayer({ time, box: seed });
      tracking.attachOrTrack(inserted.id, seed, time);
    } else if (s.selectedPlayer) tracking.attachOrTrack(inserted.id, s.selectedPlayer.box, time);
  };

  const snapToPlayer = (mark: AnalysisAnnotation, point: Point): AnalysisAnnotation => {
    const player = playerBoxes().filter((r) => point.x >= r.x - 0.015 && point.x <= r.x + r.width + 0.015 && point.y >= r.y - 0.015 && point.y <= r.y + r.height + 0.015).sort((a, b) => a.width - b.width)[0];
    if (player) return { ...mark, points: [{ x: player.x, y: player.y }, { x: player.x + player.width, y: player.y + player.height }] };
    return { ...mark, points: [{ x: point.x - 0.022, y: point.y - 0.1 }, { x: point.x + 0.022, y: point.y }] };
  };

  /* ---- Gestures ---- */
  const tapCanvas = (location: Point, inFrame: Rect) => {
    const s = engine.getState();
    if (s.tracking || !(inside(location, inFrame) || editsOffscreenField)) return;
    pause();
    const point = normalise(location, inFrame);
    if (s.pickingPlayerTrack) { const box = playerAt(point); if (box) tracking.trackIndependentPlayer(box, time); return; }
    if (s.tool === "zone" || s.tool === "connection") {
      if (s.constructionPoints.length >= 12) return;
      if (s.tool === "connection" || s.areaUsesPlayers) {
        const box = playerAt(point);
        if (!box) { onError("Tap a detected player. If the player is missing, use Find players at this frame first."); return; }
        s.appendConstructionPlayer({ time, box });
      } else s.appendConstructionPoint(point);
      return;
    }
    if (s.tool === "select") {
      const vertex = !s.correctingPlayer && selected ? handleIndexAt(selected, location, inFrame, time, clip.groundCalibration) : null;
      if (vertex != null) { s.setSelectedVertex(vertex); return; }
      const hit = !s.correctingPlayer ? hitTest(clip.annotations, point, time, clip.groundCalibration, displayAspect) : null;
      if (hit) { s.select(hit.id, time); return; }
      const player = playerAt(point);
      if (player) { selectPlayer(player); return; }
      if (!s.correctingPlayer) { s.select(null, time); s.setSelectedPlayer(null); }
      return;
    }
    if (!["text", "player", "spotlight", "pen", "zoom", "loupe"].includes(s.tool)) return;
    let mark = newAnnotation(s.tool, [point], Math.min(time, annotationEnd - 0.05), Math.min(annotationEnd, time + 4), { color: s.color, width: s.width, text: s.tool === "text" ? "Text" : "", ...toolRegistry[s.tool].defaults });
    if (s.tool === "loupe") { const box = playerAt(point); s.setSelectedPlayer(box ? { time, box } : null); }
    if (s.tool === "player" || s.tool === "spotlight") mark = snapToPlayer(mark, point);
    if (s.tool === "player") { const [a, b] = mark.points as [Point, Point]; selectPlayer(rectFrom(a, b)); return; }
    insertMark(mark);
  };

  const changeDrawing = (start: Point, location: Point, inFrame: Rect) => {
    const s = engine.getState();
    if (s.tracking || !(inside(start, inFrame) || editsOffscreenField)) return;
    dragFrame.current ??= inFrame;
    pause();
    const from = normalise(start, inFrame), point = normalise(location, inFrame);
    if (s.tool === "connection" || s.tool === "zone") return;
    if (s.correctingPlayer || s.pickingPlayerTrack) { s.setDraft({ ...newAnnotation("rectangle", [from, point], time, annotationEnd), color: s.color, width: s.width }); return; }
    if (s.tool === "select") {
      if (!dragOriginal.current) {
        const handle = selected ? handleIndexAt(selected, start, inFrame, time, clip.groundCalibration) : null;
        let target = selected;
        if (handle == null) { target = hitTest(clip.annotations, from, time, clip.groundCalibration, displayAspect); s.select(target?.id ?? null, time); }
        dragOriginal.current = target;
        dragVertex.current = target ? handleIndexAt(target, start, inFrame, time, clip.groundCalibration) : null;
        s.setSelectedVertex(dragVertex.current);
      }
      const original = dragOriginal.current;
      if (original) {
        const { playerMotion: _p, linkedPlayers: _l, cameraMotion: _c, ...rest } = original;
        s.setDraft({ ...rest, points: reshaped(original, time, dragVertex.current, { width: point.x - from.x, height: point.y - from.y }, clip.groundCalibration), keyframes: [] });
      }
      return;
    }
    const draft = s.draft ?? newAnnotation(s.tool, [from], Math.min(time, annotationEnd - 0.05), Math.min(annotationEnd, time + 4), { color: s.color, width: s.width, text: s.tool === "text" ? "Text" : "", ...toolRegistry[s.tool].defaults });
    s.setDraft({ ...draft, points: s.tool === "pen" ? [...draft.points, point] : s.tool === "zoom" || s.tool === "loupe" ? [point] : [from, point] });
  };

  const endDrawing = (start: Point, location: Point, inFrame: Rect) => {
    const s = engine.getState();
    const draft = s.draft, original = dragOriginal.current, vertex = dragVertex.current;
    s.setDraft(null); dragOriginal.current = null; dragVertex.current = null; dragFrame.current = null;
    if (s.tracking || !(inside(start, inFrame) || editsOffscreenField)) return;
    const from = normalise(start, inFrame), end = normalise(location, inFrame);
    if (s.pickingPlayerTrack) { const seed = rectFrom(from, end); if (seed.width > 0.003 && seed.height > 0.01) tracking.trackIndependentPlayer(seed, time); return; }
    if (s.correctingPlayer && s.selectedID) {
      const seed = rectFrom(from, end);
      if (seed.width <= 0.003 || seed.height <= 0.01) return;
      if (selected?.linkedPlayers) { selectPlayer(seed); return; }
      s.checkpoint(); s.setCorrectingPlayer(false); s.setSelectedPlayer({ time, box: seed });
      tracking.beginTracking(s.selectedID, seed, time);
      return;
    }
    if (s.tool === "select") {
      if (!original) return;
      const dx = end.x - from.x, dy = end.y - from.y;
      if (Math.abs(dx) + Math.abs(dy) <= 0.002) return;
      s.updateLayer(original.id, (m) => moveDrawing(m, reshaped(original, time, vertex, { width: dx, height: dy }, clip.groundCalibration), time));
      return;
    }
    if (!draft) return;
    let mark = draft;
    if (s.tool === "text") mark = { ...mark, points: [from] };
    if (s.tool === "player" || s.tool === "spotlight") {
      const player = playerBoxes().filter((r) => from.x >= r.x - 0.015 && from.x <= r.x + r.width + 0.015 && from.y >= r.y - 0.015 && from.y <= r.y + r.height + 0.015).sort((a, b) => a.width - b.width)[0];
      if (player) mark = { ...mark, points: [{ x: player.x, y: player.y }, { x: player.x + player.width, y: player.y + player.height }] };
      else if (Math.hypot(end.x - from.x, end.y - from.y) < 0.015) mark = { ...mark, points: [{ x: from.x - 0.022, y: from.y - 0.1 }, { x: from.x + 0.022, y: from.y }] };
    }
    if (s.tool === "player") { const [a, b] = mark.points as [Point, Point]; selectPlayer(rectFrom(a, b)); return; }
    insertMark(mark);
  };

  const cancelDrawing = () => { engine.getState().setDraft(null); dragOriginal.current = null; dragVertex.current = null; dragFrame.current = null; touch.current = null; };

  const local = (event: React.PointerEvent): Point => {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  };

  const onPointerDown = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (event.button !== 0 && event.pointerType === "mouse") return;
    event.currentTarget.setPointerCapture(event.pointerId);
    const point = local(event);
    pointers.current.set(event.pointerId, point);
    if (pointers.current.size === 1) {
      touch.current = { start: point, current: point, frame, dragging: false };
    } else if (pointers.current.size === 2) {
      cancelDrawing();
      pause();
      const [a, b] = [...pointers.current.values()] as [Point, Point];
      navigation.current = { zoom: state.inspection.zoom, center: state.inspection.center, startDistance: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), startMid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, anchorFrame: frame };
    }
  };

  const onPointerMove = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!pointers.current.has(event.pointerId)) return;
    const point = local(event);
    pointers.current.set(event.pointerId, point);
    if (navigation.current && pointers.current.size >= 2) {
      const [a, b] = [...pointers.current.values()] as [Point, Point];
      const distance = Math.hypot(a.x - b.x, a.y - b.y), mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      const nav = navigation.current;
      engine.getState().setInspection(navigateViewport({ zoom: nav.zoom, center: nav.center }, distance / nav.startDistance, nav.startMid, mid, fitted));
      return;
    }
    const t = touch.current;
    if (!t) return;
    t.current = point;
    if (Math.hypot(point.x - t.start.x, point.y - t.start.y) >= 3) t.dragging = true;
    if (t.dragging) changeDrawing(t.start, point, t.frame);
  };

  const onPointerUp = (event: React.PointerEvent<HTMLCanvasElement>) => {
    pointers.current.delete(event.pointerId);
    if (navigation.current) { if (pointers.current.size === 0) navigation.current = null; return; }
    const t = touch.current;
    if (!t) return;
    touch.current = null;
    if (t.dragging) endDrawing(t.start, t.current, t.frame); else tapCanvas(t.current, t.frame);
  };

  const onPointerCancel = (event: React.PointerEvent<HTMLCanvasElement>) => { pointers.current.delete(event.pointerId); if (pointers.current.size === 0) navigation.current = null; cancelDrawing(); };

  const onWheel = (event: React.WheelEvent<HTMLCanvasElement>) => {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    const point = local(event as unknown as React.PointerEvent);
    const scale = Math.exp(-event.deltaY * 0.01);
    engine.getState().setInspection(navigateViewport(state.inspection, scale, point, point, fitted));
  };

  useEffect(() => { if (!isPlaying && state.selectedID == null) onRequestDetections(); }, [isPlaying, state.selectedID, time, onRequestDetections]);

  const label = "Analysis preview. One pointer draws or selects. Two fingers pan and pinch to zoom.";
  return (
    <canvas ref={canvasRef} className="an-canvas" data-tool={state.tool} role="img" aria-label={label} style={{ width: size.width, height: size.height }}
      onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel} onWheel={onWheel} onContextMenu={(e) => e.preventDefault()} />
  );
}
