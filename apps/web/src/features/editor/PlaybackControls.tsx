import { Icon } from "@/design/icons";
import { Spinner } from "@/design/components";
import { EditorIcon } from "./icons";
import { maxZoom, timelineTimecode } from "./model/geometry";

/** Shared zoom actions keep analysis and the main editor visually identical. */
export function TimelineZoomControls({ zoom, duration, onZoom, fit, fitLabel }: { zoom: number; duration: number; onZoom: (zoom: number) => void; fit: () => void; fitLabel: string }) {
  const limit = maxZoom(duration);
  return (
    <div className="ed-zoom" role="group" aria-label="Timeline zoom">
      <button type="button" className="ed-icon-button" aria-label="Zoom out timeline" disabled={zoom <= 1} onClick={() => onZoom(Math.max(1, zoom / 2))}><EditorIcon.ZoomOut /></button>
      <button type="button" className="ed-icon-button" aria-label={fitLabel} title={fitLabel} onClick={fit}><EditorIcon.Fit /></button>
      <button type="button" className="ed-icon-button" aria-label="Zoom in timeline" disabled={zoom >= limit} onClick={() => onZoom(Math.min(limit, zoom * 2))}><EditorIcon.ZoomIn /></button>
    </div>
  );
}

export interface TransportBarProps {
  zoom: number;
  duration: number;
  onZoom: (zoom: number) => void;
  undo?: (() => void) | null;
  redo?: (() => void) | null;
  showsHistory?: boolean;
  addEvent?: (() => void) | null;
  showsEvents?: boolean;
  fit: () => void;
  fitLabel: string;
  visibleSeconds?: number | null;
}

/** Row above the timeline: history, add-event toggle and zoom. Port of EditorPlaybackControls. */
export function TransportBar({ zoom, duration, onZoom, undo, redo, showsHistory = true, addEvent, showsEvents = false, fit, fitLabel, visibleSeconds }: TransportBarProps) {
  return (
    <div className="ed-transport">
      {showsHistory && (
        <>
          <button type="button" className="ed-icon-button" aria-label="Undo edit" disabled={!undo} onClick={() => undo?.()}><Icon.Undo /></button>
          <button type="button" className="ed-icon-button" aria-label="Redo edit" disabled={!redo} onClick={() => redo?.()}><Icon.Redo /></button>
        </>
      )}
      {addEvent && (
        <button type="button" className="ed-icon-button" data-active={showsEvents || undefined} aria-label={showsEvents ? "Hide event buttons" : "Add event"} aria-pressed={showsEvents} onClick={addEvent}><Icon.Flag /></button>
      )}
      {visibleSeconds != null && <span className="ed-transport-hint mono">{timelineTimecode(visibleSeconds)} visible</span>}
      <span className="ed-spacer" />
      <TimelineZoomControls zoom={zoom} duration={duration} onZoom={onZoom} fit={fit} fitLabel={fitLabel} />
    </div>
  );
}

export interface PreviewControlsProps {
  isPlaying: boolean;
  isPreparing: boolean;
  isEnabled: boolean;
  currentTime: number;
  totalTime: number;
  play: () => void;
  previousFrame?: () => void;
  nextFrame?: () => void;
}

/** Lightweight transport at the preview edge. Port of EditorPreviewControls. */
export function PreviewControls({ isPlaying, isPreparing, isEnabled, currentTime, totalTime, play, previousFrame, nextFrame }: PreviewControlsProps) {
  return (
    <div className="ed-preview-controls">
      {previousFrame && <button type="button" className="ed-icon-button" aria-label="Previous frame" disabled={!isEnabled} onClick={previousFrame}><EditorIcon.StepBack /></button>}
      <button type="button" className="ed-action" aria-label={isPreparing ? "Preparing preview" : isPlaying ? "Pause" : "Play"} disabled={!isEnabled} onClick={play}>
        {isPreparing ? <Spinner size={14} /> : isPlaying ? <Icon.Pause /> : <Icon.Play />}
      </button>
      {nextFrame && <button type="button" className="ed-icon-button" aria-label="Next frame" disabled={!isEnabled} onClick={nextFrame}><EditorIcon.StepForward /></button>}
      <span className="ed-spacer" />
      <span className="ed-timecode mono"><b>{timelineTimecode(currentTime)}</b><span className="ed-dim"> / </span>{timelineTimecode(totalTime)}</span>
    </div>
  );
}
