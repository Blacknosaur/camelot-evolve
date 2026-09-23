import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, type PointerEvent as ReactPointerEvent } from "react";
import { eventTint, type Recording, type UUID } from "@/domain";
import { Icon } from "@/design/icons";
import type { RangeDraft } from "./EventBrowser";
import { clampTime, eventIDKey, layoutEvents, makeGeometry, maxZoom, pointsPerSecond, resizeSnapshot, sameEventID, snapshotEnd, snapshotStart, tickInterval, timeToX, timelineTimecode, trimRange, subdivisionInterval, xToTime, type TimelineEventID, type TimelineEventSnapshot, type TimelineGeometry, type TimelinePlacedEvent } from "./model/geometry";
import { segmentDuration, segmentEnd, sourceTimeAt, type SequenceSegment } from "./model/sequence";
import { requestStrip, type StripSample, type ThumbnailImage } from "./thumbnails";
import { TransportBar, type TransportBarProps } from "./PlaybackControls";

export interface TimelineClip { segment: SequenceSegment; number: number }

export interface TimelineProps {
  duration: number;
  currentTime: number;
  zoom: number;
  onZoom: (zoom: number) => void;
  clips: readonly TimelineClip[];
  recordings: ReadonlyMap<UUID, Recording>;
  /** Recording shown when `clips` is empty (source trimming). */
  sourceRecording?: Recording;
  selectedClipID: UUID | null;
  selectClip: (id: UUID) => void;
  reorderClip: (id: UUID, destination: number) => void;
  events: readonly TimelineEventSnapshot[];
  selectedEventID: TimelineEventID | null;
  selectEvent: (id: TimelineEventID | null) => void;
  /** New pre/post roll in output seconds for the occurrence. */
  updateEventWindow: (id: TimelineEventID, preRoll: number, postRoll: number) => void;
  showsTrim: boolean;
  trimStart: number;
  trimEnd: number;
  updateTrim: (start: number, end: number) => void;
  previewSeek: (seconds: number) => void;
  commitSeek: (seconds: number) => void;
  onDraft: (draft: RangeDraft | null) => void;
  addClipAtStart?: (() => void) | null;
  addClipAtEnd?: (() => void) | null;
  transport: Omit<TransportBarProps, "zoom" | "duration" | "onZoom" | "visibleSeconds">;
  interactive?: boolean;
}

const HOLD_MS = 350;
const ROW_HEIGHT = 36;
const THUMB_HEIGHT = 100;
const IMAGE_LIMIT = 48;

interface Bands { film: { y: number; height: number }; eventsTop: number }

function bands(height: number): Bands {
  const filmHeight = Math.min(68, Math.max(36, height * 0.26));
  return { film: { y: 26, height: filmHeight }, eventsTop: 26 + filmHeight + 8 };
}

/** Virtual timeline: one canvas the size of the viewport draws only the visible range, whatever the
 *  recording length. The playhead is fixed at the centre; dragging moves the content (scrubbing),
 *  wheel/pinch zooms around the playhead, handles trim the selected range, holding a clip reorders it.
 *  Port of TimelineViewport/TimelineCanvas (EditorTimeline.swift). */
