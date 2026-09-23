import type { Recording, RecordingEndedReason } from "@/domain";
import { newId } from "@/domain";
import type { CaptureJournal } from "@/media/recovery-journal";
import { writeJournal } from "@/media/recovery-journal";
import { availableQualities, bufferSeconds, qualityForSize, qualityShortTitle, qualitySize, qualityTitle, STORAGE_FLOOR_BYTES, type CaptureMode, type CaptureQuality } from "./capture-mode";
import { beginJournal, currentTimezone, discardSegment, extensionFor, hasRecordingCapacity, persistSegment, preferredRecorderMimeType, SegmentSink, type CompletedSegment } from "./capture-library";
import { beginSegment, createRollingBuffer, endEventCapture, isDue, promote, rotate, type RollingBuffer, type RotationReason } from "./rolling-buffer";
import { clampZoom, type ZoomScale } from "./zoom-model";

/** A camera that never answers (some headless/kiosk browsers, or a device held by another app) must not leave the
 *  screen on "Preparing camera…" forever. Permission prompts in normal browsers resolve well within this window. */
const OPEN_STREAM_TIMEOUT_MS = 30_000;
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new DOMException("Camera did not respond", "TimeoutError")), ms);
    promise.then((value) => { clearTimeout(timer); resolve(value); }, (error: unknown) => { clearTimeout(timer); reject(error); });
  });
}

/* Web port of `CameraRecorder` (CameraView.swift): getUserMedia + MediaRecorder instead of an
   AVCaptureSession. One MediaRecorder per file so every segment is independently playable; chunks
   stream into the Recovery folder next to a journal and move into Recordings when the file closes. */

export type RecorderStatus = "idle" | "configuring" | "ready" | "denied" | "failed";

export interface RecorderSnapshot {
  status: RecorderStatus;
  /** True while the stream is being opened or a preset is being applied. */
  isConfiguring: boolean;
  statusMessage: string | null;
  isRecording: boolean;
  isPaused: boolean;
  isFinishing: boolean;
  supportsPause: boolean;
  /** Seconds on the movie clock: the active file, or all buffered time in replay mode. */
  elapsed: number;
  /** Seconds into the active file. */
  currentOffset: number;
  /** 0…1 fill of the active replay segment. */
  bufferProgress: number;
  activeSegmentID: string | null;
  quality: CaptureQuality;
  availableQualities: CaptureQuality[];
  appliedSize: { width: number; height: number } | null;
  framesPerSecond: number;
  mimeType: string;
  hasAudio: boolean;
  zoom: number;
  zoomScale: ZoomScale;
  /** False when the browser cannot zoom the track and the preview is scaled instead. */
  zoomIsHardware: boolean;
  hasTorch: boolean;
  isTorchOn: boolean;
  showsInterruption: boolean;
  /** How many files this session saved and the length of the last one. */
  savedCount: number;
  lastSavedDuration: number | null;
}

const initialSnapshot: RecorderSnapshot = {
  status: "idle", isConfiguring: false, statusMessage: null, isRecording: false, isPaused: false, isFinishing: false,
  supportsPause: typeof MediaRecorder !== "undefined" && typeof MediaRecorder.prototype.pause === "function",
  elapsed: 0, currentOffset: 0, bufferProgress: 0, activeSegmentID: null,
  quality: "1080p", availableQualities: [], appliedSize: null, framesPerSecond: 30, mimeType: "", hasAudio: false,
  zoom: 1, zoomScale: { minimum: 1, maximum: 4, lensFactors: [] }, zoomIsHardware: false,
  hasTorch: false, isTorchOn: false, showsInterruption: false, savedCount: 0, lastSavedDuration: null,
};

/** Wall time minus pauses, in seconds. Stands in for `AVCaptureFileOutput.recordedDuration`. */
class MovieClock {
  private accumulated = 0;
  private runningSince: number | null = null;
  start() { this.runningSince = performance.now(); }
  pause() { if (this.runningSince != null) { this.accumulated += performance.now() - this.runningSince; this.runningSince = null; } }
  resume() { if (this.runningSince == null) this.runningSince = performance.now(); }
  get offset() { return (this.accumulated + (this.runningSince != null ? performance.now() - this.runningSince : 0)) / 1000; }
}

