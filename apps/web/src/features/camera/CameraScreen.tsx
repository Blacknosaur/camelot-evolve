import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from "react";
import { useNavigate, useParams } from "react-router";
import { defaultPostRoll, defaultPreRoll, newId, type EventKind, type MatchEvent, type Recording } from "@/domain";
import { Icon } from "@/design/icons";
import { Spinner } from "@/design/components";
import { compactDuration } from "@/design/format";
import { useLayoutMetrics } from "@/design/layout";
import * as repository from "@/storage/repository";
import { routes } from "@/app/router";
import { CameraRecorder } from "./camera-recorder";
import { bufferSeconds, CAPTURE_MODES, CAPTURE_QUALITIES, captureModeShortTitle, captureModeTitle, isRollingMode, qualityShortTitle, qualityTitle, type CaptureMode, type CaptureQuality } from "./capture-mode";
import { addEvent, advance, emptyEventCapture, endNow, endOffset, finishSegment, selectEvent, type EventCaptureState, type ShortenedEvent } from "./event-capture";
import { CameraDialog, CameraMenu, CaptureDock, ChromeButton, EventCountdown, TimerCapsule } from "./CameraControls";
import { CameraZoomDial, vibrate } from "./CameraZoomDial";
import { clampZoom, crossedStop, formatZoom, snapZoom, zoomPills } from "./zoom-model";
import "./camera.css";

/* Port of CameraCaptureView (CameraView.swift). The full camera frame sits behind compact top and
   bottom overlays, with a single row of event targets in both orientations. */

const GRID_KEY = "camera.showsGrid", QUALITY_KEY = "camera.captureQuality";
const readSetting = <T,>(key: string, fallback: T): T => { try { const raw = localStorage.getItem(key); return raw == null ? fallback : (JSON.parse(raw) as T); } catch { return fallback; } };
const writeSetting = (key: string, value: unknown) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ } };

