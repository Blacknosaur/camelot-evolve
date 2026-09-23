/* Sequence player: plays an ordered list of clips over several <video> elements, one per distinct
   recording, mapping output time ↔ (clip, source time) while honouring rate and held frames.
   Framework-free so the editor, the players and tests share it. Port of EditorPlayback +
   the composed AVPlayerItem in RecordingEditorView.swift / CompositionPlayerView.swift. */

import { clampRate, type CompositionClip, type UUID } from "@/domain";
import { outputTimeAt, segmentContaining, segmentEnd, segmentsForClips, sequenceDuration, sourceTimeAt, type SequenceSegment } from "@/features/editor/model/sequence";

export interface SequenceSource {
  recordingID: UUID;
  /** Object URL or remote URL for the recording's file. */
  url: string;
  duration: number;
  width?: number;
  height?: number;
}

export interface SequencePlayerState {
  outputTime: number;
  duration: number;
  isPlaying: boolean;
  /** Every source has metadata; seeking and playing are possible. */
  isReady: boolean;
  error: string | null;
  activeClipID: UUID | null;
  activeRecordingID: UUID | null;
  sourceTime: number;
}

export interface TimeSample { outputTime: number; sourceTime: number; clip: CompositionClip | null }

type Listener = (state: SequencePlayerState) => void;
type TimeListener = (sample: TimeSample) => void;

const PITCH_RANGE: [number, number] = [0.5, 2];
const END_EPSILON = 1 / 120;

export class SequencePlayer {
  readonly elements = new Map<UUID, HTMLVideoElement>();
  private sources = new Map<UUID, SequenceSource>();
  private clips: CompositionClip[] = [];
  private segments: SequenceSegment[] = [];
  private outputTime = 0;
  private playing = false;
  private rangeEnd: number | null = null;
  private frame = 0;
  private lastTick = 0;
  private muted = false;
  private pendingSeeks = new Map<UUID, number>();
  private seeking = new Set<UUID>();
  private listeners = new Set<Listener>();
  private timeListeners = new Set<TimeListener>();
  private lastEmit = 0;
  private error: string | null = null;
  private disposed = false;

  constructor(sources: readonly SequenceSource[] = [], clips: readonly CompositionClip[] = []) {
    this.setSources(sources);
    this.setClips(clips);
  }

  // MARK: Configuration

  setSources(sources: readonly SequenceSource[]) {
    const keep = new Set(sources.map((s) => s.recordingID));
    for (const [id, element] of this.elements) {
      if (keep.has(id) && this.sources.get(id)?.url === sources.find((s) => s.recordingID === id)?.url) continue;
      this.detach(element);
      this.elements.delete(id);
      this.sources.delete(id);
    }
    for (const source of sources) {
      this.sources.set(source.recordingID, source);
      if (this.elements.has(source.recordingID)) continue;
      const element = document.createElement("video");
      element.src = source.url;
      element.preload = "auto";
      element.playsInline = true;
      element.setAttribute("playsinline", "");
      element.disablePictureInPicture = true;
      element.muted = this.muted;
      element.addEventListener("loadedmetadata", this.handleMetadata);
      element.addEventListener("seeked", this.handleSeeked);
      element.addEventListener("error", this.handleError);
      element.addEventListener("ended", this.handleEnded);
      this.elements.set(source.recordingID, element);
    }
    this.error = null;
    this.emit(true);
  }

  setClips(clips: readonly CompositionClip[]) {
    this.clips = [...clips];
    this.segments = segmentsForClips(this.clips);
    this.rangeEnd = null;
    const duration = this.duration;
    if (this.outputTime > duration) this.outputTime = duration;
    this.applyPosition(false);
    this.emit(true);
  }

  get duration() { return sequenceDuration(this.segments); }
  get currentTime() { return this.outputTime; }
  get isPlaying() { return this.playing; }

  get state(): SequencePlayerState {
    const segment = this.currentSegment;
    return {
      outputTime: this.outputTime,
      duration: this.duration,
      isPlaying: this.playing,
      isReady: this.isReady,
      error: this.error,
      activeClipID: segment?.id ?? null,
      activeRecordingID: segment?.recordingID ?? null,
      sourceTime: segment ? sourceTimeAt(segment, this.outputTime) : 0,
    };
  }

  get isReady() {
    if (!this.segments.length) return false;
    for (const segment of this.segments) {
      const element = this.elements.get(segment.recordingID);
      if (!element || element.readyState < HTMLMediaElement.HAVE_METADATA) return false;
    }
    return true;
  }

  get activeElement(): HTMLVideoElement | null {
    const segment = this.currentSegment;
    return segment ? this.elements.get(segment.recordingID) ?? null : null;
  }

  get activeClip(): CompositionClip | null {
    const segment = this.currentSegment;
    return segment ? this.clips.find((c) => c.id === segment.id) ?? null : null;
  }

