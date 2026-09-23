/* Field setup: port of GroundCalibrationSheet.swift. Choose a frame, Detect field (or place a landmark / trace lines),
   Snap to lines, review the overlay, confirm "Lines align with the video" and Apply. Every edit is a local draft;
   nothing is committed until Apply. Heavy work (detection, snapping) runs in the vision worker; frames are decoded on
   the main thread through `@/media/frame-source`. */
import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from "react";
import type { Point, Rect, Size } from "@/domain/geometry";
import type { GroundCalibration, GroundCalibrationMode, GroundCircleReference, GroundLandmark, GroundLineObservation, GroundPitchLine } from "@/domain/ground";
import { GROUND_LANDMARK_INFO, GROUND_PITCH_LINES, GROUND_PITCH_LINE_TITLES } from "@/domain/ground";
import type { CompositionClip } from "@/domain/records";
import type { AnnotationCameraMotion, TimeRange } from "@/domain/tracking";
import { Icon } from "@/design/icons";
import { Spinner } from "@/design/components";
import { preciseDuration } from "@/design/format";
import { useLayoutMetrics } from "@/design/layout";
import { openFrameSource, type FrameSource } from "@/media/frame-source";
import { recordings } from "@/storage/repository";
import * as api from "../tracking/api";
import { sharedCamera } from "../tracking/library";
import { circleAnchors, circleCenterFromTouchline, circlePixelSensitivity } from "./circle";
import { fitLines } from "./line-alignment";
import { calibrationCorners, editingAnchors, handleNames, overlayPolylines, RECTANGLE, referenceAnchors, referencePolyline, seedAnchors } from "./overlay";
import { DEFAULT_VIEWPORT, FieldPlacementTouchState, loupeCenter, navigateViewport, nudgePoint, sourcePoint, viewportFrame, type PlacementViewport, type TouchAction } from "./placement";
import { calibrationIsValid, frozenCalibration } from "./projection";
import type { FieldProposal } from "./region-detection";
import { FIT_GRADE_TITLES, qualityGrade, qualitySummary, type FitGrade, type SnapQuality } from "./registration";
import "./ground-calibration-sheet.css";

export interface GroundCalibrationSheetProps {
  clip: CompositionClip;
  /** Source time to open on; defaults to the clip start. */
  time?: number;
  /** For a freeze-frame clip: the annotation time the calibration is authored for. */
  annotationTime?: number;
  /** Existing calibration to edit; defaults to `clip.groundCalibration`. */
  existing?: GroundCalibration | null;
  /** `null` removes the calibration. */
  onApply(calibration: GroundCalibration | null): void;
  onClose(): void;
}

type Tone = "neutral" | "positive" | "warning";
const HANDLE_RADIUS = 13;
const LOUPE_SIZE: Size = { width: 112, height: 100 };
const SIGNAL = "rgb(209 255 64)";

function grade(quality: SnapQuality): FitGrade { return qualityGrade(quality); }
const toneColor = (g: FitGrade) => (g === "good" ? SIGNAL : g === "check" ? "#ff9500" : "#ff3b30");

