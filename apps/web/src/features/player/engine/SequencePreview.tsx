import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { CompositionClip } from "@/domain";
import { aspectValue } from "@/features/editor/model/edits";
import type { SequencePlayer, TimeSample } from "./sequence-player";
import "./SequencePreview.css";

export interface OverlayContext {
  clip: CompositionClip;
  /** Seconds into the clip's recording currently on screen. */
  sourceTime: number;
  outputTime: number;
  /** Pixel size of the scaled source frame the overlay covers (fractions of it are annotation coordinates). */
  size: { width: number; height: number };
}

export interface SequencePreviewProps {
  player: SequencePlayer;
  aspectRatio: string;
  /** Called every frame; the returned node is drawn over the source frame, clipped by the crop. */
  renderOverlay?: (ctx: OverlayContext) => ReactNode;
  /** Controls placed over the bottom edge of the stage. */
  children?: ReactNode;
  className?: string;
  /** "contain" letterboxes the crop inside the container (default); "fill" stretches the stage to the container. */
  fit?: "contain" | "fill";
}

interface Frame { stage: { width: number; height: number }; source: { width: number; height: number }; ratio: number }

/** Renders the active <video> of a SequencePlayer with the composition's crop applied.
 *  The overlay slot lets the analysis workspace draw annotations over the same frame. */
export function SequencePreview({ player, aspectRatio, renderOverlay, children, className = "", fit = "contain" }: SequencePreviewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const [containerSize, setContainerSize] = useState({ width: 0, height: 0 });
  const [videoSize, setVideoSize] = useState<{ width: number; height: number } | null>(null);
  const [sample, setSample] = useState<TimeSample>({ outputTime: 0, sourceTime: 0, clip: null });
  const [activeID, setActiveID] = useState<string | null>(null);

  // Mount every element once; show only the active recording so cuts never flash black.
  useLayoutEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const sync = () => {
      for (const [id, element] of player.elements) {
        if (element.parentElement !== stage) { element.className = "seq-video"; stage.prepend(element); }
        element.dataset.active = id === (player.state.activeRecordingID ?? "") ? "true" : "false";
      }
    };
    sync();
    return player.subscribe((state) => {
      sync();
      setActiveID(state.activeRecordingID);
      const element = state.activeRecordingID ? player.elements.get(state.activeRecordingID) : null;
      if (element && element.videoWidth) setVideoSize((prev) => (prev?.width === element.videoWidth && prev?.height === element.videoHeight ? prev : { width: element.videoWidth, height: element.videoHeight }));
    });
  }, [player]);

  useEffect(() => {
    if (!renderOverlay) return;
    return player.onTime(setSample);
  }, [player, renderOverlay]);

  useEffect(() => {
    const element = activeID ? player.elements.get(activeID) : null;
    if (!element) return;
    const update = () => { if (element.videoWidth) setVideoSize({ width: element.videoWidth, height: element.videoHeight }); };
    update();
    element.addEventListener("loadedmetadata", update);
    element.addEventListener("resize", update);
    return () => { element.removeEventListener("loadedmetadata", update); element.removeEventListener("resize", update); };
  }, [player, activeID]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const observer = new ResizeObserver(([entry]) => { if (entry) setContainerSize({ width: entry.contentRect.width, height: entry.contentRect.height }); });
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  const frame = layoutFrame(containerSize, videoSize, aspectRatio, fit);
  const isOriginal = aspectValue(aspectRatio) == null;
  return (
    <div ref={containerRef} className={`seq-preview ${className}`}>
      <div ref={stageRef} className="seq-stage" data-fit={isOriginal ? "contain" : "cover"} style={{ width: frame.stage.width || "100%", height: frame.stage.height || "100%" }}>
        {renderOverlay && sample.clip && frame.source.width > 0 && (
          <div className="seq-overlay" style={{ width: frame.source.width, height: frame.source.height }}>
            {renderOverlay({ clip: sample.clip, sourceTime: sample.sourceTime, outputTime: sample.outputTime, size: frame.source })}
          </div>
        )}
        {children && <div className="seq-controls">{children}</div>}
      </div>
    </div>
  );
}

/** Stage = the crop rectangle fitted inside the container; source = the video frame scaled
 *  to cover (crop) or fit (original) that stage. */
function layoutFrame(container: { width: number; height: number }, video: { width: number; height: number } | null, aspectRatio: string, fit: "contain" | "fill"): Frame {
  const videoRatio = video && video.height > 0 ? video.width / video.height : 16 / 9;
  const ratio = aspectValue(aspectRatio) ?? videoRatio;
  if (container.width <= 0 || container.height <= 0) return { stage: { width: 0, height: 0 }, source: { width: 0, height: 0 }, ratio };
  let stage = { width: container.width, height: container.height };
  if (fit === "contain") {
    stage = container.width / container.height > ratio
      ? { width: container.height * ratio, height: container.height }
      : { width: container.width, height: container.width / ratio };
  }
  const cover = aspectValue(aspectRatio) != null;
  const scale = cover ? Math.max(stage.width / (videoRatio * 1), stage.height) : Math.min(stage.width / videoRatio, stage.height);
  // `scale` is the source height in pixels; width follows the video ratio.
  const source = { width: scale * videoRatio, height: scale };
  return { stage, source, ratio };
}