  private get currentSegment(): SequenceSegment | null { return segmentContaining(this.outputTime, this.segments); }

  /** Output position for a source time inside a clip (used when re-entering the sequence after a trim). */
  outputTimeFor(clipID: UUID, sourceSeconds: number): number | null {
    const segment = this.segments.find((s) => s.id === clipID);
    return segment ? outputTimeAt(segment, sourceSeconds) : null;
  }

  setMuted(muted: boolean) {
    this.muted = muted;
    this.applyAudio();
  }

  // MARK: Transport

  /** Coarse seek while scrubbing: tolerant, never flooding the decoder with more than one in-flight seek. */
  previewSeek(seconds: number) { this.seekTo(seconds, true); }

  /** Exact seek; pauses playback. */
  seek(seconds: number) { this.seekTo(seconds, false); }

  private seekTo(seconds: number, fast: boolean) {
    if (!Number.isFinite(seconds)) return;
    this.pause();
    this.rangeEnd = null;
    this.outputTime = Math.max(0, Math.min(this.duration, seconds));
    this.applyPosition(fast);
    this.emit(true);
  }

  play() { this.playRange(this.outputTime, null); }

  /** Plays from `start` and pauses at `end` (or the sequence end). */
  playRange(start: number, end: number | null) {
    if (!this.segments.length) return;
    const duration = this.duration;
    this.outputTime = Math.max(0, Math.min(duration, start));
    if (this.outputTime >= duration - END_EPSILON) this.outputTime = 0;
    this.rangeEnd = end == null ? null : Math.min(duration, end);
    this.playing = true;
    this.lastTick = performance.now();
    this.applyPosition(false);
    this.startActiveElement();
    this.schedule();
    this.emit(true);
  }

  pause() {
    if (!this.playing && !this.frame) return;
    this.playing = false;
    cancelAnimationFrame(this.frame);
    this.frame = 0;
    for (const element of this.elements.values()) if (!element.paused) element.pause();
    this.emit(true);
  }

  toggle() { if (this.playing) this.pause(); else this.play(); }

  /** Moves by whole source frames of the active clip (held frames step in output time). */
  step(frames: number, fps = 30) {
    const segment = this.currentSegment;
    if (!segment) return;
    const delta = segment.freezeDuration != null ? frames / fps : (frames / fps) / clampRate(segment.rate);
    this.seek(this.outputTime + delta);
  }