interface Segment {
  id: string;
  mediaKey: string;
  journal: CaptureJournal;
  recorder: MediaRecorder;
  sink: SegmentSink;
  clock: MovieClock;
  startedAt: string;
  reason: RotationReason;
  /** Whether closing this file ends the session. */
  terminal: boolean;
  /** Set while the file is closing: what the rolling buffer decided about it. */
  save: string[];
  discard: string[];
  completed: CompletedSegment | null;
  finalized: Promise<void>;
  resolveFinalized: () => void;
}

type ExtendedCapabilities = MediaTrackCapabilities & { zoom?: { min: number; max: number; step?: number }; torch?: boolean };
type ExtendedSettings = MediaTrackSettings & { zoom?: number; torch?: boolean };

const reasonForLibrary = (reason: RotationReason): RecordingEndedReason => (reason === "low-storage" ? "interruption" : reason === "buffer-rotation" ? "rolling" : reason);

export class CameraRecorder {
  private snapshot: RecorderSnapshot = initialSnapshot;
  private listeners = new Set<() => void>();
  private stream: MediaStream | null = null;
  private prepareGeneration = 0;
  private projectID = "";
  private mode: CaptureMode = "full";
  private rolling: RollingBuffer | null = null;
  private accumulated = 0;
  private active: Segment | null = null;
  private segments = new Map<string, Segment>();
  private starting = false;
  private stopRequested: RotationReason | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private storageTick = 0;
  private zoomTimer: ReturnType<typeof setTimeout> | null = null;
  private pendingZoom: number | null = null;
  private lastZoomAt = 0;
  private rampFrame: number | null = null;
  private wakeLock: WakeLockSentinel | null = null;
  /** Called when a file closes, before it is saved, so open event windows can be shortened. */
  onSegmentClosed: ((recordingID: string, duration: number) => void) | null = null;
  onSaved: ((recordings: Recording[]) => void) | null = null;

  // MARK: Store contract

  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  getSnapshot = () => this.snapshot;
  private patch(changes: Partial<RecorderSnapshot>) {
    this.snapshot = { ...this.snapshot, ...changes };
    for (const listener of this.listeners) listener();
  }
  setStatusMessage(message: string | null) { if (this.snapshot.statusMessage !== message) this.patch({ statusMessage: message }); }
  dismissInterruption() { this.patch({ showsInterruption: false }); }

  get mediaStream() { return this.stream; }
  get activeSegmentID() { return this.active?.id ?? null; }
  get currentOffset() { return this.active?.clock.offset ?? 0; }
  get canMarkEvent() { const s = this.snapshot; return !!this.active && s.isRecording && !s.isFinishing && !s.isPaused && this.active.recorder.state === "recording"; }
  /** Segment IDs holding the pre-roll context for a new event (replay mode). */
  get contextRecordingIDs(): string[] { return this.rolling?.previous ? [this.rolling.previous] : []; }

  private get videoTrack() { return this.stream?.getVideoTracks()[0] ?? null; }
  private capabilities(): ExtendedCapabilities { const track = this.videoTrack; return (track && typeof track.getCapabilities === "function" ? track.getCapabilities() : {}) as ExtendedCapabilities; }

  // MARK: Session