export function GroundCalibrationSheet({ clip, time, annotationTime, existing: existingProp, onApply, onClose }: GroundCalibrationSheetProps) {
  const existing = existingProp === undefined ? clip.groundCalibration ?? null : existingProp;
  const isStill = clip.freezeDuration != null;
  const request = useMemo(() => ({
    sourceTime: time ?? clip.startSeconds, annotationTime: annotationTime ?? time ?? clip.startSeconds, existing, isStill,
    sourceRange: [clip.startSeconds, clip.endSeconds] as TimeRange, cameraMotion: (sharedCamera(clip.trackingLibrary) ?? existing?.cameraMotion ?? null) as AnnotationCameraMotion | null,
  }), [clip, time, annotationTime, existing, isStill]);
  const referenceTimeAt = useCallback((source: number) => (request.isStill ? request.annotationTime : source), [request]);
  const relocating = useCallback((draft: GroundCalibration, source: number): GroundCalibration | null => {
    const original: GroundCalibration = { ...draft, cameraMotion: request.cameraMotion ?? request.existing?.cameraMotion ?? undefined };
    const moved = frozenCalibration(original, referenceTimeAt(source));
    return moved ? { ...moved, fixedCamera: draft.fixedCamera, cameraMotion: original.cameraMotion } : null;
  }, [request, referenceTimeAt]);

  // Reference draft
  const initialLandmark: GroundLandmark = existing?.fieldReference?.landmark ?? (existing ? "custom" : "penaltyArea");
  const [usesLines, setUsesLines] = useState(existing?.lineReferences != null);
  const [mode, setMode] = useState<GroundCalibrationMode>(existing?.mode ?? GROUND_LANDMARK_INFO[initialLandmark].mode);
  const [landmark, setLandmark] = useState<GroundLandmark>(initialLandmark);
  const [points, setPoints] = useState<Point[]>(() => (existing ? editingAnchors(existing, initialLandmark) : seedAnchors(initialLandmark)));
  const [lines, setLines] = useState<GroundLineObservation[]>(existing?.lineReferences ?? []);
  const [selectedLine, setSelectedLine] = useState<GroundPitchLine>("leftGoal");
  const [circle, setCircle] = useState<GroundCircleReference | null>(existing?.circleReference ?? null);
  const [editingHalfway, setEditingHalfway] = useState(false);
  const [centerPlaced, setCenterPlaced] = useState(existing?.circleReference != null);
  const [length, setLength] = useState(existing?.lengthMeters ?? GROUND_LANDMARK_INFO[initialLandmark].defaultLengthMeters);
  const [width, setWidth] = useState(existing?.widthMeters ?? GROUND_LANDMARK_INFO[initialLandmark].defaultWidthMeters);
  const [pitchLength, setPitchLength] = useState(existing?.fieldReference?.pitchLength ?? 105);
  const [pitchWidth, setPitchWidth] = useState(existing?.fieldReference?.pitchWidth ?? 68);
  const [fixedCamera, setFixedCamera] = useState(isStill || existing?.fixedCamera === true);
  const [goalOnRight, setGoalOnRight] = useState(true);

  // Frame
  const sourceRef = useRef<FrameSource | null>(null);
  const [sourceTime, setSourceTime] = useState(request.sourceTime);
  const [displayedTime, setDisplayedTime] = useState(request.sourceTime);
  const [frameRange, setFrameRange] = useState<TimeRange>(request.sourceRange);
  const [frameRate, setFrameRate] = useState(30);
  const [loadingFrame, setLoadingFrame] = useState(true);
  const [image, setImage] = useState<ImageBitmap | null>(null);
  const [sourceSize, setSourceSize] = useState<Size>({ width: 0, height: 0 });

  // Interaction
  const [active, setActive] = useState(0);
  const [checked, setChecked] = useState(existing != null);
  const [showsAdjustments, setShowsAdjustments] = useState(false);
  const [showOverlay, setShowOverlay] = useState(true);
  const [showSettings, setShowSettings] = useState(false);
  const [loupePinned, setLoupePinned] = useState(false);
  const [fineTuning, setFineTuning] = useState(false);
  const [suggestions, setSuggestions] = useState<Point[]>([]);
  const [viewport, setViewport] = useState<PlacementViewport>(DEFAULT_VIEWPORT);
  const [finger, setFinger] = useState<Point | null>(null);

  // Automation
  const [notice, setNotice] = useState<string | null>(null);
  const [scanning, setScanning] = useState(false);
  const [progressTitle, setProgressTitle] = useState("Working…");
  const [quality, setQuality] = useState<SnapQuality | null>(null);
  const snappedRef = useRef<{ points: Point[] | null; lines: GroundLineObservation[] | null }>({ points: null, lines: null });
  const [circleSensitivity, setCircleSensitivity] = useState<number | null>(null);
  const pendingReference = useRef<{ time: number; proposal: FieldProposal; autoSnap: boolean } | null>(null);
  const jobRef = useRef<AbortController | null>(null);

  const aspect = image ? image.width / Math.max(1, image.height) : 16 / 9;

  const invalidateSnap = useCallback(() => { setQuality(null); snappedRef.current = { points: null, lines: null }; }, []);

  const lineFit = useMemo(() => fitLines(lines, pitchLength, pitchWidth, referenceTimeAt(displayedTime), aspect, fixedCamera), [lines, pitchLength, pitchWidth, referenceTimeAt, displayedTime, aspect, fixedCamera]);

  const calibration = useMemo<GroundCalibration>(() => {
    if (usesLines) {
      if (lineFit) return lineFit.calibration;
      if (lines.length === 0 && request.existing) { const moved = relocating(request.existing, displayedTime); if (moved) return moved; }
      return { mode: "plane", points: [], lengthMeters: pitchWidth, widthMeters: pitchLength, referenceTime: referenceTimeAt(displayedTime), imageAspectRatio: aspect, fixedCamera };
    }
    const anchors = circle ? circleAnchors(circle) ?? [] : points;
    const result: GroundCalibration = {
      mode, points: calibrationCorners(anchors, landmark), lengthMeters: length, widthMeters: landmark === "centreCircle" ? length : width,
      referenceTime: referenceTimeAt(displayedTime), imageAspectRatio: aspect, fixedCamera,
    };
    if (mode === "plane" && landmark !== "custom") result.fieldReference = { landmark, pitchLength, pitchWidth };
    if (circle) result.circleReference = circle;
    return result;
  }, [usesLines, lineFit, lines.length, request.existing, relocating, displayedTime, pitchWidth, pitchLength, referenceTimeAt, aspect, fixedCamera, circle, points, mode, landmark, length, width]);

  const valid = calibrationIsValid(calibration);
  const editingPoints: Point[] = usesLines ? lines.find((l) => l.kind === selectedLine)?.points ?? [] : circle ? (editingHalfway ? circle.halfway : circle.farTouchline ?? [circle.center]) : points;
  const editingCount = usesLines ? 2 : circle ? (editingHalfway || circle.farTouchline ? 2 : 1) : mode === "plane" ? 4 : 2;
  const drawingLine = usesLines || (!editingHalfway && circle?.farTouchline != null);

  const updateCenterFromTouchline = useCallback((c: GroundCircleReference | null, diameter = length, pitch = pitchWidth): GroundCircleReference | null => {
    if (!c?.farTouchline) return c;
    const center = circleCenterFromTouchline(c, pitch, diameter);
    setCenterPlaced(center != null);
    return center ? { ...c, center } : c;
  }, [length, pitchWidth]);

  const setEditingPoints = useCallback((value: Point[]) => {
    setChecked(false);
    if (usesLines) {
      setLines((current) => (current.some((l) => l.kind === selectedLine) ? current.map((l) => (l.kind === selectedLine ? { ...l, points: value } : l)) : [...current, { kind: selectedLine, points: value }]));
      return;
    }
    if (!circle) { setPoints(value); return; }
    let next: GroundCircleReference = circle;
    if (editingHalfway) next = { ...circle, halfway: value };
    else if (circle.farTouchline) next = { ...circle, farTouchline: value };
    else if (value[0]) { next = { ...circle, center: value[0] }; setCenterPlaced(true); }
    setCircle(updateCenterFromTouchline(next));
  }, [usesLines, selectedLine, circle, editingHalfway, updateCenterFromTouchline]);

  // Edits clear the snap grade and the review.
  const pointsKey = JSON.stringify(points), linesKey = JSON.stringify(lines);
  useEffect(() => { setChecked(false); if (JSON.stringify(snappedRef.current.points) !== pointsKey) invalidateSnap(); }, [pointsKey, invalidateSnap]);
  useEffect(() => { if (JSON.stringify(snappedRef.current.lines) !== linesKey) invalidateSnap(); }, [linesKey, invalidateSnap]);
  useEffect(() => { setCircleSensitivity(circle ? circlePixelSensitivity(circle, sourceSize) : null); if (circle) invalidateSnap(); }, [circle, sourceSize, invalidateSnap]);
  useEffect(() => { setChecked(false); invalidateSnap(); }, [usesLines, width, pitchLength, invalidateSnap]);
  useEffect(() => { setChecked(false); invalidateSnap(); setCircle((c) => updateCenterFromTouchline(c)); }, [length, pitchWidth, invalidateSnap, updateCenterFromTouchline]);

  const frameReady = image != null && !loadingFrame && sourceTime === displayedTime && !scanning;
  const canSnap = frameReady && (!usesLines || lineFit != null) && (circle != null || (valid && calibration.mode === "plane" && calibration.fieldReference != null));
  const canApply = valid && (usesLines || !circle || centerPlaced) && frameReady && checked;

  // MARK: - Frames

  useEffect(() => () => { sourceRef.current?.close(); sourceRef.current = null; jobRef.current?.abort(); }, []);

  useEffect(() => {
    let cancelled = false;
    const target = sourceTime;
    setLoadingFrame(true);
    (async () => {
      try {
        if (!sourceRef.current) {
          const recording = await recordings.get(clip.recordingID);
          if (!recording?.localPath) throw new Error("missing file");
          sourceRef.current = await openFrameSource(recording);
        }
        const source = sourceRef.current;
        const rate = source.frameRate > 0 ? source.frameRate : 30;
        const lower = Math.min(request.sourceRange[0], request.sourceTime);
        const upper = Math.max(lower, Math.min(source.duration - 1 / rate, Math.max(request.sourceRange[1], request.sourceTime)));
        if (cancelled) return;
        if (!request.isStill && target > upper) { setFrameRange([lower, upper]); setSourceTime(upper); return; }
        const frame = await source.frameAt(Math.min(upper, target));
        if (cancelled || !frame) { frame?.close(); if (!cancelled) setNotice("Could not open this frame. Choose another position."); return; }
        const bitmap = await createImageBitmap(frame);
        frame.close();
        if (cancelled) { bitmap.close(); return; }
        if (image && displayedTime !== target) {
          const moved = relocating(calibration, target);
          if (moved) {
            if (usesLines) setLines(moved.lineReferences ?? []);
            else { setPoints(editingAnchors(moved, landmark)); setCircle(moved.circleReference ?? null); }
          } else {
            setCircle(null); setCenterPlaced(false);
            if (usesLines) setLines([]);
            setNotice("Align the reference on this frame, then confirm the lines.");
          }
          setChecked(false);
        }
        setSourceSize({ width: source.width, height: source.height }); setFrameRate(rate); setFrameRange([lower, upper]);
        setDisplayedTime(target);
        setImage((previous) => { previous?.close(); return bitmap; });
        const pending = pendingReference.current;
        if (pending && Math.abs(pending.time - target) < 1 / 600) {
          pendingReference.current = null;
          useProposal(pending.proposal, target);
          if (pending.autoSnap) setTimeout(() => { void snapToMarkings(); }, 0);
        }
      } catch {
        if (!cancelled) setNotice(typeof VideoFrame === "undefined" ? "This browser cannot decode video frames for field setup." : "Could not open this frame. Choose another position.");
      } finally {
        if (!cancelled) setLoadingFrame(false);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sourceTime]);

  useEffect(() => {
    setChecked(false); setFineTuning(false); setSuggestions([]); setNotice(null); invalidateSnap();
  }, [sourceTime, invalidateSnap]);

  const setFrame = (value: number) => {
    const next = Math.min(frameRange[1], Math.max(frameRange[0], Math.round(value * frameRate) / frameRate));
    if (Math.abs(next - sourceTime) > 0.0001) setSourceTime(next);
  };

  // MARK: - Editing actions

  const chooseLandmark = useCallback((value: GroundLandmark, right = goalOnRight) => {
    setCircle(null); setCenterPlaced(false); setEditingHalfway(false); setUsesLines(false);
    setLandmark(value); setMode(GROUND_LANDMARK_INFO[value].mode); setActive(0); setChecked(false); setShowOverlay(true);
    setPoints(seedAnchors(value, right));
    setLength(GROUND_LANDMARK_INFO[value].defaultLengthMeters); setWidth(GROUND_LANDMARK_INFO[value].defaultWidthMeters);
  }, [goalOnRight]);

  const chooseLines = () => { setCircle(null); setCenterPlaced(false); setEditingHalfway(false); setUsesLines(true); setActive(0); setChecked(false); setShowOverlay(true); };
  const changeMode = (value: GroundCalibrationMode) => { setMode(value); setActive(0); setChecked(false); setPoints(value === "plane" ? seedAnchors("penaltyArea", goalOnRight) : seedAnchors("custom")); };
  const flipGoalSide = () => { setPoints((p) => p.map((q) => ({ x: 1 - q.x, y: q.y }))); setGoalOnRight((g) => !g); };
  const nudge = (dx: number, dy: number) => {
    const selected = editingPoints.slice();
    if (!(active < selected.length) || !(sourceSize.width > 0)) return;
    selected[active] = nudgePoint(selected[active]!, dx, dy, sourceSize);
    setEditingPoints(selected); setFineTuning(true);
  };

  // MARK: - Automation

  const runJob = async <T,>(title: string, start: (signal: AbortSignal) => Promise<T>): Promise<T | null> => {
    jobRef.current?.abort();
    const controller = new AbortController();
    jobRef.current = controller;
    setScanning(true); setProgressTitle(title); setNotice(null);
    try { return await start(controller.signal); } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return null;
      throw error;
    } finally { if (jobRef.current === controller) { jobRef.current = null; setScanning(false); } }
  };

  const useProposal = (proposal: FieldProposal, at: number) => {
    chooseLandmark(proposal.landmark);
    if (proposal.registration && grade(proposal.registration.quality) !== "poor") {
      const anchors = editingAnchors(proposal.registration.calibration, proposal.landmark);
      setPoints(anchors); snappedRef.current = { points: anchors, lines: null };
      setQuality(proposal.registration.quality); setCircle(null); setCenterPlaced(false); setNotice(null);
      return;
    }
    const info = GROUND_LANDMARK_INFO[proposal.landmark];
    const draft: GroundCalibration = { mode: "plane", points: proposal.corners, lengthMeters: info.defaultLengthMeters, widthMeters: info.defaultWidthMeters, referenceTime: at, imageAspectRatio: aspect, fixedCamera: false };
    setPoints(editingAnchors(draft, proposal.landmark));
    setCircle(proposal.circle ?? null); setCenterPlaced(false); setEditingHalfway(false); setActive(0); setChecked(false); invalidateSnap();
    setNotice(proposal.circle ? "Circle found. Place the centre spot, then Snap to lines to refine the perspective." : "Starting alignment only. Refine the handles, then Snap to lines.");
  };

  const snapToMarkings = async () => {
    if (!image) return;
    let draft = calibration;
    if (!usesLines && circle) {
      const anchors = circleAnchors(circle);
      if (anchors) { setPoints(anchors); setCircle(null); setCenterPlaced(false); setEditingHalfway(false); draft = { ...calibration, points: calibrationCorners(anchors, landmark), circleReference: undefined }; }
    }
    if (!calibrationIsValid(draft) || draft.mode !== "plane" || !draft.fieldReference) { setNotice("Place a field reference before snapping."); return; }
    const frame = displayedTime;
    try {
      const output = await runJob("Snapping to the painted markings…", (signal) => api.snapField(clip, frame, draft, pitchLength, pitchWidth, usesLines ? lines : null, { signal }));
      if (!output) return;
      if (!output.result) { setNotice("No markings found near the overlay. Move it closer to the white lines and try again."); return; }
      if (usesLines) {
        if (!output.lines) { setNotice("Snapped alignment could not be applied to the traced lines."); return; }
        setLines(output.lines); snappedRef.current = { points: null, lines: output.lines };
      } else {
        const anchors = editingAnchors(output.result.calibration, landmark);
        setPoints(anchors); snappedRef.current = { points: anchors, lines: null };
      }
      setQuality(output.result.quality); setChecked(false);
    } catch { setNotice("Could not read this frame's markings."); }
  };

  const detectPitch = async () => {
    if (!image) return;
    const frame = displayedTime;
    try {
      const output = await runJob("Detecting the field and snapping to markings…", (signal) =>
        api.detectField(clip, frame, pitchLength, pitchWidth, request.isStill ? null : frameRange, (stage) => setProgressTitle(stage === "searching" ? "Searching the clip for a clear view of the field…" : "Detecting the field and snapping to markings…"), { signal }));
      if (!output) return;
      const first = output.proposals[0];
      if (!first) { setNotice("No field markings recognised in this clip. Use Adjust by hand to place a reference on a clear frame."); return; }
      if (Math.abs(output.time - frame) >= 1 / 600) { pendingReference.current = { time: output.time, proposal: first, autoSnap: true }; setSourceTime(output.time); return; }
      useProposal(first, frame);
      if (!(first.registration && grade(first.registration.quality) !== "poor")) setTimeout(() => { void snapToMarkings(); }, 0);
    } catch { setNotice("Automatic detection is unavailable here. Use Adjust by hand to place a reference, then Snap to lines."); }
  };

  const findIntersections = async () => {
    try {
      const output = await runJob("Finding marking intersections…", (signal) => api.detectLineIntersections(clip, displayedTime, { signal }));
      if (!output) return;
      setSuggestions(output.intersections);
      setNotice(output.intersections.length === 0 ? "No clear marking intersections found." : "Cyan dots mark possible intersections. Confirm them against the footage.");
    } catch { setNotice("Marking search unavailable. Align the reference manually."); }
  };

  // MARK: - Status

  const status = ((): { text: string; tone: Tone } => {
    if (scanning) return { text: progressTitle, tone: "neutral" };
    if (notice) return { text: notice, tone: "neutral" };
    if (!valid && !usesLines && !circle) return { text: "Corners cross or dimensions are missing. Adjust the reference before applying.", tone: "warning" };
    if (quality) {
      const g = grade(quality);
      if (g === "good") return { text: "Snapped to the painted markings. Check the overlay away from your points, then confirm.", tone: "positive" };
      if (g === "check") return { text: "Partly supported by markings. Zoom in on the lines without evidence before confirming.", tone: "warning" };
      return { text: "Few markings support this alignment. Choose a clearer frame or adjust the reference.", tone: "warning" };
    }
    if (usesLines) {
      if (lineFit) return { text: "Field fitted from your lines. Snap to lines refines it against the video.", tone: "neutral" };
      const missing = Math.max(0, 4 - lines.filter((l) => l.points.length === 2).length);
      return { text: `Trace visible parts of ${missing === 0 ? "more" : `${missing} more`} white lines, 2 in each field direction. Corners can be offscreen.`, tone: "neutral" };
    }
    if (circle) {
      if (circleSensitivity != null && circleSensitivity > 12 && centerPlaced) return { text: "Sharp angle · verify distant lines or choose a clearer frame.", tone: "warning" };
      if (centerPlaced) return { text: circle.farTouchline ? `Perspective from the far touchline · confirm the pitch width in settings (${pitchWidth} m).` : "Perspective fitted · check the overlay beyond the circle, or Snap to lines.", tone: "neutral" };
      return { text: circle.farTouchline ? `Trace the far touchline. Confirm the actual pitch width in settings (currently ${pitchWidth} m).` : "Place the point on the actual centre spot, or use Touchline if the spot is hidden.", tone: "warning" };
    }
    if (mode === "localScale") return { text: "Place both points on the ground at a known distance, then set it in settings.", tone: "neutral" };
    return { text: `Drag the numbered handles onto the ${GROUND_LANDMARK_INFO[landmark].title.toLowerCase()} corners, then Snap to lines.`, tone: "neutral" };
  })();

  // MARK: - Layout

  const [bodyRef, metrics] = useLayoutMetrics<HTMLDivElement>();
  const landscape = metrics.width > metrics.height;
  const previewLines = usesLines ? lines : circle ? (editingHalfway ? [{ kind: "halfway" as GroundPitchLine, points: circle.halfway }] : circle.farTouchline ? [{ kind: "farTouch" as GroundPitchLine, points: circle.farTouchline }] : []) : [];

  return (
    <div className="gcs-backdrop" data-surface="dark" role="dialog" aria-label="Field setup">
      <div className="gcs-sheet">
        <header className="gcs-header">
          <div className="gcs-header-side"><button type="button" className="gcs-control" data-plain onClick={onClose} data-testid="ground-cancel">Cancel</button></div>
          <h2>Field setup</h2>
          <div className="gcs-header-side" data-end><button type="button" className="gcs-control" data-plain disabled={!canApply} onClick={() => { onApply(calibration); onClose(); }} data-testid="ground-apply">Apply</button></div>
        </header>
        <div className="gcs-body" ref={bodyRef} data-landscape={landscape || undefined}>
          <div className="gcs-main">
            <PointCanvas image={image} points={editingPoints} count={editingCount} suggestions={suggestions} calibration={calibration} valid={valid} active={active} setActive={setActive}
              showOverlay={showOverlay} fineTuning={fineTuning} setFineTuning={setFineTuning} pinnedLoupe={loupePinned} referenceLines={previewLines} drawingLine={drawingLine}
              viewport={viewport} setViewport={setViewport} finger={finger} setFinger={setFinger} onChange={setEditingPoints} interactive={frameReady} loading={loadingFrame} notice={image ? null : notice}
              quality={showOverlay ? quality : null} />
            {!request.isStill && frameRange[1] > frameRange[0] && (
              <div className="gcs-transport">
                <div className="gcs-transport-row">
                  <button type="button" className="gcs-control" onClick={() => setFrame(sourceTime - 1)} aria-label="Back one second" data-testid="ground-second-back">−1s</button>
                  <button type="button" className="gcs-control" onClick={() => setFrame(sourceTime - 1 / frameRate)} aria-label="Previous frame" data-testid="ground-frame-back"><Icon.ChevronLeft /></button>
                  <span className="gcs-time" data-testid="ground-frame-time">{preciseDuration(sourceTime - frameRange[0])}</span>
                  <button type="button" className="gcs-control" onClick={() => setFrame(sourceTime + 1 / frameRate)} aria-label="Next frame" data-testid="ground-frame-forward"><Icon.ChevronRight /></button>
                  <button type="button" className="gcs-control" onClick={() => setFrame(sourceTime + 1)} aria-label="Forward one second" data-testid="ground-second-forward">+1s</button>
                </div>
                <input type="range" min={frameRange[0]} max={frameRange[1]} step={1 / frameRate} value={sourceTime} onChange={(e) => setFrame(Number(e.target.value))} aria-label="Field reference time" data-testid="ground-frame-scrubber" />
              </div>
            )}
          </div>
          <div className="gcs-controls">
            <div className="gcs-row">
              <select className="gcs-select" aria-label="Reference method" data-testid="ground-landmark-picker" value={usesLines ? "lines" : landmark}
                onChange={(e) => { const v = e.target.value; if (v === "lines") chooseLines(); else chooseLandmark(v as GroundLandmark); }}>
                <option value="lines">Trace lines</option>
                <optgroup label="Field overlay">
                  {(["penaltyArea", "goalArea", "centreCircle", "halfPitch", "fullPitch"] as GroundLandmark[]).map((l) => <option key={l} value={l}>{GROUND_LANDMARK_INFO[l].title}</option>)}
                </optgroup>
                <optgroup label="Other references">
                  <option value="goalWidth">Goal width · local scale</option>
                  <option value="custom">Custom distance / rectangle</option>
                </optgroup>
              </select>
              <span className="gcs-spacer" />
              {!usesLines && !circle && !["centreCircle", "goalWidth", "custom"].includes(landmark) && (
                <button type="button" className="gcs-control" data-plain onClick={flipGoalSide} data-testid="ground-goal-side">{goalOnRight ? "Goal on the right" : "Goal on the left"}</button>
              )}
            </div>
            <button type="button" className="gcs-action" data-prominent={quality == null || undefined} disabled={!frameReady} onClick={() => { void detectPitch(); }} data-testid="ground-auto-align">
              <Icon.Sparkles />{quality == null ? "Detect field" : "Detect again"}
            </button>
            <div className="gcs-status" data-tone={status.tone} role="status" data-testid={usesLines ? "ground-line-status" : circle ? "ground-circle-status" : "ground-status"}>
              {scanning ? <Spinner size={14} /> : <span className="gcs-status-dot" />}
              <span>{status.text}</span>
            </div>
            <button type="button" className="gcs-control" data-plain style={{ width: "100%", minHeight: 36 }} onClick={() => setShowsAdjustments((v) => !v)} data-testid="ground-adjustments">
              {showsAdjustments ? <Icon.ChevronDown style={{ transform: "rotate(180deg)" }} /> : <Icon.ChevronDown />}{showsAdjustments ? "Hide adjustments" : "Adjust by hand"}
            </button>
            {showsAdjustments && (
              <>
                <div className="gcs-row" data-tight>
                  <button type="button" className="gcs-control" data-active={(canSnap && quality == null) || undefined} disabled={!canSnap} onClick={() => { void snapToMarkings(); }} data-testid="ground-snap"><Icon.Scope />Snap to lines</button>
                  <span className="gcs-spacer" />
                  <button type="button" className="gcs-control" onClick={() => setShowOverlay((v) => !v)} aria-label={showOverlay ? "Hide overlay" : "Show overlay"} data-testid="ground-overlay-toggle">{showOverlay ? <Icon.Eye /> : <Icon.EyeOff />}</button>
                  <button type="button" className="gcs-control" data-active={loupePinned || undefined} onClick={() => { setLoupePinned((v) => { setFineTuning(!v); return !v; }); }} aria-label={loupePinned ? "Hide loupe" : "Show loupe"} data-testid="ground-fine-tune"><Icon.Search /></button>
                  <button type="button" className="gcs-control" onClick={() => setShowSettings(true)} aria-label="Reference settings" data-testid="ground-settings"><Icon.Gear /></button>
                  <select className="gcs-select" aria-label="Alignment options" data-testid="ground-alignment-options" value="" onChange={(e) => {
                    const v = e.target.value;
                    if (v === "manual" && circle) { setPoints(circleAnchors(circle) ?? points); setCircle(null); setActive(0); setChecked(false); }
                    else if (v === "flip") flipGoalSide();
                    else if (v === "intersections") void findIntersections();
                    else if (v === "restart") { if (usesLines) { setLines([]); setChecked(false); } else chooseLandmark(landmark); }
                  }}>
                    <option value="">…</option>
                    {circle && <option value="manual">Use manual circle handles</option>}
                    {!usesLines && !circle && <option value="flip">Flip goal side</option>}
                    <option value="intersections">Find marking intersections</option>
                    <option value="restart">Restart reference</option>
                  </select>
                </div>
                {usesLines ? (
                  <div className="gcs-row" style={{ flexDirection: "column", alignItems: "stretch", gap: 4 }}>
                    <div className="gcs-row">
                      <select className="gcs-select" data-caption aria-label="Pitch line" data-testid="ground-line-picker" value={selectedLine} onChange={(e) => { setSelectedLine(e.target.value as GroundPitchLine); setActive(0); setFineTuning(false); }}>
                        {GROUND_PITCH_LINES.map((l) => <option key={l} value={l}>{GROUND_PITCH_LINE_TITLES[l]}</option>)}
                      </select>
                      <span className="gcs-spacer" />
                      <button type="button" className="gcs-control" onClick={() => { setEditingPoints([]); setActive(0); }} aria-label="Redraw line" data-testid="ground-redraw-line"><Icon.Trash /></button>
                    </div>
                    {lines.length > 0 && (
                      <div className="gcs-chips">
                        {lines.map((line) => <button key={line.kind} type="button" className="gcs-chip" data-active={line.kind === selectedLine || undefined} onClick={() => { setSelectedLine(line.kind); setActive(0); }}>{GROUND_PITCH_LINE_TITLES[line.kind]}</button>)}
                      </div>
                    )}
                  </div>
                ) : circle ? (
                  <div className="gcs-row">
                    <button type="button" className="gcs-control" data-plain data-muted={(editingHalfway || circle.farTouchline != null) || undefined} onClick={() => { if (circle.farTouchline) { setCircle({ ...circle, farTouchline: undefined }); setCenterPlaced(false); setChecked(false); } setEditingHalfway(false); setActive(0); }} data-testid="ground-circle-center"><Icon.Scope />Centre spot</button>
                    <span className="gcs-spacer" />
                    <button type="button" className="gcs-control" data-plain data-muted={!(circle.farTouchline != null && !editingHalfway) || undefined} onClick={() => { if (!circle.farTouchline) { setCircle({ ...circle, farTouchline: [] }); setCenterPlaced(false); setChecked(false); } setEditingHalfway(false); setActive(0); }} data-testid="ground-circle-touchline">Touchline</button>
                    <button type="button" className="gcs-control" data-plain data-muted={!editingHalfway || undefined} onClick={() => { setEditingHalfway(true); setActive(0); }} data-testid="ground-circle-halfway">Halfway line</button>
                  </div>
                ) : (
                  <div className="gcs-points">
                    {Array.from({ length: editingCount }, (_, i) => (
                      <button key={i} type="button" className="gcs-point" aria-pressed={active === i} onClick={() => setActive(i)} aria-label={`Point ${i + 1}, ${handleNames(landmark, editingCount)[i]}`} data-testid={`ground-point-${i}`}>{i + 1}</button>
                    ))}
                    <ReferenceDiagram landmark={landmark} active={active} mode={mode} />
                  </div>
                )}
                <div className="gcs-nudge" aria-label="Fine tune selected field point">
                  <span>Nudge 1 px</span>
                  {([["Left", -1, 0, "←"], ["Up", 0, -1, "↑"], ["Down", 0, 1, "↓"], ["Right", 1, 0, "→"]] as [string, number, number, string][]).map(([name, dx, dy, glyph]) => (
                    <button key={name} type="button" disabled={!frameReady || !(active < editingPoints.length) || !showOverlay} onClick={() => nudge(dx, dy)} aria-label={`Move point ${name.toLowerCase()} one pixel`} data-testid={`ground-nudge-${name.toLowerCase()}`}>{glyph}</button>
                  ))}
                </div>
              </>
            )}
            <label className="gcs-review">
              <input type="checkbox" checked={checked} disabled={!valid || !frameReady} onChange={(e) => setChecked(e.target.checked)} data-testid="ground-review" />
              Lines align with the video
            </label>
          </div>
        </div>
        {showSettings && (
          <div className="gcs-settings" data-testid="ground-settings-sheet">
            <header className="gcs-header">
              <div className="gcs-header-side" />
              <h2>Reference settings</h2>
              <div className="gcs-header-side" data-end><button type="button" className="gcs-control" data-plain onClick={() => setShowSettings(false)}>Done</button></div>
            </header>
            <div className="gcs-settings-body">
              <section className="gcs-section">
                <h3>Dimensions · metres</h3>
                <div className="gcs-section-card">
                  {landmark === "custom" && !usesLines && (
                    <div className="gcs-field">
                      <span>Reference</span><span className="gcs-spacer" />
                      <select className="gcs-select" data-caption value={mode} onChange={(e) => changeMode(e.target.value as GroundCalibrationMode)} data-testid="ground-reference-mode">
                        <option value="localScale">2 points · local</option><option value="plane">4 points · ground</option>
                      </select>
                    </div>
                  )}
                  {!usesLines && <Dimension title={landmark === "centreCircle" ? "Circle diameter" : mode === "plane" ? "Reference width" : "Known distance"} value={length} onChange={setLength} id="ground-length" />}
                  {!usesLines && mode === "plane" && landmark !== "centreCircle" && <Dimension title="Reference depth" value={width} onChange={setWidth} id="ground-width" />}
                  {(usesLines || (mode === "plane" && !["custom", "halfPitch", "fullPitch"].includes(landmark))) && (
                    <>
                      <Dimension title="Pitch length" value={pitchLength} onChange={setPitchLength} id="ground-pitch-length" />
                      <Dimension title="Pitch width" value={pitchWidth} onChange={setPitchWidth} id="ground-pitch-width" />
                    </>
                  )}
                  <p className="gcs-caption">{usesLines ? "Trace any visible part of named lines; their intersections may be offscreen." : GROUND_LANDMARK_INFO[landmark].guidance}</p>
                  <p className="gcs-caption">Football defaults are editable. The overlay is an alignment aid, not proof of accurate measurements.</p>
                </div>
              </section>
              {!request.isStill && (
                <section className="gcs-section">
                  <h3>Camera</h3>
                  <div className="gcs-section-card">
                    <div className="gcs-field"><span>Camera stays fixed</span><span className="gcs-spacer" /><button type="button" role="switch" aria-checked={fixedCamera} className="gcs-switch" onClick={() => setFixedCamera((v) => !v)} aria-label="Camera stays fixed" /></div>
                    <p className="gcs-caption">Leave off for moving footage. One camera track is reused for measurements and floor effects.</p>
                  </div>
                </section>
              )}
              {quality && (
                <section className="gcs-section">
                  <h3>Snap result</h3>
                  <div className="gcs-section-card">
                    <div className="gcs-field"><span>Fit</span><span className="gcs-spacer" /><span className="gcs-value">{FIT_GRADE_TITLES[grade(quality)]}</span></div>
                    <div className="gcs-field"><span>Median residual</span><span className="gcs-spacer" /><span className="gcs-value">{quality.residualPixels.toFixed(2)} px</span></div>
                    <div className="gcs-field"><span>Evidence coverage</span><span className="gcs-spacer" /><span className="gcs-value">{Math.round(quality.coverage * 100)}%</span></div>
                    <div className="gcs-field"><span>Supported lines</span><span className="gcs-spacer" /><span className="gcs-value">{quality.supportedLines}</span></div>
                    <p className="gcs-caption">Residual and coverage describe agreement with visible paint, not metric accuracy.</p>
                  </div>
                </section>
              )}
              {request.existing && (
                <section className="gcs-section"><div className="gcs-section-card"><button type="button" className="gcs-destructive" onClick={() => { onApply(null); onClose(); }}>Remove calibration</button></div></section>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/** Commits on every keystroke, so closing the settings never drops a value. */
function Dimension({ title, value, onChange, id }: { title: string; value: number; onChange(value: number): void; id: string }) {
  const [text, setText] = useState(() => formatDimension(value));
  const [editing, setEditing] = useState(false);
  useEffect(() => { if (!editing) setText(formatDimension(value)); }, [value, editing]);
  return (
    <div className="gcs-field">
      <span>{title}</span><span className="gcs-spacer" />
      <input type="text" inputMode="decimal" value={text} aria-label={title} data-testid={id} onFocus={() => setEditing(true)} onBlur={() => setEditing(false)}
        onChange={(e) => {
          setText(e.target.value);
          const normalized = e.target.value.replace(",", ".");
          const parsed = Number(normalized);
          if (normalized.length > 0 && Number.isFinite(parsed) && parsed >= 0) onChange(parsed);
          else if (normalized.length === 0) onChange(0);
        }} />
    </div>
  );
}
const formatDimension = (value: number) => (Number.isInteger(value) ? String(value) : String(Math.round(value * 1000) / 1000));

/** Small template diagram with the numbered anchors (port of GroundReferenceDiagram). */
function ReferenceDiagram({ landmark, active, mode }: { landmark: GroundLandmark; active: number; mode: GroundCalibrationMode }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current, context = canvas?.getContext("2d");
    if (!canvas || !context) return;
    const scale = window.devicePixelRatio || 1;
    canvas.width = 96 * scale; canvas.height = 44 * scale;
    context.scale(scale, scale);
    context.clearRect(0, 0, 96, 44);
    const frame: Rect = { x: 10, y: 9, width: 76, height: 26 };
    const anchors = mode === "plane" ? referenceAnchors(landmark) : [{ x: 0, y: 0.5 }, { x: 1, y: 0.5 }];
    const info = GROUND_LANDMARK_INFO[landmark];
    const calibration: GroundCalibration = { mode, points: mode === "plane" ? RECTANGLE.slice() : anchors, lengthMeters: Math.max(1, info.defaultLengthMeters), widthMeters: Math.max(1, info.defaultWidthMeters), referenceTime: 0, imageAspectRatio: 1, fixedCamera: false, fieldReference: { landmark, pitchLength: 105, pitchWidth: 68 } };
    context.lineWidth = 1; context.strokeStyle = "rgb(255 255 255 / 0.5)";
    for (const line of overlayPolylines(calibration, frame)) strokePolyline(context, line);
    context.lineWidth = 1.5; context.strokeStyle = SIGNAL;
    strokePolyline(context, referencePolyline(calibration, frame));
    anchors.forEach((point, i) => {
      const p = { x: frame.x + point.x * frame.width, y: frame.y + point.y * frame.height };
      context.beginPath(); context.arc(p.x, p.y, 6.5, 0, Math.PI * 2); context.fillStyle = active === i ? SIGNAL : "#000"; context.fill();
      context.fillStyle = active === i ? "#000" : "#fff"; context.font = "bold 8px system-ui"; context.textAlign = "center"; context.textBaseline = "middle"; context.fillText(String(i + 1), p.x, p.y);
    });
  }, [landmark, active, mode]);
  return <div className="gcs-diagram" aria-hidden><canvas ref={ref} /></div>;
}

function strokePolyline(context: CanvasRenderingContext2D, points: readonly Point[]) {
  if (points.length < 2) return;
  context.beginPath();
  points.forEach((p, i) => (i === 0 ? context.moveTo(p.x, p.y) : context.lineTo(p.x, p.y)));
  context.stroke();
}

interface PointCanvasProps {
  image: ImageBitmap | null; points: Point[]; count: number; suggestions: Point[]; calibration: GroundCalibration; valid: boolean;
  active: number; setActive(index: number): void; showOverlay: boolean; fineTuning: boolean; setFineTuning(value: boolean): void; pinnedLoupe: boolean;
  referenceLines: GroundLineObservation[]; drawingLine: boolean; viewport: PlacementViewport; setViewport(v: PlacementViewport): void;
  finger: Point | null; setFinger(p: Point | null): void; onChange(points: Point[]): void; interactive: boolean; loading: boolean; notice: string | null; quality: SnapQuality | null;
}

/** The frame with the projected overlay, handles and loupe; one pointer edits, two pan/zoom (port of GroundPointCanvas). */
function PointCanvas(props: PointCanvasProps) {
  const { image, points, count, suggestions, calibration, valid, active, setActive, showOverlay, fineTuning, setFineTuning, pinnedLoupe, referenceLines, drawingLine, viewport, setViewport, finger, setFinger, onChange, interactive } = props;
  const [hostRef, metrics] = useLayoutMetrics<HTMLDivElement>();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const loupeRef = useRef<HTMLCanvasElement>(null);
  const touches = useRef(new Map<number, Point>());
  const touchState = useRef(new FieldPlacementTouchState());
  const navigationStart = useRef<PlacementViewport | null>(null);
  const original = useRef<{ points: Point[]; active: number } | null>(null);
  const offset = useRef<Point>({ x: 0, y: 0 });
  const latest = useRef({ points, active, count, drawingLine, viewport });
  latest.current = { points, active, count, drawingLine, viewport };

  const bounds: Rect = { x: 0, y: 0, width: metrics.width, height: metrics.height };
  const fitted: Rect = useMemo(() => {
    if (!image || bounds.width <= 0 || bounds.height <= 0) return bounds;
    const scale = Math.min(bounds.width / image.width, bounds.height / image.height);
    const w = image.width * scale, h = image.height * scale;
    return { x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h };
  }, [image, bounds.width, bounds.height]);
  const frame = viewportFrame(viewport, fitted);

  useEffect(() => {
    const canvas = canvasRef.current, context = canvas?.getContext("2d");
    if (!canvas || !context || bounds.width <= 0) return;
    const scale = window.devicePixelRatio || 1;
    canvas.width = Math.round(bounds.width * scale); canvas.height = Math.round(bounds.height * scale);
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.fillStyle = "#141414"; context.fillRect(0, 0, bounds.width, bounds.height);
    if (!image) return;
    context.drawImage(image, frame.x, frame.y, frame.width, frame.height);
    if (!showOverlay) return;
    const map = (p: Point): Point => ({ x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height });
    context.save(); context.beginPath(); context.rect(frame.x, frame.y, frame.width, frame.height); context.clip();
    const projected = overlayPolylines(calibration, frame);
    context.lineWidth = 3; context.strokeStyle = "rgb(0 0 0 / 0.7)"; for (const line of projected) strokePolyline(context, line);
    context.lineWidth = 1.3; context.strokeStyle = "rgb(255 255 255 / 0.9)"; for (const line of projected) strokePolyline(context, line);
    if (!drawingLine) {
      const reference = referencePolyline(calibration, frame);
      context.lineWidth = 4; context.strokeStyle = "#000"; strokePolyline(context, reference);
      context.lineWidth = 2; context.strokeStyle = valid ? SIGNAL : "#ff9500"; strokePolyline(context, reference);
    }
    context.restore();
    referenceLines.forEach((line, index) => {
      if (line.points.length !== 2) return;
      const a = map(line.points[0]!), b = map(line.points[1]!);
      context.lineWidth = 5; context.strokeStyle = "#000"; strokePolyline(context, [a, b]);
      context.lineWidth = 2; context.strokeStyle = "cyan"; strokePolyline(context, [a, b]);
      context.fillStyle = "#fff"; context.font = "bold 12px system-ui"; context.textAlign = "center"; context.textBaseline = "middle";
      context.fillText(String(index + 1), (a.x + b.x) / 2, (a.y + b.y) / 2 - 12);
    });
    for (const s of suggestions) { const p = map(s); context.beginPath(); context.arc(p.x, p.y, 4, 0, Math.PI * 2); context.lineWidth = 1; context.strokeStyle = "cyan"; context.stroke(); }
    points.forEach((point, i) => {
      const p = map(point);
      context.beginPath(); context.arc(p.x, p.y, HANDLE_RADIUS, 0, Math.PI * 2);
      context.fillStyle = i === active ? SIGNAL : "#000"; context.fill();
      context.lineWidth = 1.5; context.strokeStyle = "#fff"; context.stroke();
      context.fillStyle = i === active ? "#000" : "#fff"; context.font = "bold 12px system-ui"; context.textAlign = "center"; context.textBaseline = "middle";
      context.fillText(String(i + 1), p.x, p.y);
    });
  }, [image, bounds.width, bounds.height, frame.x, frame.y, frame.width, frame.height, showOverlay, calibration, valid, drawingLine, referenceLines, suggestions, points, active]);

  const showLoupe = showOverlay && image && active < points.length && (finger != null || fineTuning || pinnedLoupe);
  const focus = finger ?? (active < points.length ? { x: frame.x + points[active]!.x * frame.width, y: frame.y + points[active]!.y * frame.height } : { x: 0, y: 0 });
  const loupeAt = showLoupe ? loupeCenter(focus, bounds, LOUPE_SIZE) : null;
  useEffect(() => {
    const canvas = loupeRef.current, context = canvas?.getContext("2d");
    if (!canvas || !context || !image || !showLoupe) return;
    const point = points[active]!;
    const magnification = Math.max(fineTuning || pinnedLoupe ? 4 : 1.5, (frame.width / image.width) * 2);
    const scale = window.devicePixelRatio || 1;
    canvas.width = LOUPE_SIZE.width * scale; canvas.height = LOUPE_SIZE.height * scale;
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.fillStyle = "#000"; context.fillRect(0, 0, LOUPE_SIZE.width, LOUPE_SIZE.height);
    context.imageSmoothingEnabled = false;
    context.drawImage(image, LOUPE_SIZE.width / 2 - point.x * image.width * magnification, LOUPE_SIZE.height / 2 - point.y * image.height * magnification, image.width * magnification, image.height * magnification);
  }, [image, showLoupe, points, active, fineTuning, pinnedLoupe, frame.width]);

  const handle = (action: TouchAction) => {
    const { points: current, active: currentActive, count: max, drawingLine: drawing, viewport: vp } = latest.current;
    const frameNow = viewportFrame(vp, fitted);
    const move = (location: Point) => {
      setFinger(location);
      const target = { x: location.x + offset.current.x, y: location.y + offset.current.y };
      const point = sourcePoint(target, frameNow, true);
      if (currentActive < current.length) { const next = current.slice(); next[currentActive] = point; onChange(next); }
      else if (currentActive === current.length && current.length < max) onChange([...current, point]);
    };
    switch (action.type) {
      case "beginCorner": {
        setFineTuning(false);
        original.current = { points: current.slice(), active: currentActive }; offset.current = { x: 0, y: 0 };
        if (drawing && current.length < 2) {
          const point = sourcePoint(action.location, frameNow, true);
          onChange(current.length === 0 ? [point, point] : [...current, point]);
          setActive(1); setFinger(action.location);
          return;
        }
        let nearest = -1, best = Infinity;
        current.forEach((p, i) => { const d = Math.hypot(frameNow.x + p.x * frameNow.width - action.location.x, frameNow.y + p.y * frameNow.height - action.location.y); if (d < best) { best = d; nearest = i; } });
        if (nearest >= 0 && best <= 28) {
          const p = current[nearest]!;
          setActive(nearest); latest.current.active = nearest;
          offset.current = { x: frameNow.x + p.x * frameNow.width - action.location.x, y: frameNow.y + p.y * frameNow.height - action.location.y };
        }
        move(action.location);
        return;
      }
      case "moveCorner": move(action.location); return;
      case "endCorner": {
        if (drawing && current.length === 2 && Math.hypot((current[1]!.x - current[0]!.x) * frameNow.width, (current[1]!.y - current[0]!.y) * frameNow.height) < 8) { onChange(current.slice(0, 1)); setActive(1); }
        const before = original.current;
        if (before && current.length > before.points.length && current.length < max) setActive(current.length);
        original.current = null; setFinger(null);
        return;
      }
      case "cancelCorner": {
        if (original.current) { onChange(original.current.points); setActive(original.current.active); }
        original.current = null; setFinger(null);
        return;
      }
      case "beginNavigation": navigationStart.current = vp; setFinger(null); setFineTuning(false); return;
      case "navigate": if (navigationStart.current) setViewport(navigateViewport(navigationStart.current, action.scale, action.from, action.to, fitted)); return;
      case "endNavigation": navigationStart.current = null; return;
    }
  };

  const local = (e: { clientX: number; clientY: number; currentTarget: Element }) => { const rect = e.currentTarget.getBoundingClientRect(); return { x: e.clientX - rect.left, y: e.clientY - rect.top }; };
  const dispatch = () => { for (const action of touchState.current.update([...touches.current.values()])) handle(action); };
  const onPointerDown = (e: ReactPointerEvent<HTMLCanvasElement>) => { if (!interactive || !showOverlay) return; e.currentTarget.setPointerCapture(e.pointerId); touches.current.set(e.pointerId, local(e)); dispatch(); };
  const onPointerMove = (e: ReactPointerEvent<HTMLCanvasElement>) => { if (!touches.current.has(e.pointerId)) return; touches.current.set(e.pointerId, local(e)); dispatch(); };
  const onPointerUp = (e: ReactPointerEvent<HTMLCanvasElement>) => {
    if (!touches.current.has(e.pointerId)) return;
    if (touches.current.size === 1) { touches.current.set(e.pointerId, local(e)); dispatch(); }
    touches.current.delete(e.pointerId); dispatch();
  };
  const onPointerCancel = () => { for (const action of touchState.current.cancel()) handle(action); touches.current.clear(); };
  const onWheel = (e: ReactWheelEvent<HTMLCanvasElement>) => {
    if (!interactive) return;
    const location = local(e);
    setViewport(navigateViewport(viewport, e.ctrlKey || e.metaKey ? Math.exp(-e.deltaY * 0.01) : 1, location, e.ctrlKey || e.metaKey ? location : { x: location.x - e.deltaX, y: location.y - e.deltaY }, fitted));
  };

  return (
    <div className="gcs-preview" ref={hostRef} data-testid="ground-preview" aria-label="Field placement image" role="img" data-points={points.map((p) => `${p.x.toFixed(4)},${p.y.toFixed(4)}`).join("; ")}>
      <canvas ref={canvasRef} onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel} onWheel={onWheel} aria-label="One finger places a corner. Two fingers pan and pinch to zoom." data-testid="field-placement-touch-surface" />
      {props.loading && <div className="gcs-loading"><Spinner /></div>}
      {!image && !props.loading && <div className="gcs-empty">{props.notice ?? "Loading frame…"}</div>}
      {props.quality && (
        <div className="gcs-quality" data-testid="ground-quality" aria-label="Snap quality">
          <span className="gcs-quality-dot" style={{ background: toneColor(grade(props.quality)) }} />{qualitySummary(props.quality)}
        </div>
      )}
      <button type="button" className="gcs-control gcs-fit" onClick={() => setViewport(DEFAULT_VIEWPORT)} aria-label="Fit preview"><Icon.Scope /></button>
      {loupeAt && <div className="gcs-loupe" style={{ left: loupeAt.x, top: loupeAt.y }} aria-label="Selected field point magnified" data-testid="ground-point-loupe"><canvas ref={loupeRef} /></div>}
    </div>
  );
}