  // MARK: Observation

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => { this.listeners.delete(listener); };
  }

  /** Frame-accurate time callbacks (every animation frame while playing, every seek otherwise). */
  onTime(listener: TimeListener): () => void {
    this.timeListeners.add(listener);
    return () => { this.timeListeners.delete(listener); };
  }

  dispose() {
    this.disposed = true;
    this.pause();
    for (const element of this.elements.values()) this.detach(element);
    this.elements.clear();
    this.listeners.clear();
    this.timeListeners.clear();
  }

  // MARK: Internals

  private detach(element: HTMLVideoElement) {
    element.pause();
    element.removeEventListener("loadedmetadata", this.handleMetadata);
    element.removeEventListener("seeked", this.handleSeeked);
    element.removeEventListener("error", this.handleError);
    element.removeEventListener("ended", this.handleEnded);
    element.removeAttribute("src");
    element.load();
    element.remove();
  }

  private handleMetadata = () => { this.applyPosition(false); this.emit(true); };
  private handleError = (event: Event) => {
    const element = event.currentTarget as HTMLVideoElement;
    this.error = element.error?.message || "The video could not be decoded.";
    this.pause();
    this.emit(true);
  };
  private handleEnded = () => { if (this.playing) this.advance(); };
  private handleSeeked = (event: Event) => {
    const element = event.currentTarget as HTMLVideoElement;
    const id = [...this.elements].find(([, e]) => e === element)?.[0];
    if (!id) return;
    this.seeking.delete(id);
    const pending = this.pendingSeeks.get(id);
    if (pending != null) { this.pendingSeeks.delete(id); this.requestSeek(id, element, pending, true); }
    if (!this.playing) this.emitTime();
  };

  /** One in-flight seek per element; the newest request wins when it completes. */
  private requestSeek(id: UUID, element: HTMLVideoElement, seconds: number, fast: boolean) {
    if (element.readyState < HTMLMediaElement.HAVE_METADATA) { this.pendingSeeks.set(id, seconds); return; }
    const target = Math.max(0, Math.min(Number.isFinite(element.duration) ? Math.max(0, element.duration - END_EPSILON) : seconds, seconds));
    if (Math.abs(element.currentTime - target) < 0.001) return;
    if (this.seeking.has(id)) { this.pendingSeeks.set(id, target); return; }
    this.seeking.add(id);
    try {
      if (fast && typeof element.fastSeek === "function") element.fastSeek(target);
      else element.currentTime = target;
    } catch { this.seeking.delete(id); }
  }

  /** Points every element at the frame it shows for the current output time; the active one now,
   *  the next clip's element ahead of time so the cut has decoded frames waiting. */
  private applyPosition(fast: boolean) {
    const segment = this.currentSegment;
    if (!segment) return;
    const element = this.elements.get(segment.recordingID);
    if (element) {
      this.requestSeek(segment.recordingID, element, sourceTimeAt(segment, this.outputTime), fast);
      this.applyRate(element, segment);
    }
    const index = this.segments.indexOf(segment);
    const next = this.segments[index + 1];
    if (next && next.recordingID !== segment.recordingID) {
      const upcoming = this.elements.get(next.recordingID);
      if (upcoming && upcoming.paused) this.requestSeek(next.recordingID, upcoming, next.sourceStart, false);
    }
    for (const [id, other] of this.elements) if (id !== segment.recordingID && !other.paused) other.pause();
    this.applyAudio();
  }

  private applyRate(element: HTMLVideoElement, segment: SequenceSegment) {
    const rate = segment.freezeDuration != null ? 1 : clampRate(segment.rate);
    try { if (element.playbackRate !== rate) element.playbackRate = rate; } catch { /* unsupported rate: keep the last accepted */ }
  }

  /** Mute when the browser cannot keep pitch outside 0.5–2×, and during held frames. */
  private applyAudio() {
    const segment = this.currentSegment;
    for (const [id, element] of this.elements) {
      const active = segment?.recordingID === id;
      const rate = segment ? clampRate(segment.rate) : 1;
      const keepsPitch = "preservesPitch" in element;
      if (keepsPitch) (element as HTMLVideoElement & { preservesPitch: boolean }).preservesPitch = true;
      const outOfRange = !keepsPitch && (rate < PITCH_RANGE[0] || rate > PITCH_RANGE[1]);
      element.muted = this.muted || !active || outOfRange || segment?.freezeDuration != null;
    }
  }

  private startActiveElement() {
    const segment = this.currentSegment;
    if (!segment || segment.freezeDuration != null) return;
    const element = this.elements.get(segment.recordingID);
    if (!element) return;
    this.applyRate(element, segment);
    element.play().catch(() => { /* autoplay refusal surfaces as a paused state */ this.pause(); });
  }

  private schedule() {
    if (this.frame || this.disposed) return;
    this.frame = requestAnimationFrame(this.tick);
  }

  private tick = (now: number) => {
    this.frame = 0;
    if (!this.playing) return;
    const dt = Math.max(0, Math.min(0.25, (now - this.lastTick) / 1000));
    this.lastTick = now;
    const segment = this.currentSegment;
    if (!segment) { this.pause(); return; }
    const element = this.elements.get(segment.recordingID);
    if (segment.freezeDuration != null) {
      this.outputTime += dt;
    } else if (element) {
      if (element.paused && !element.ended && !this.seeking.has(segment.recordingID)) this.startActiveElement();
      // Trust the decoder for the frame on screen; fall back to the wall clock while it seeks.
      const fromVideo = outputTimeAt(segment, element.currentTime);
      this.outputTime = this.seeking.has(segment.recordingID) ? Math.min(segmentEnd(segment), this.outputTime + dt) : Math.max(this.outputTime, fromVideo);
      if (element.currentTime >= segment.sourceEnd - END_EPSILON) this.outputTime = segmentEnd(segment);
    }
    const limit = this.rangeEnd ?? this.duration;
    if (this.outputTime >= limit - END_EPSILON) {
      this.outputTime = limit;
      this.pause();
      this.applyPosition(false);
      this.emitTime();
      return;
    }
    if (this.outputTime >= segmentEnd(segment) - END_EPSILON) this.advance();
    this.emit(false);
    this.schedule();
  };

  /** Moves to the next segment at a cut; a following clip on the same recording is a plain seek. */
  private advance() {
    const segment = this.currentSegment;
    if (!segment) return;
    const index = this.segments.indexOf(segment);
    const next = this.segments[index + 1];
    if (!next) { this.outputTime = this.duration; this.pause(); return; }
    this.outputTime = next.start;
    this.applyPosition(false);
    this.startActiveElement();
  }

  private emitTime() {
    const segment = this.currentSegment;
    const sample: TimeSample = { outputTime: this.outputTime, sourceTime: segment ? sourceTimeAt(segment, this.outputTime) : 0, clip: this.activeClip };
    for (const listener of this.timeListeners) listener(sample);
  }

  /** State listeners run at most ~30 Hz for time-only changes; structural changes flush immediately. */
  private emit(force: boolean) {
    this.emitTime();
    const now = performance.now();
    if (!force && now - this.lastEmit < 33) return;
    this.lastEmit = now;
    const state = this.state;
    for (const listener of this.listeners) listener(state);
  }
}