  async prepare(quality: CaptureQuality): Promise<void> {
    if (this.snapshot.status === "ready" || this.snapshot.isConfiguring) return;
    if (typeof navigator === "undefined" || !navigator.mediaDevices?.getUserMedia) { this.patch({ status: "failed", statusMessage: "This browser cannot access the camera." }); return; }
    const generation = ++this.prepareGeneration;
    this.patch({ status: "configuring", isConfiguring: true, statusMessage: null });
    try {
      // A suspended camera reuses its stream (returning from the background) instead of prompting again.
      if (!this.videoTrack || this.videoTrack.readyState !== "live") {
        this.releaseStream();
        this.stream = await this.openStream(quality);
      }
      if (generation !== this.prepareGeneration) { this.stream?.getTracks().forEach((t) => t.stop()); return; }
      const track = this.videoTrack!;
      track.onended = () => this.handleTrackEnded();
      this.stream?.getAudioTracks().forEach((t) => { t.onended = () => this.handleTrackEnded(); });
      const applied = this.readTrackState(quality);
      const caps = this.capabilities();
      const zoomIsHardware = !!caps.zoom && Number.isFinite(caps.zoom.min) && Number.isFinite(caps.zoom.max) && caps.zoom.max > caps.zoom.min;
      const zoomScale: ZoomScale = zoomIsHardware
        ? { minimum: Math.max(0.5, caps.zoom!.min), maximum: Math.min(caps.zoom!.max, 6), lensFactors: [] }
        : { minimum: 1, maximum: 4, lensFactors: [] };
      const zoom = clampZoom(zoomScale, zoomIsHardware ? ((track.getSettings() as ExtendedSettings).zoom ?? 1) : this.snapshot.zoom);
      const hasAudio = (this.stream?.getAudioTracks().length ?? 0) > 0;
      this.patch({
        status: "ready", isConfiguring: false, mimeType: preferredRecorderMimeType(), hasAudio,
        zoomIsHardware, zoomScale, zoom, hasTorch: caps.torch === true, isTorchOn: false,
        statusMessage: applied.quality !== quality ? `${qualityShortTitle(quality)} is unavailable. Using ${qualityTitle(applied.quality)}.` : hasAudio ? null : "Recording without audio: no microphone is available.",
      });
      if (!zoomIsHardware && zoom !== 1) this.applyZoom(zoom);
    } catch (error) {
      if (generation !== this.prepareGeneration) return;
      const name = error instanceof DOMException ? error.name : "";
      if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError") {
        this.patch({ status: "denied", isConfiguring: false, statusMessage: "Allow camera and microphone access to record videos." });
      } else {
        const message = name === "TimeoutError"
          ? "The camera did not respond. Close other apps using it, then try again."
          : `Could not start the camera: ${error instanceof Error ? error.message : String(error)}`;
        this.patch({ status: "failed", isConfiguring: false, statusMessage: message });
      }
    }
  }

  private async openStream(quality: CaptureQuality): Promise<MediaStream> {
    const size = qualitySize(quality);
    const video: MediaTrackConstraints = { facingMode: { ideal: "environment" }, width: { ideal: size.width }, height: { ideal: size.height }, frameRate: { ideal: 30 } };
    try {
      return await withTimeout(navigator.mediaDevices.getUserMedia({ video, audio: true }), OPEN_STREAM_TIMEOUT_MS);
    } catch (error) {
      const name = error instanceof DOMException ? error.name : "";
      if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError" || name === "TimeoutError") throw error;
      // No microphone (or it is busy): record video only rather than nothing.
      return withTimeout(navigator.mediaDevices.getUserMedia({ video, audio: false }), OPEN_STREAM_TIMEOUT_MS);
    }
  }

  private readTrackState(requested: CaptureQuality): { quality: CaptureQuality } {
    const track = this.videoTrack;
    const settings = track?.getSettings() ?? {};
    const caps = this.capabilities();
    const width = settings.width ?? 0, height = settings.height ?? 0;
    const quality = width && height ? qualityForSize(width, height) : requested;
    const available = availableQualities(caps.width?.max, caps.height?.max);
    if (!available.includes(quality)) available.push(quality);
    this.patch({ quality, availableQualities: available.sort((a, b) => qualitySize(a).width - qualitySize(b).width), appliedSize: width && height ? { width, height } : null, framesPerSecond: Math.round(settings.frameRate ?? 30) });
    return { quality };
  }

  async setQuality(quality: CaptureQuality): Promise<void> {
    const track = this.videoTrack;
    const s = this.snapshot;
    if (!track || s.status !== "ready" || s.isRecording || s.isConfiguring || s.quality === quality) return;
    this.patch({ isConfiguring: true });
    const size = qualitySize(quality);
    try {
      await track.applyConstraints({ width: { ideal: size.width }, height: { ideal: size.height }, frameRate: { ideal: 30 } });
      const applied = this.readTrackState(quality);
      this.patch({ isConfiguring: false, statusMessage: applied.quality === quality ? null : `This camera does not support ${qualityTitle(quality)}.` });
    } catch {
      this.patch({ isConfiguring: false, statusMessage: `This camera does not support ${qualityTitle(quality)}.` });
    }
  }

  /** Stops the stream. No-op while a file is open. */
  shutdown() {
    if (this.active || this.starting || this.snapshot.isFinishing) return;
    this.prepareGeneration += 1;
    this.stopTimer();
    if (this.rampFrame != null) cancelAnimationFrame(this.rampFrame);
    this.releaseStream();
    this.patch({ status: "idle", isConfiguring: false, isTorchOn: false });
  }

  private releaseStream() {
    this.stream?.getTracks().forEach((t) => { t.onended = null; t.stop(); });
    this.stream = null;
  }

  private handleTrackEnded() {
    if (this.active || this.starting) { this.stop("interruption"); return; }
    this.releaseStream();
    this.patch({ status: "idle", statusMessage: "The camera was disconnected." });
  }

  // MARK: Recording

  async start(projectID: string, mode: CaptureMode): Promise<void> {
    const s = this.snapshot;
    if (s.status !== "ready" || s.isConfiguring || s.isFinishing || this.active || this.starting || !this.stream) return;
    if (!(await hasRecordingCapacity(STORAGE_FLOOR_BYTES))) { this.setStatusMessage("Not enough storage to record safely. Free at least 500 MB and try again."); return; }
    this.projectID = projectID; this.mode = mode; this.accumulated = 0; this.storageTick = 0; this.stopRequested = null;
    const seconds = bufferSeconds(mode);
    this.rolling = seconds ? createRollingBuffer(seconds) : null;
    this.patch({ elapsed: 0, currentOffset: 0, bufferProgress: 0, isPaused: false, showsInterruption: false });
    await this.startFile(newId());
    void this.requestWakeLock();
  }

  private async startFile(id: string): Promise<void> {
    if (!this.stream) return;
    this.starting = true;
    const startedAt = new Date().toISOString(), timezone = currentTimezone();
    const mimeType = this.snapshot.mimeType;
    const mediaKey = `${id}.${extensionFor(mimeType)}`;
    const journal: CaptureJournal = { recordingID: id, projectID: this.projectID, startedAt, timezone, mode: this.rolling ? "rolling" : "normal", mediaKey, promoted: false };
    let sink: SegmentSink;
    try {
      await beginJournal(journal);
      sink = await SegmentSink.open(mediaKey, mimeType);
    } catch (error) {
      this.abortStart(`Could not prepare crash recovery: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    let recorder: MediaRecorder;
    try { recorder = new MediaRecorder(this.stream, mimeType ? { mimeType } : undefined); }
    catch (error) { void discardSegment(id, mediaKey); this.abortStart(`Could not start recording: ${error instanceof Error ? error.message : String(error)}`); return; }
    let resolveFinalized = () => {};
    const finalized = new Promise<void>((resolve) => { resolveFinalized = resolve; });
    const segment: Segment = { id, mediaKey, journal, recorder, sink, clock: new MovieClock(), startedAt, reason: this.rolling ? "buffer-rotation" : "user", terminal: !this.rolling, save: [], discard: [], completed: null, finalized, resolveFinalized };
    recorder.ondataavailable = (event) => sink.append(event.data);
    recorder.onstop = () => { void this.finalize(segment); };
    recorder.onerror = (event) => {
      this.setStatusMessage(`Recording error: ${(event as ErrorEvent).error?.message ?? "the browser stopped the recorder."}`);
      if (this.active === segment) this.stop("interruption");
    };
    if (this.rolling) this.rolling = beginSegment(this.rolling, id);
    this.segments.set(id, segment);
    this.active = segment;
    recorder.start(1000);
    segment.clock.start();
    this.starting = false;
    this.patch({ isRecording: true, isPaused: false, isFinishing: false, activeSegmentID: id, statusMessage: this.snapshot.statusMessage?.startsWith("Saved ") ? this.snapshot.statusMessage : null });
    this.ensureTimer();
    if (this.stopRequested) { const reason = this.stopRequested; this.stopRequested = null; this.stop(reason); }
  }

  /** A file could not be opened: end the session cleanly instead of leaving the chrome in a recording state. */
  private abortStart(message: string) {
    this.starting = false;
    this.stopRequested = null;
    this.rolling = null;
    this.stopTimer();
    void this.releaseWakeLock();
    this.patch({ statusMessage: message, isRecording: false, isFinishing: false, isPaused: false, activeSegmentID: null });
  }

  togglePause() {
    const segment = this.active;
    if (!segment || !this.snapshot.supportsPause || this.snapshot.isFinishing) return;
    if (segment.recorder.state === "recording") { segment.recorder.pause(); segment.clock.pause(); this.patch({ isPaused: true }); }
    else if (segment.recorder.state === "paused") { segment.recorder.resume(); segment.clock.resume(); this.patch({ isPaused: false }); }
  }

  /** Ends the session: the active file closes as a durable segment. */
  stop(reason: RotationReason) {
    if (this.starting && !this.active) { this.stopRequested = reason; return; }
    if (!this.active || this.snapshot.isFinishing) return;
    this.patch({ isFinishing: true });
    this.closeActive(reason);
  }

  /** Closes the active file. In replay mode the buffer decides whether a new file starts right away. */
  private closeActive(reason: RotationReason) {
    const segment = this.active;
    if (!segment) return;
    segment.reason = reason;
    if (this.rolling) {
      const rotation = rotate(this.rolling, reason);
      this.rolling = rotation.buffer;
      segment.save = rotation.save; segment.discard = rotation.discard; segment.terminal = !rotation.continues;
    } else {
      segment.save = [segment.id]; segment.terminal = true;
    }
    this.active = null;
    segment.clock.pause();
    if (segment.recorder.state === "inactive") void this.finalize(segment);
    else segment.recorder.stop();
    if (!segment.terminal) void this.startFile(newId());
    else this.patch({ isFinishing: true, activeSegmentID: null });
  }

  private async finalize(segment: Segment) {
    if (segment.completed) return;
    const duration = Math.max(0, segment.clock.offset) || Math.max(0, (Date.now() - new Date(segment.startedAt).getTime()) / 1000);
    try { await segment.sink.close(); } catch (error) { this.setStatusMessage(error instanceof Error ? error.message : String(error)); }
    const size = this.snapshot.appliedSize;
    segment.completed = { id: segment.id, projectID: this.projectID, mediaKey: segment.mediaKey, ext: extensionFor(this.snapshot.mimeType), mimeType: this.snapshot.mimeType, duration, reason: reasonForLibrary(segment.reason), startedAt: segment.startedAt, timezone: segment.journal.timezone, width: size?.width ?? null, height: size?.height ?? null };
    segment.resolveFinalized();
    if (this.rolling || segment.reason === "buffer-rotation") this.accumulated += duration;
    this.onSegmentClosed?.(segment.id, duration);
    if (segment.terminal) {
      this.stopTimer();
      void this.releaseWakeLock();
      const streamAlive = this.videoTrack?.readyState === "live";
      this.patch({ isRecording: false, isFinishing: false, isPaused: false, activeSegmentID: null, currentOffset: 0, bufferProgress: 0, status: streamAlive ? this.snapshot.status : "idle", showsInterruption: segment.reason === "interruption" || segment.reason === "background" });
      if (!streamAlive) this.releaseStream();
      this.rolling = null;
    }
    for (const id of segment.discard) {
      const s = this.segments.get(id);
      this.segments.delete(id);
      void (s?.finalized ?? Promise.resolve()).then(() => discardSegment(id, s?.mediaKey ?? `${id}.${segment.completed!.ext}`));
    }
    const saved: Recording[] = [];
    for (const id of segment.save) {
      const s = this.segments.get(id);
      if (!s) continue;
      await s.finalized;
      this.segments.delete(id);
      try { saved.push(await persistSegment(s.completed!)); }
      catch (error) { this.setStatusMessage(error instanceof Error ? error.message : String(error)); }
    }
    if (saved.length) {
      this.patch({ savedCount: this.snapshot.savedCount + saved.length, lastSavedDuration: saved.at(-1)!.duration });
      this.onSaved?.(saved);
    }
  }

  // MARK: Replay promotion

  /** Event tap in replay mode: keeps the buffered context and extends the active file to `endOffset`. */
  promoteRollingBuffer(endOffset: number): string[] {
    const segment = this.active;
    if (!this.rolling || !segment) return [];
    const wasPromoted = this.rolling.promoted;
    const result = promote(this.rolling, segment.clock.offset, endOffset);
    this.rolling = result.buffer;
    if (!wasPromoted) {
      for (const id of [segment.id, ...result.contextRecordingIDs]) {
        const s = this.segments.get(id);
        if (s && !s.journal.promoted) { s.journal = { ...s.journal, promoted: true }; void writeJournal(s.journal).catch(() => undefined); }
      }
    }
    return result.contextRecordingIDs;
  }

  /** "End now" in replay mode: shorten the promoted file, or close it and resume buffering. */
  endRollingEventCapture(endOffset: number | null) {
    if (!this.rolling || !this.active || !this.canMarkEvent) return;
    this.rolling = endEventCapture(this.rolling, this.active.clock.offset, endOffset);
    this.checkRotation();
  }

  private checkRotation() {
    const segment = this.active;
    if (!segment || !this.rolling || this.snapshot.isFinishing || this.snapshot.isPaused) return;
    if (isDue(this.rolling, segment.clock.offset)) this.closeActive("buffer-rotation");
  }

  // MARK: Clock

  private ensureTimer() {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), 100);
  }
  private stopTimer() { if (this.timer) { clearInterval(this.timer); this.timer = null; } }

  private tick() {
    const segment = this.active;
    if (!segment) return;
    const offset = segment.clock.offset;
    const seconds = bufferSeconds(this.mode);
    this.patch({ currentOffset: offset, elapsed: (this.rolling ? this.accumulated : 0) + offset, bufferProgress: seconds ? Math.min(1, offset / seconds) : 0 });
    this.checkRotation();
    this.storageTick += 1;
    if (this.storageTick % 100 === 0) {
      void hasRecordingCapacity(STORAGE_FLOOR_BYTES).then((ok) => { if (!ok && this.active) { this.setStatusMessage("Storage is almost full. Saving the recording now."); this.stop("low-storage"); } });
    }
  }

  // MARK: Zoom and torch

  /** Applies a factor in display units. `smooth` ramps at about 0.3 s per doubling like Camera.app. */
  setZoom(value: number, smooth = false) {
    const target = clampZoom(this.snapshot.zoomScale, value);
    if (this.rampFrame != null) { cancelAnimationFrame(this.rampFrame); this.rampFrame = null; }
    if (!smooth) { this.patch({ zoom: target }); this.scheduleZoom(target); return; }
    const from = this.snapshot.zoom, startedAt = performance.now();
    const duration = Math.max(80, Math.abs(Math.log2(target / Math.max(from, 0.01))) * 300);
    const step = () => {
      const t = Math.min(1, (performance.now() - startedAt) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      const zoom = from * Math.pow(target / from, eased);
      this.patch({ zoom });
      this.scheduleZoom(zoom);
      this.rampFrame = t < 1 ? requestAnimationFrame(step) : null;
    };
    this.rampFrame = requestAnimationFrame(step);
  }

  /** Throttles hardware zoom to the preview frame rate; the latest value wins. */
  private scheduleZoom(value: number) {
    this.pendingZoom = value;
    if (this.zoomTimer) return;
    const delay = Math.max(0, 1000 / 30 - (performance.now() - this.lastZoomAt));
    this.zoomTimer = setTimeout(() => {
      this.zoomTimer = null;
      const pending = this.pendingZoom;
      this.pendingZoom = null;
      this.lastZoomAt = performance.now();
      if (pending != null) this.applyZoom(pending);
    }, delay);
  }

  private applyZoom(value: number) {
    const track = this.videoTrack;
    if (!this.snapshot.zoomIsHardware || !track) return;
    track.applyConstraints({ advanced: [{ zoom: value } as MediaTrackConstraintSet] }).catch(() => this.setStatusMessage("Could not change zoom."));
  }

  toggleTorch() {
    const track = this.videoTrack;
    if (!track || !this.snapshot.hasTorch) { this.patch({ isTorchOn: false }); return; }
    const enabled = !this.snapshot.isTorchOn;
    this.patch({ isTorchOn: enabled });
    track.applyConstraints({ advanced: [{ torch: enabled } as MediaTrackConstraintSet] }).catch(() => this.patch({ isTorchOn: false, statusMessage: "Could not change the torch." }));
  }

  /** Continuous focus and exposure at a point of interest where the browser supports it (Chrome on Android). */
  focus(point: { x: number; y: number }) {
    const track = this.videoTrack;
    const caps = this.capabilities() as ExtendedCapabilities & { focusMode?: string[]; exposureMode?: string[]; pointsOfInterest?: unknown };
    if (!track || !caps.pointsOfInterest) return false;
    const advanced: Record<string, unknown> = { pointsOfInterest: [{ x: point.x, y: point.y }] };
    if (caps.focusMode?.includes("continuous")) advanced.focusMode = "continuous";
    if (caps.exposureMode?.includes("continuous")) advanced.exposureMode = "continuous";
    track.applyConstraints({ advanced: [advanced as MediaTrackConstraintSet] }).catch(() => undefined);
    return true;
  }

  private async requestWakeLock() {
    try { this.wakeLock = (await navigator.wakeLock?.request("screen")) ?? null; } catch { this.wakeLock = null; }
  }
  private async releaseWakeLock() {
    try { await this.wakeLock?.release(); } catch { /* released by the browser */ }
    this.wakeLock = null;
  }
}