export function Timeline(props: TimelineProps) {
  const { duration, currentTime, zoom, onZoom, clips, sourceRecording, selectedClipID, events, selectedEventID, showsTrim, trimStart, trimEnd, transport, interactive = true } = props;
  const hostRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const labelRef = useRef<HTMLDivElement>(null);
  const beforeRef = useRef<HTMLButtonElement>(null);
  const afterRef = useRef<HTMLButtonElement>(null);
  const sizeRef = useRef({ width: 0, height: 0 });
  const center = useRef(currentTime);
  const workingZoom = useRef(zoom);
  const verticalOffset = useRef(0);
  const placed = useRef<TimelinePlacedEvent[]>([]);
  const images = useRef(new Map<number, ThumbnailImage>());
  const sampleInterval = useRef(1);
  const requested = useRef<string>("");
  const cancelStrip = useRef<(() => void) | null>(null);
  const stripTimer = useRef(0);
  const frame = useRef(0);
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const gesture = useRef<Gesture | null>(null);
  const pinch = useRef<{ zoom: number; distance: number; anchor: number } | null>(null);
  const drag = useRef<{ leading: boolean; start: number; end: number; grabOffset: number; x: number } | null>(null);
  const clipDrag = useRef<{ id: UUID; destination: number; originalTime: number; x: number; insertion: number | null } | null>(null);
  const holdTimer = useRef(0);
  const wheelTimer = useRef(0);
  const autoScroll = useRef(0);
  const latest = useRef(props);
  latest.current = props;

  const interacting = () => !!gesture.current || !!pinch.current || !!drag.current || !!clipDrag.current;

  const geometry = useCallback((): TimelineGeometry => {
    const { width } = sizeRef.current;
    const p = latest.current;
    return makeGeometry(Math.max(0.1, p.duration), Math.max(1, width), workingZoom.current, p.showsTrim ? width * 0.1 : Math.max(52, width * 0.1));
  }, []);

  const selectedEvent = () => latest.current.events.find((e) => sameEventID(e.id, latest.current.selectedEventID)) ?? null;
  const selectedRange = (): [number, number] | null => {
    const p = latest.current;
    if (drag.current) return [drag.current.start, drag.current.end];
    if (p.showsTrim) return [p.trimStart, p.trimEnd];
    const event = selectedEvent();
    return event ? [snapshotStart(event), Math.min(p.duration, snapshotEnd(event))] : null;
  };

  useMemo(() => { placed.current = layoutEvents(events); }, [events]);

  const clipsKey = clips.map((c) => `${c.segment.id}:${c.segment.start}:${c.segment.sourceStart}:${c.segment.rate}`).join("|") + (sourceRecording?.id ?? "");
  useEffect(() => { images.current.clear(); requested.current = ""; cancelStrip.current?.(); }, [clipsKey]);

  // MARK: Drawing

  const draw = useCallback(() => {
    frame.current = 0;
    const canvas = canvasRef.current;
    const { width, height } = sizeRef.current;
    if (!canvas || width <= 0 || height <= 0) return;
    const dpr = window.devicePixelRatio || 1;
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) { canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr); }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    const p = latest.current;
    const g = geometry();
    const c = center.current;
    const x = (seconds: number) => timeToX(g, seconds, c);
    const left = xToTime(g, 0, c), right = xToTime(g, width, c);
    const { film, eventsTop } = bands(height);
    const font = "500 12px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.font = font; ctx.textBaseline = "top";
    const styles = getComputedStyle(canvas);
    const signal = styles.getPropertyValue("--signal").trim() || "rgb(209 255 64)";
    const resolve = (color: string) => (color.startsWith("var(") ? styles.getPropertyValue(color.slice(4, -1)).trim() || "#ff9500" : color);
    const alpha = (color: string, a: number) => { ctx.save(); ctx.globalAlpha = a; ctx.fillStyle = resolve(color); return () => ctx.restore(); };
    const rounded = (rx: number, ry: number, rw: number, rh: number, r: number) => { ctx.beginPath(); ctx.roundRect(rx, ry, Math.max(0, rw), Math.max(0, rh), r); };

    // Film band: thumbnails per clip range, clipped, stretched when zoom outruns the cache.
    const ranges: Array<[number, number, SequenceSegment | null]> = p.clips.length ? p.clips.map((cl) => [cl.segment.start, segmentEnd(cl.segment), cl.segment]) : [[0, p.duration, null]];
    const drawInterval = Math.max(sampleInterval.current, tickInterval(g));
    for (const [start, end] of ranges) {
      if (end < left || start > right) continue;
      const bx = Math.max(-8, x(start)) + 1, bw = Math.max(1, Math.min(width + 8, x(end)) - Math.max(-8, x(start)) - 2);
      ctx.save(); rounded(bx, film.y, bw, film.height, 6); ctx.clip();
      ctx.fillStyle = "rgba(255,255,255,0.07)"; ctx.fillRect(bx, film.y, bw, film.height);
      const first = Math.max(0, Math.floor((left - start) / drawInterval));
      const last = Math.max(first, Math.ceil((Math.min(right, end) - start) / drawInterval));
      const keys = [...images.current.keys()].filter((k) => k >= start && k < end);
      for (let i = first; i <= last; i += 1) {
        const seconds = start + i * drawInterval;
        if (seconds >= end) continue;
        let image = images.current.get(seconds);
        if (!image && keys.length) {
          let nearest = keys[0]!;
          for (const k of keys) if (Math.abs(k - seconds) < Math.abs(nearest - seconds)) nearest = k;
          image = images.current.get(nearest);
        }
        if (!image) continue;
        const cellW = Math.min(drawInterval, end - seconds) * pointsPerSecond(g);
        const cell = { x: x(seconds), y: film.y, w: cellW, h: film.height };
        const iw = image.width, ih = image.height;
        if (!iw || !ih) continue;
        const scale = Math.max(cell.w / iw, cell.h / ih);
        ctx.save(); ctx.beginPath(); ctx.rect(cell.x, cell.y, cell.w, cell.h); ctx.clip();
        ctx.drawImage(image, cell.x + cell.w / 2 - iw * scale / 2, cell.y + cell.h / 2 - ih * scale / 2, iw * scale, ih * scale);
        ctx.restore();
      }
      ctx.restore();
    }
    for (const clip of p.clips) {
      const s = clip.segment, e = segmentEnd(s);
      if (e < left || s.start > right) continue;
      const bx = Math.max(-8, x(s.start)) + 1, bw = Math.max(1, Math.min(width + 8, x(e)) - Math.max(-8, x(s.start)) - 2);
      ctx.save(); rounded(bx, film.y, bw, film.height, 6); ctx.clip();
      ctx.fillStyle = "rgba(0,0,0,0.55)"; ctx.fillRect(bx, film.y + film.height - 21, bw, 21);
      if (bw > 28) {
        ctx.fillStyle = "#fff";
        ctx.fillText(`${s.freezeDuration == null ? `Clip ${clip.number}` : "Freeze"} · ${timelineTimecode(segmentDuration(s))}`, Math.max(5, bx + 6), film.y + film.height - 18);
      }
      ctx.restore();
      const selected = p.selectedClipID === s.id;
      ctx.strokeStyle = selected ? signal : "rgba(255,255,255,0.65)"; ctx.lineWidth = selected ? 2 : 1;
      rounded(bx, film.y, bw, film.height, 6); ctx.stroke();
    }
    if (clipDrag.current) {
      const dragged = p.clips.find((cl) => cl.segment.id === clipDrag.current!.id);
      if (dragged) { ctx.fillStyle = "rgba(0,0,0,0.25)"; ctx.fillRect(x(dragged.segment.start), film.y, segmentDuration(dragged.segment) * pointsPerSecond(g), film.height); }
      if (clipDrag.current.insertion != null) { ctx.fillStyle = signal; ctx.fillRect(Math.min(width - 3, Math.max(0, x(clipDrag.current.insertion) - 2)), film.y - 4, 4, film.height + 8); }
    }

    // Ruler.
    const major = tickInterval(g), minor = subdivisionInterval(g);
    const divisions = Math.round(major / minor);
    const firstTick = Math.ceil(left / minor), lastTick = Math.max(firstTick, Math.floor(right / minor));
    for (let i = firstTick; i <= lastTick; i += 1) {
      const time = i * minor;
      if (time < 0 || time > p.duration) continue;
      const isMajor = i % divisions === 0;
      ctx.fillStyle = isMajor ? "rgba(255,255,255,0.6)" : "rgba(255,255,255,0.24)";
      ctx.fillRect(x(time), isMajor ? 16 : 20, 1, isMajor ? 9 : 5);
      if (isMajor) { ctx.fillStyle = "#c8c8cc"; ctx.fillText(timelineTimecode(time, major < 1), x(time) + 4, 1); }
    }

    // Event tracks.
    ctx.save(); ctx.beginPath(); ctx.rect(0, eventsTop, width, Math.max(0, height - eventsTop)); ctx.clip();
    const range = selectedRange();
    for (const { event, row } of placed.current) {
      const by = eventsTop + row * ROW_HEIGHT - verticalOffset.current, bh = 30;
      if (by + bh < eventsTop || by > height) continue;
      const selected = !p.showsTrim && sameEventID(event.id, p.selectedEventID);
      const start = selected && range ? range[0] : snapshotStart(event);
      const end = selected && range ? range[1] : snapshotEnd(event);
      if (end < left || start > right) continue;
      const bx = Math.max(-12, x(start)), bw = Math.max(8, Math.min(width + 12, x(end)) - bx);
      const tint = resolve(eventTint(event.colorHex, event.kind));
      let restore = alpha(tint, selected ? 0.55 : 0.28); rounded(bx, by, bw, bh, 6); ctx.fill(); restore();
      ctx.save(); rounded(bx, by, bw, bh, 6); ctx.clip();
      if (!event.isDrawing) {
        restore = alpha(tint, 0.3); ctx.fillRect(x(event.offset), by, Math.max(0, x(end) - x(event.offset)), bh); restore();
        ctx.fillStyle = tint; ctx.fillRect(x(event.offset) - 1, by, 2, bh);
      }
      if (bw > 58) { ctx.fillStyle = "#fff"; ctx.fillText(`${event.kind} · ${timelineTimecode(end - start)}`, Math.max(8, bx + 10), by + 8); }
      ctx.restore();
      ctx.strokeStyle = selected ? "#fff" : tint; ctx.globalAlpha = selected ? 1 : 0.7; ctx.lineWidth = selected ? 2 : 1;
      rounded(bx + 0.5, by + 0.5, bw - 1, bh - 1, 6); ctx.stroke(); ctx.globalAlpha = 1;
    }
    ctx.restore();

    // Trim shading.
    if (range && p.showsTrim) {
      const sx = Math.max(-16, x(range[0])), ex = Math.min(width + 16, x(range[1]));
      ctx.fillStyle = "rgba(0,0,0,0.62)";
      ctx.fillRect(0, film.y, Math.max(0, Math.min(width, sx)), film.height);
      ctx.fillRect(Math.max(0, ex), film.y, Math.max(0, width - ex), film.height);
      if (ex >= sx) { ctx.strokeStyle = signal; ctx.lineWidth = 2; rounded(sx, film.y, Math.max(1, ex - sx), film.height, 6); ctx.stroke(); }
    }

    // Handles for the selected range.
    const handleBand = handleBandFor(p, height, placed.current, verticalOffset.current);
    if (range && handleBand && !clipDrag.current && (p.showsTrim || selectedEvent()?.isLocked !== true)) {
      for (const [seconds, leading] of [[range[0], true], [range[1], false]] as const) {
        const hx = x(seconds);
        if (hx < -12 || hx > width + 12 || handleBand.y < eventsTop - 40 || handleBand.y > height) continue;
        ctx.fillStyle = p.showsTrim ? signal : "#fff";
        rounded(hx - 6, handleBand.y + handleBand.height / 2 - 19, 12, 38, 4); ctx.fill();
        ctx.fillStyle = "rgba(0,0,0,0.7)"; rounded(hx - 1, handleBand.y + handleBand.height / 2 - 8, 2, 16, 1); ctx.fill();
        void leading;
      }
    }

    // Zoom hint while pinching (the React header cannot follow a ref mid-gesture).
    if (pinch.current) {
      ctx.fillStyle = "rgba(255,255,255,0.7)"; ctx.textAlign = "right";
      ctx.fillText(`${timelineTimecode(p.duration / workingZoom.current)} visible`, width - 6, 1);
      ctx.textAlign = "left";
    }

    // Playhead.
    ctx.fillStyle = signal;
    ctx.fillRect(width / 2 - 1, 16, 2, height - 18);
    ctx.beginPath(); ctx.moveTo(width / 2 - 4, 15); ctx.lineTo(width / 2 + 4, 15); ctx.lineTo(width / 2, 21); ctx.closePath(); ctx.fill();

    // Positioned HTML: add-clip buttons and reorder label.
    for (const [ref, leading] of [[beforeRef, true], [afterRef, false]] as const) {
      const button = ref.current;
      if (!button) continue;
      const action = leading ? p.addClipAtStart : p.addClipAtEnd;
      const edge = x(leading ? 0 : p.duration);
      const bx = leading ? edge - 48 : edge + 4;
      const visible = !p.showsTrim && !!action && !clipDrag.current && bx + 44 > 0 && bx < width;
      button.style.display = visible ? "flex" : "none";
      button.style.transform = `translate(${bx}px, ${film.y + film.height / 2 - 22}px)`;
    }
    const label = labelRef.current;
    if (label) {
      label.style.display = clipDrag.current ? "block" : "none";
      if (clipDrag.current) label.style.transform = `translate(${Math.min(width - 74, Math.max(2, clipDrag.current.x - 36))}px, 1px)`;
    }
  }, [geometry]);

  const refresh = useCallback(() => { if (!frame.current) frame.current = requestAnimationFrame(draw); }, [draw]);

  // MARK: Thumbnails

  const loadVisibleThumbnails = useCallback(() => {
    const p = latest.current;
    const g = geometry();
    const { width } = sizeRef.current;
    if (width <= 0) return;
    const interval = Math.max(0.25, 2 ** Math.ceil(Math.log2(72 / pointsPerSecond(g))));
    const left = xToTime(g, -72, center.current), right = xToTime(g, width + 72, center.current);
    const samples: StripSample[] = [];
    const ranges: Array<[number, number, SequenceSegment | null]> = p.clips.length ? p.clips.map((cl) => [cl.segment.start, segmentEnd(cl.segment), cl.segment]) : [[0, p.duration, null]];
    for (const [start, end, segment] of ranges) {
      if (end < left || start > right) continue;
      const lower = Math.max(0, Math.floor((left - start) / interval));
      const upper = Math.max(lower, Math.ceil((Math.min(right, end) - start) / interval));
      for (let i = lower; i <= upper; i += 1) {
        const seconds = start + i * interval;
        if (seconds >= end) continue;
        const recordingID = segment?.recordingID ?? p.sourceRecording?.id;
        if (!recordingID) continue;
        samples.push({ outputSeconds: seconds, recordingID, sourceSeconds: segment ? sourceTimeAt(segment, seconds) : seconds });
      }
    }
    const key = `${interval}:${samples.map((s) => s.outputSeconds).join(",")}`;
    if (key === requested.current) return;
    requested.current = key;
    cancelStrip.current?.();
    clearTimeout(stripTimer.current);
    // Coalesce rapid scroll updates before starting another decoder request.
    stripTimer.current = window.setTimeout(() => {
      const missing = samples.filter((s) => !images.current.has(s.outputSeconds));
      const recordingsMap = latest.current.recordings;
      cancelStrip.current = requestStrip(missing, recordingsMap, THUMB_HEIGHT, (seconds, image) => {
        images.current.set(seconds, image);
        if (images.current.size > IMAGE_LIMIT) {
          const keep = new Set([...images.current.keys()].sort((a, b) => Math.abs(a - center.current) - Math.abs(b - center.current)).slice(0, 32));
          for (const k of [...images.current.keys()]) if (!keep.has(k)) images.current.delete(k);
        }
        sampleInterval.current = interval;
        refresh();
      });
      sampleInterval.current = interval;
      refresh();
    }, 60);
  }, [geometry, refresh]);

  // MARK: Sync from props

  useLayoutEffect(() => {
    if (interacting()) return;
    center.current = clampTime(geometry(), currentTime);
    workingZoom.current = zoom;
    refresh();
    loadVisibleThumbnails();
  }, [currentTime, zoom, duration, clips, events, selectedClipID, selectedEventID, showsTrim, trimStart, trimEnd, geometry, refresh, loadVisibleThumbnails]);

  // Bring a freshly selected event's row into view.
  const selectedKey = selectedEventID ? eventIDKey(selectedEventID) : null;
  useEffect(() => {
    if (!selectedKey) return;
    const hit = placed.current.find((pl) => eventIDKey(pl.event.id) === selectedKey);
    if (!hit) return;
    const lane = Math.max(ROW_HEIGHT, sizeRef.current.height - bands(sizeRef.current.height).eventsTop);
    verticalOffset.current = Math.min(maxVerticalOffset(), Math.max(0, hit.row * ROW_HEIGHT - (lane - ROW_HEIGHT) / 2));
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedKey]);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const observer = new ResizeObserver(([entry]) => {
      if (!entry) return;
      sizeRef.current = { width: entry.contentRect.width, height: entry.contentRect.height };
      refresh(); loadVisibleThumbnails();
    });
    observer.observe(host);
    return () => { observer.disconnect(); cancelAnimationFrame(frame.current); cancelStrip.current?.(); clearTimeout(stripTimer.current); clearTimeout(holdTimer.current); cancelAnimationFrame(autoScroll.current); };
  }, [refresh, loadVisibleThumbnails]);

  const maxVerticalOffset = () => {
    const rows = placed.current.reduce((m, pl) => Math.max(m, pl.row + 1), 0);
    const { height } = sizeRef.current;
    return Math.max(0, bands(height).eventsTop + rows * ROW_HEIGHT + 8 - height);
  };

  // MARK: Gestures

  const point = (e: ReactPointerEvent | PointerEvent) => {
    const rect = hostRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  };

  const hitHandle = (pt: { x: number; y: number }): boolean | null => {
    const p = latest.current;
    const range = selectedRange();
    if (!range) return null;
    const band = handleBandFor(p, sizeRef.current.height, placed.current, verticalOffset.current);
    if (!band || (!p.showsTrim && selectedEvent()?.isLocked)) return null;
    const midY = band.y + band.height / 2;
    if (Math.abs(pt.y - midY) > 24) return null;
    const g = geometry();
    const candidates = ([[true, timeToX(g, range[0], center.current)], [false, timeToX(g, range[1], center.current)]] as const).filter(([, hx]) => Math.abs(pt.x - hx) <= 22);
    if (!candidates.length) return null;
    return candidates.sort((a, b) => Math.abs(pt.x - a[1]) - Math.abs(pt.x - b[1]))[0]![0];
  };

  const clipAt = (seconds: number) => latest.current.clips.find((cl) => seconds >= cl.segment.start && seconds < segmentEnd(cl.segment)) ?? null;

  const selectTimelineEvent = (id: TimelineEventID) => {
    const p = latest.current;
    const event = p.events.find((e) => sameEventID(e.id, id));
    if (!event) return;
    const deselecting = sameEventID(p.selectedEventID, id);
    p.selectEvent(deselecting ? null : id);
    if (!deselecting) center.current = clampTime(geometry(), Math.min(event.upperBound, Math.max(event.lowerBound, event.offset)));
    refresh();
    p.commitSeek(center.current);
  };

  const tapped = (pt: { x: number; y: number }) => {
    const p = latest.current;
    const g = geometry();
    const seconds = xToTime(g, pt.x, center.current);
    const { eventsTop } = bands(sizeRef.current.height);
    if (pt.y >= eventsTop && !p.showsTrim) {
      const hit = placed.current.find(({ event, row }) => {
        const by = eventsTop + row * ROW_HEIGHT - verticalOffset.current;
        return pt.y >= by && pt.y <= by + 30 && seconds >= snapshotStart(event) && seconds <= snapshotEnd(event);
      });
      if (hit) { selectTimelineEvent(hit.event.id); return; }
    }
    p.selectEvent(null);
    if (pt.y < eventsTop) {
      center.current = seconds;
      const clip = clipAt(seconds);
      if (clip) p.selectClip(clip.segment.id);
    }
    refresh();
    p.commitSeek(center.current);
  };

  const applyEdge = (value: number) => {
    const d = drag.current;
    if (!d) return;
    const p = latest.current;
    const seconds = Math.round(value * 10) / 10;
    if (p.showsTrim) [d.start, d.end] = trimRange(seconds, d.start, d.end, p.duration, d.leading);
    else { const ev = selectedEvent(); if (ev) [d.start, d.end] = resizeSnapshot(ev, seconds, d.start, d.end, d.leading, p.duration); }
    p.onDraft({ eventID: p.showsTrim ? null : p.selectedEventID, start: d.start, end: d.end });
    p.previewSeek(d.leading ? d.start : d.end);
    refresh();
  };

  const finishDrag = (cancelled: boolean) => {
    const d = drag.current;
    if (!d) return;
    const p = latest.current;
    cancelAnimationFrame(autoScroll.current); autoScroll.current = 0;
    if (!cancelled) {
      if (p.showsTrim) { if (d.start !== p.trimStart || d.end !== p.trimEnd) p.updateTrim(d.start, d.end); }
      else { const ev = selectedEvent(); if (ev) p.updateEventWindow(ev.id, d.leading ? ev.offset - d.start : ev.preRoll, d.leading ? ev.postRoll : d.end - ev.offset); }
    }
    drag.current = null;
    p.onDraft(null);
    center.current = clampTime(geometry(), d.leading ? d.start : d.end);
    refresh();
    p.commitSeek(center.current);
  };

  const updateReorder = () => {
    const cd = clipDrag.current;
    if (!cd) return;
    const p = latest.current;
    const seconds = xToTime(geometry(), cd.x, center.current);
    const remaining = p.clips.filter((cl) => cl.segment.id !== cd.id);
    cd.destination = remaining.filter((cl) => seconds > (cl.segment.start + segmentEnd(cl.segment)) / 2).length;
    cd.insertion = cd.destination < remaining.length ? remaining[cd.destination]!.segment.start : p.duration;
    refresh();
  };

  const finishReorder = (cancelled: boolean) => {
    const cd = clipDrag.current;
    if (!cd) return;
    cancelAnimationFrame(autoScroll.current); autoScroll.current = 0;
    clipDrag.current = null;
    center.current = cd.originalTime;
    refresh();
    if (!cancelled) latest.current.reorderClip(cd.id, cd.destination);
  };

  const startAutoScroll = () => {
    let last = performance.now();
    const step = (now: number) => {
      autoScroll.current = 0;
      const active = drag.current ?? clipDrag.current;
      if (!active) return;
      const dt = (now - last) / 1000; last = now;
      const { width } = sizeRef.current;
      const margin = Math.min(44, width / 4);
      const px = active.x;
      const direction = px < margin ? -Math.min(1, (margin - px) / margin) : px > width - margin ? Math.min(1, (px - width + margin) / margin) : 0;
      if (direction !== 0) {
        const g = geometry();
        center.current = clampTime(g, center.current + direction * 180 / pointsPerSecond(g) * dt);
        if (drag.current) applyEdge(xToTime(g, drag.current.x - drag.current.grabOffset, center.current));
        else updateReorder();
      }
      autoScroll.current = requestAnimationFrame(step);
    };
    autoScroll.current = requestAnimationFrame(step);
  };

  const beginPinch = () => {
    const [a, b] = [...pointers.current.values()];
    if (!a || !b) return;
    clearTimeout(holdTimer.current);
    gesture.current = null;
    pinch.current = { zoom: workingZoom.current, distance: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), anchor: center.current };
    latest.current.commitSeek(center.current);
  };

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!interactive) return;
    const pt = point(e);
    pointers.current.set(e.pointerId, pt);
    e.currentTarget.setPointerCapture(e.pointerId);
    if (pointers.current.size === 2) { if (drag.current) finishDrag(true); if (clipDrag.current) finishReorder(true); beginPinch(); return; }
    if (pointers.current.size > 2) return;
    const p = latest.current;
    const handle = hitHandle(pt);
    if (handle != null) {
      const range = selectedRange()!;
      const edge = handle ? range[0] : range[1];
      drag.current = { leading: handle, start: range[0], end: range[1], grabOffset: pt.x - timeToX(geometry(), edge, center.current), x: pt.x };
      p.previewSeek(edge);
      startAutoScroll();
      return;
    }
    gesture.current = { id: e.pointerId, origin: pt, center: center.current, offset: verticalOffset.current, axis: null, moved: false };
    const { film } = bands(sizeRef.current.height);
    const g = geometry();
    const seconds = xToTime(g, pt.x, center.current);
    if (!p.showsTrim && p.clips.length > 1 && pt.y >= film.y && pt.y <= film.y + film.height && pt.x >= timeToX(g, 0, center.current) && pt.x <= timeToX(g, p.duration, center.current)) {
      const clip = clipAt(seconds);
      if (clip) {
        holdTimer.current = window.setTimeout(() => {
          if (!gesture.current || gesture.current.moved) return;
          gesture.current = null;
          clipDrag.current = { id: clip.segment.id, destination: clip.number - 1, originalTime: center.current, x: pt.x, insertion: null };
          p.commitSeek(center.current);
          if (labelRef.current) labelRef.current.textContent = `Clip ${clip.number}`;
          updateReorder();
          startAutoScroll();
        }, HOLD_MS);
      }
    }
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(e.pointerId)) return;
    const pt = point(e);
    pointers.current.set(e.pointerId, pt);
    const p = latest.current;
    if (pinch.current) {
      const [a, b] = [...pointers.current.values()];
      if (!a || !b) return;
      const scale = Math.hypot(a.x - b.x, a.y - b.y) / pinch.current.distance;
      workingZoom.current = Math.max(1, Math.min(maxZoom(p.duration), pinch.current.zoom * scale));
      center.current = pinch.current.anchor;
      refresh();
      return;
    }
    if (drag.current) { drag.current.x = pt.x; applyEdge(xToTime(geometry(), pt.x - drag.current.grabOffset, center.current)); return; }
    if (clipDrag.current) { clipDrag.current.x = pt.x; updateReorder(); return; }
    const gs = gesture.current;
    if (!gs || gs.id !== e.pointerId) return;
    const dx = pt.x - gs.origin.x, dy = pt.y - gs.origin.y;
    if (!gs.axis) {
      if (Math.hypot(dx, dy) < 6) return;
      gs.axis = Math.abs(dy) > Math.abs(dx) && gs.origin.y >= bands(sizeRef.current.height).eventsTop ? "vertical" : "horizontal";
      gs.moved = true;
      clearTimeout(holdTimer.current);
    }
    if (gs.axis === "vertical") { verticalOffset.current = Math.min(maxVerticalOffset(), Math.max(0, gs.offset - dy)); refresh(); return; }
    const g = geometry();
    const next = clampTime(g, gs.center - dx / pointsPerSecond(g));
    if (Math.abs(next - center.current) > 0.001) { center.current = next; p.previewSeek(next); }
    refresh(); loadVisibleThumbnails();
  };

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>, cancelled = false) => {
    const had = pointers.current.delete(e.pointerId);
    if (!had) return;
    const p = latest.current;
    if (pinch.current) {
      if (pointers.current.size < 2) {
        center.current = pinch.current.anchor;
        pinch.current = null;
        p.onZoom(workingZoom.current);
        refresh(); loadVisibleThumbnails();
      }
      return;
    }
    if (drag.current) { finishDrag(cancelled); return; }
    if (clipDrag.current) { finishReorder(cancelled); return; }
    const gs = gesture.current;
    clearTimeout(holdTimer.current);
    if (!gs || gs.id !== e.pointerId) return;
    gesture.current = null;
    if (cancelled) { refresh(); return; }
    if (!gs.moved) { tapped(gs.origin); return; }
    if (gs.axis === "horizontal") p.commitSeek(center.current);
  };

  const onWheel = (e: WheelEvent) => {
    if (!latest.current || !interactive) return;
    e.preventDefault();
    const p = latest.current;
    const g = geometry();
    if (e.ctrlKey || e.metaKey) {
      workingZoom.current = Math.max(1, Math.min(maxZoom(p.duration), workingZoom.current * Math.exp(-e.deltaY * 0.01)));
      refresh();
      clearTimeout(wheelTimer.current);
      wheelTimer.current = window.setTimeout(() => { p.onZoom(workingZoom.current); loadVisibleThumbnails(); }, 120);
      return;
    }
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      center.current = clampTime(g, center.current + e.deltaX / pointsPerSecond(g));
      p.previewSeek(center.current);
      refresh(); loadVisibleThumbnails();
      clearTimeout(wheelTimer.current);
      wheelTimer.current = window.setTimeout(() => p.commitSeek(center.current), 150);
      return;
    }
    verticalOffset.current = Math.min(maxVerticalOffset(), Math.max(0, verticalOffset.current + e.deltaY));
    refresh();
  };

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const handler = (e: WheelEvent) => onWheel(e);
    host.addEventListener("wheel", handler, { passive: false });
    return () => host.removeEventListener("wheel", handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [interactive]);

  const onKeyDown = (e: React.KeyboardEvent) => {
    const p = latest.current;
    const step = e.shiftKey ? 0.1 : e.altKey ? 5 : 1;
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") { e.preventDefault(); p.commitSeek(clampTime(geometry(), center.current + (e.key === "ArrowLeft" ? -step : step))); }
    if (e.key === "Escape") p.selectEvent(null);
  };

  return (
    <div className="ed-timeline">
      <TransportBar {...transport} zoom={zoom} duration={duration} onZoom={onZoom} />
      <div
        ref={hostRef}
        className="ed-timeline-host"
        role="application"
        aria-label="Video timeline"
        aria-description="Drag sideways to scrub or vertically to browse overlapping event tracks. Pinch or hold Ctrl and scroll to zoom. Hold a clip and drag to reorder it. Arrow keys move the playhead."
        tabIndex={0}
        onKeyDown={onKeyDown}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={(e) => onPointerUp(e)}
        onPointerCancel={(e) => onPointerUp(e, true)}
        style={{ touchAction: "none" }}
      >
        <canvas ref={canvasRef} className="ed-canvas" />
        <button ref={beforeRef} type="button" className="ed-add-clip" aria-label="Add clip at start" onPointerDown={(e) => e.stopPropagation()} onClick={() => latest.current.addClipAtStart?.()}><Icon.Plus /></button>
        <button ref={afterRef} type="button" className="ed-add-clip" aria-label="Add clip at end" onPointerDown={(e) => e.stopPropagation()} onClick={() => latest.current.addClipAtEnd?.()}><Icon.Plus /></button>
        <div ref={labelRef} className="ed-reorder-label mono" aria-live="polite" />
      </div>
    </div>
  );
}

interface Gesture { id: number; origin: { x: number; y: number }; center: number; offset: number; axis: "horizontal" | "vertical" | null; moved: boolean }

function handleBandFor(p: TimelineProps, height: number, placed: readonly TimelinePlacedEvent[], verticalOffset: number): { y: number; height: number } | null {
  const { film, eventsTop } = bands(height);
  if (p.showsTrim) return { y: film.y, height: film.height };
  if (!p.selectedEventID) return null;
  const row = placed.find((pl) => sameEventID(pl.event.id, p.selectedEventID))?.row ?? 0;
  return { y: eventsTop + row * ROW_HEIGHT - verticalOffset, height: 30 };
}