export default function CameraScreen() {
  const { projectID = "" } = useParams();
  const navigate = useNavigate();
  const [recorder] = useState(() => new CameraRecorder());
  const s = useSyncExternalStore(recorder.subscribe, recorder.getSnapshot, recorder.getSnapshot);
  const [rootRef, layout] = useLayoutMetrics<HTMLDivElement>();
  const videoRef = useRef<HTMLVideoElement>(null);
  const [projectName, setProjectName] = useState("");
  const [captureMode, setCaptureMode] = useState<CaptureMode>("full");
  const [showsGrid, setShowsGrid] = useState(() => readSetting(GRID_KEY, false));
  const [preferredQuality] = useState<CaptureQuality>(() => { const q = readSetting<string>(QUALITY_KEY, "1080p"); return (CAPTURE_QUALITIES as readonly string[]).includes(q) ? (q as CaptureQuality) : "1080p"; });
  const [eventCapture, setEventCapture] = useState<EventCaptureState>(emptyEventCapture);
  const events = useRef(new Map<string, MatchEvent>());
  const [taggedEvents, setTaggedEvents] = useState<EventKind[]>([]);
  const [tagFeedback, setTagFeedback] = useState<EventKind | null>(null);
  const tagFeedbackToken = useRef(0);
  const [showingStopConfirmation, setShowingStopConfirmation] = useState(false);
  const [videoSize, setVideoSize] = useState<{ width: number; height: number } | null>(null);
  const [zoomHUD, setZoomHUD] = useState<number | null>(null);
  const [reticle, setReticle] = useState<{ x: number; y: number } | null>(null);

  const isRolling = isRollingMode(captureMode);
  const isBusy = s.isRecording || s.isFinishing;

  // MARK: Session lifecycle

  useEffect(() => { void repository.projects.get(projectID).then((p) => setProjectName(p?.name ?? "")); }, [projectID]);
  useEffect(() => { void recorder.prepare(preferredQuality); }, [recorder, preferredQuality]);
  useEffect(() => { if (s.status === "ready") writeSetting(QUALITY_KEY, s.quality); }, [s.quality, s.status]);
  useEffect(() => { writeSetting(GRID_KEY, showsGrid); }, [showsGrid]);
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const stream = s.status === "ready" ? recorder.mediaStream : null;
    if (video.srcObject !== stream) { video.srcObject = stream; if (stream) video.play().catch(() => undefined); }
  }, [s.status, recorder]);
  useEffect(() => () => { if (recorder.activeSegmentID) recorder.stop("user"); else recorder.shutdown(); }, [recorder]);

  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === "hidden") { if (recorder.activeSegmentID) recorder.stop("background"); }
      else if (recorder.getSnapshot().status === "idle") void recorder.prepare(recorder.getSnapshot().quality);
    };
    const onBeforeUnload = (event: BeforeUnloadEvent) => { if (recorder.activeSegmentID) { event.preventDefault(); event.returnValue = ""; } };
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => { document.removeEventListener("visibilitychange", onVisibility); window.removeEventListener("beforeunload", onBeforeUnload); };
  }, [recorder]);

  const close = useCallback(() => { if (!isBusy) navigate(routes.project(projectID)); }, [isBusy, navigate, projectID]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape" && !showingStopConfirmation && !s.showsInterruption) close(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close, showingStopConfirmation, s.showsInterruption]);

  // MARK: Event bookkeeping on the movie clock

  useEffect(() => {
    if (s.activeSegmentID && eventCapture.active.length) setEventCapture((state) => advance(state, s.activeSegmentID!, s.currentOffset));
  }, [s.currentOffset, s.activeSegmentID, eventCapture.active.length]);

  const persistShortened = useCallback((shortened: ShortenedEvent[]) => {
    for (const change of shortened) {
      const event = events.current.get(change.id);
      if (!event) continue;
      const updated = { ...event, postRollSeconds: change.postRollSeconds };
      events.current.set(event.id, updated);
      repository.events.save(updated).catch(() => recorder.setStatusMessage("The shortened event is pending and will be saved with the recording."));
    }
  }, [recorder]);

  useEffect(() => {
    recorder.onSegmentClosed = (id, duration) => setEventCapture((state) => { const result = finishSegment(state, id, duration); persistShortened(result.shortened); return result.state; });
    recorder.onSaved = (saved: Recording[]) => {
      const message = saved.length === 1 && saved[0] ? `Saved ${compactDuration(saved[0].duration)} locally` : `Saved ${saved.length} video segments locally`;
      recorder.setStatusMessage(message);
      vibrate([10, 40, 10]);
      setTimeout(() => { if (recorder.getSnapshot().statusMessage === message) recorder.setStatusMessage(null); }, 3000);
    };
    return () => { recorder.onSegmentClosed = null; recorder.onSaved = null; };
  }, [recorder, persistShortened]);

  // MARK: Actions

  const startSegment = useCallback(() => { setTaggedEvents([]); void recorder.start(projectID, captureMode); }, [recorder, projectID, captureMode]);
  const recordButtonPressed = () => { if (s.isRecording) setShowingStopConfirmation(true); else startSegment(); };

  const markEvent = (kind: EventKind) => {
    const recordingID = recorder.activeSegmentID;
    if (!recordingID || !recorder.canMarkEvent) return;
    const offset = Math.max(0, recorder.currentOffset);
    const seconds = bufferSeconds(captureMode);
    const event: MatchEvent = {
      id: newId(), projectID, kind, note: "", occurredAt: new Date().toISOString(), recordingID, offsetSeconds: offset,
      preRollSeconds: seconds ? Math.min(defaultPreRoll(kind), seconds) : defaultPreRoll(kind), postRollSeconds: defaultPostRoll(kind),
      colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId(),
    };
    const next = addEvent(eventCapture, { id: event.id, recordingID, kind, offsetSeconds: offset, postRollSeconds: event.postRollSeconds });
    if (isRolling) event.contextRecordingIDs = recorder.promoteRollingBuffer(endOffset(next, recordingID) ?? offset + event.postRollSeconds);
    events.current.set(event.id, event);
    setEventCapture(next);
    setTaggedEvents((list) => [...list, kind]);
    vibrate(20);
    const token = ++tagFeedbackToken.current;
    setTagFeedback(kind);
    setTimeout(() => { if (tagFeedbackToken.current === token) setTagFeedback(null); }, 900);
    // Let the acknowledgement render before durable I/O; retry once like the iOS client.
    setTimeout(() => {
      repository.events.save(event).catch(() => new Promise((r) => setTimeout(r, 250)).then(() => repository.events.save(event)))
        .catch(() => recorder.setStatusMessage("The event is pending and will be saved with the next change."));
    }, 0);
  };

  const endEventNow = (id: string) => {
    const recordingID = recorder.activeSegmentID;
    if (!recordingID || !recorder.canMarkEvent) return;
    const result = endNow(eventCapture, id, recordingID, recorder.currentOffset);
    if (!result) return;
    setEventCapture(result.state);
    if (result.shortened) persistShortened([result.shortened]);
    if (isRolling) recorder.endRollingEventCapture(endOffset(result.state, recordingID));
    vibrate(20);
  };

  const continueAfterInterruption = async () => {
    recorder.dismissInterruption();
    if (recorder.getSnapshot().status !== "ready") await recorder.prepare(recorder.getSnapshot().quality);
    if (recorder.getSnapshot().status === "ready") startSegment();
  };

  const zoomTo = useCallback((value: number, smooth: boolean) => {
    recorder.setZoom(value, smooth);
    if (!s.zoomIsHardware && value > 1.001 && !sessionStorage.getItem("camera.zoomNoteShown")) {
      sessionStorage.setItem("camera.zoomNoteShown", "1");
      recorder.setStatusMessage("Zoom is preview-only in this browser; the saved video stays unzoomed.");
    }
  }, [recorder, s.zoomIsHardware]);

  // MARK: Preview gestures: pinch to zoom, double tap to 1×, tap to focus

  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<{ startDistance: number; startZoom: number; lastStop: number | null } | null>(null);
  const tapCandidate = useRef<{ x: number; y: number; at: number } | null>(null);
  const hudTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const showHUD = (value: number, hold = false) => {
    setZoomHUD(value);
    if (hudTimer.current) clearTimeout(hudTimer.current);
    if (!hold) hudTimer.current = setTimeout(() => setZoomHUD(null), 700);
  };
  const distance = () => { const [a, b] = [...pointers.current.values()]; return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0; };
  const onPreviewPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (s.status !== "ready") return;
    pointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (pointers.current.size === 2) { pinch.current = { startDistance: distance(), startZoom: s.zoom, lastStop: null }; tapCandidate.current = null; showHUD(s.zoom, true); }
    else if (pointers.current.size === 1) tapCandidate.current = { x: event.clientX, y: event.clientY, at: performance.now() };
  };
  const onPreviewPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(event.pointerId)) return;
    pointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
    const p = pinch.current;
    if (p && pointers.current.size === 2 && p.startDistance > 0) {
      const previous = s.zoom;
      const target = clampZoom(s.zoomScale, p.startZoom * (distance() / p.startDistance));
      const stop = crossedStop(previous, target, zoomPills(s.zoomScale));
      if (stop != null && stop !== p.lastStop) { vibrate(6); p.lastStop = stop; }
      zoomTo(target, false);
      showHUD(target, true);
    } else if (tapCandidate.current && Math.hypot(event.clientX - tapCandidate.current.x, event.clientY - tapCandidate.current.y) > 12) tapCandidate.current = null;
  };
  const onPreviewPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    pointers.current.delete(event.pointerId);
    if (pinch.current && pointers.current.size < 2) {
      const snapped = snapZoom(s.zoom, zoomPills(s.zoomScale));
      zoomTo(snapped, false);
      showHUD(snapped);
      pinch.current = null;
      return;
    }
    const tap = tapCandidate.current;
    tapCandidate.current = null;
    if (!tap || performance.now() - tap.at > 400 || event.pointerType === "mouse" && event.button !== 0) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const point = { x: (tap.x - rect.left) / rect.width, y: (tap.y - rect.top) / rect.height };
    if (recorder.focus(point)) { setReticle(point); setTimeout(() => setReticle(null), 1800); }
  };
  const onPreviewDoubleClick = () => { if (s.status === "ready") { vibrate(8); zoomTo(1, true); showHUD(1); } };
  const onPreviewWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    if (s.status !== "ready" || s.isFinishing) return;
    const target = clampZoom(s.zoomScale, s.zoom * Math.pow(2, -event.deltaY / 400));
    zoomTo(target, false);
    showHUD(target);
  };

  // MARK: Derived layout

  const tagCounts = useMemo(() => taggedEvents.reduce<Partial<Record<EventKind, number>>>((acc, kind) => { acc[kind] = (acc[kind] ?? 0) + 1; return acc; }, {}), [taggedEvents]);
  const fitted = useMemo(() => {
    if (!videoSize || !layout.width || !layout.height) return null;
    const scale = Math.min(layout.width / videoSize.width, layout.height / videoSize.height);
    const w = videoSize.width * scale, h = videoSize.height * scale;
    return { left: (layout.width - w) / 2, top: (layout.height - h) / 2, width: w, height: h };
  }, [videoSize, layout.width, layout.height]);
  const canRecord = (s.status === "ready" || s.isRecording) && !s.isConfiguring && !s.isFinishing;
  const menusDisabled = s.status !== "ready" || s.isRecording || s.isConfiguring || s.isFinishing;

  const qualityItems = [
    ...s.availableQualities.map((q) => ({ id: q, title: qualityTitle(q), checked: s.quality === q, onSelect: () => { void recorder.setQuality(q); } })),
    ...(s.availableQualities.includes("4k") ? [] : [{ id: "no-4k", title: "4K is not available on this camera", note: true }]),
  ];
  const optionItems = [
    ...CAPTURE_MODES.map((mode) => ({ id: mode, title: captureModeTitle(mode), checked: captureMode === mode, disabled: menusDisabled, onSelect: () => setCaptureMode(mode) })),
    { id: "grid", title: "Framing grid", checked: showsGrid, onSelect: () => setShowsGrid((g) => !g) },
    ...(s.hasTorch ? [{ id: "torch", title: "Camera light", checked: s.isTorchOn, disabled: s.status !== "ready" || s.isFinishing, onSelect: () => recorder.toggleTorch() }] : []),
  ];

  return (
    <div data-surface="dark" className="cam" ref={rootRef}>
      <div className="cam-viewfinder" data-testid="camera-viewfinder" onPointerDown={onPreviewPointerDown} onPointerMove={onPreviewPointerMove} onPointerUp={onPreviewPointerUp} onPointerCancel={onPreviewPointerUp} onDoubleClick={onPreviewDoubleClick} onWheel={onPreviewWheel}>
        <video ref={videoRef} className="cam-video" autoPlay playsInline muted style={{ transform: s.zoomIsHardware ? undefined : `scale(${s.zoom})` }}
          onLoadedMetadata={(e) => setVideoSize({ width: e.currentTarget.videoWidth, height: e.currentTarget.videoHeight })} onResize={(e) => setVideoSize({ width: e.currentTarget.videoWidth, height: e.currentTarget.videoHeight })} />
        {showsGrid && fitted && <div className="cam-grid" aria-hidden="true" style={fitted} />}
        {reticle && <span className="cam-reticle" aria-hidden="true" style={{ left: `${reticle.x * 100}%`, top: `${reticle.y * 100}%` }} />}
      </div>

      {s.status !== "ready" && (
        <div className="cam-notready" role="status">
          {s.isConfiguring ? <Spinner size={24} /> : <Icon.Camera width={28} height={28} />}
          <p>{s.statusMessage ?? "Preparing camera…"}</p>
          {s.status === "denied" && <p className="cam-notready-hint">Allow the camera and microphone for this site in the browser's address bar or site settings, then try again.</p>}
          {!s.isConfiguring && <button type="button" className="cam-action cam-action-text" onClick={() => void recorder.prepare(preferredQuality)} data-testid="camera-open-settings">Try again</button>}
        </div>
      )}

      <div className="cam-chrome-layer">
        <header className="cam-header">
          <ChromeButton label="Close camera" disabled={isBusy} onClick={close}><Icon.ChevronDown /></ChromeButton>
          {s.isRecording ? <TimerCapsule elapsed={s.elapsed} isPaused={s.isPaused} /> : <span className="cam-project-name">{projectName}</span>}
          <span className="cam-spacer" />
          <CameraMenu label="Recording quality" value={`${qualityTitle(s.quality)}, ${s.framesPerSecond} fps`} disabled={menusDisabled} items={qualityItems}>
            {s.isConfiguring && s.status === "ready" && <Spinner size={12} />}
            <span className="tabular">{qualityShortTitle(s.quality)} · {s.framesPerSecond}</span><Icon.ChevronDown width={10} height={10} />
          </CameraMenu>
          {layout.isLandscape && (
            <>
              <ChromeButton label="Framing grid" value={showsGrid ? "On" : "Off"} toggle isActive={showsGrid} onClick={() => setShowsGrid((g) => !g)}><GridIcon /></ChromeButton>
              {s.hasTorch && <ChromeButton label="Camera light" value={s.isTorchOn ? "On" : "Off"} toggle isActive={s.isTorchOn} disabled={s.status !== "ready" || s.isFinishing} onClick={() => recorder.toggleTorch()}><BoltIcon off={!s.isTorchOn} /></ChromeButton>}
            </>
          )}
          <CameraMenu label="Camera options" value={captureModeShortTitle(captureMode)} items={optionItems}><SlidersIcon /></CameraMenu>
        </header>

        <div className="cam-overlays" data-landscape={layout.isLandscape || undefined}>
          {zoomHUD != null && <span className="cam-zoom-hud tabular" role="status">{formatZoom(zoomHUD, 1)}×</span>}
          <EventCountdown capture={eventCapture} canEnd={recorder.canMarkEvent} isPaused={s.isPaused} select={(id) => setEventCapture((state) => selectEvent(state, id))} end={endEventNow} />
          {s.status === "ready" && s.statusMessage && (
            <div className="cam-message" role="status">
              <span>{s.statusMessage}</span>
              <button type="button" className="cam-message-close" aria-label="Dismiss camera message" onClick={() => recorder.setStatusMessage(null)}><Icon.Close width={14} height={14} /></button>
            </div>
          )}
          <span className="cam-spacer" />
          {s.status === "ready" && <CameraZoomDial value={s.zoom} scale={s.zoomScale} disabled={s.isFinishing} change={zoomTo} />}
        </div>

        <CaptureDock isRecording={s.isRecording} isFinishing={s.isFinishing} canRecord={canRecord} mode={captureMode} tagCounts={tagCounts} lastTag={tagFeedback}
          savedCount={s.savedCount} lastSavedDuration={s.lastSavedDuration} bufferProgress={isRolling ? s.bufferProgress : 0} isLandscape={layout.isLandscape}
          isPaused={s.isPaused} supportsPause={s.supportsPause} record={recordButtonPressed} mark={markEvent} pause={() => recorder.togglePause()} />
      </div>

      {showingStopConfirmation && (
        <CameraDialog title="Stop recording?"
          message={isRolling && taggedEvents.length === 0 ? "No event was marked. The unused buffer will be discarded." : "Finish and save this recording?"}
          actions={[
            { title: isRolling && taggedEvents.length === 0 ? "Stop buffering" : "Stop and save", role: "destructive", onSelect: () => { setShowingStopConfirmation(false); recorder.stop("user"); } },
            { title: s.isPaused ? "Stay paused" : "Keep recording", role: "cancel", onSelect: () => setShowingStopConfirmation(false) },
          ]} />
      )}
      {s.showsInterruption && (
        <CameraDialog title="Recording interrupted" message="The completed part was saved safely. You can continue in a new segment and join them later."
          actions={[
            { title: "Continue with a new segment", onSelect: () => { void continueAfterInterruption(); } },
            { title: "Finish", role: "cancel", onSelect: () => recorder.dismissInterruption() },
          ]} />
      )}
    </div>
  );
}

const GridIcon = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="3" y="3" width="18" height="18" rx="2" /><path d="M9 3v18M15 3v18M3 9h18M3 15h18" /></svg>;
const BoltIcon = ({ off }: { off: boolean }) => <svg width="18" height="18" viewBox="0 0 24 24" fill={off ? "none" : "currentColor"} stroke="currentColor" strokeWidth="2" strokeLinejoin="round"><path d="M13 2L5 14h6l-1 8 9-13h-6z" />{off && <path d="M4 4l16 16" strokeLinecap="round" />}</svg>;
const SlidersIcon = () => <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M4 7h10M18 7h2M4 12h3M11 12h9M4 17h12M20 17h0" /><circle cx="16" cy="7" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="18" cy="17" r="2" /></svg>;
