import { clampRate, clipAnnotationRate, clipPlaybackDuration, type CompositionClip } from "@/domain/records";

/* Pure timing/geometry shared by composition playback and the export renderer so that a frame
   scrubbed in the player and the same frame in the exported file agree. Ports the maths in
   EditorSequencePreview.swift (render size, per-clip fit/fill transform) and
   CompositionRenderer.makeCropComposition (centred crop). No DOM, safe in workers and tests. */

export interface Size { width: number; height: number }
export interface Rect { x: number; y: number; width: number; height: number }

export type ResolutionPreset = "source" | "1080p" | "720p";

/** Maximum output dimension per preset; `source` keeps the first clip's display size. */
export const PRESET_MAX_DIMENSION: Record<ResolutionPreset, number | null> = { source: null, "1080p": 1920, "720p": 1280 };

/** Width/height ratio for a fixed aspect, or null for `original`. Accepts iOS spellings too. */
export function aspectRatioValue(aspectRatio: string): number | null {
  switch (aspectRatio) {
    case "16:9": case "landscape": return 16 / 9;
    case "9:16": case "portrait": return 9 / 16;
    case "1:1": case "square": return 1;
    case "4:5": return 4 / 5;
    default: return null;
  }
}

export function aspectRatioTitle(aspectRatio: string): string {
  switch (aspectRatio) {
    case "16:9": case "landscape": return "16:9";
    case "9:16": case "portrait": return "9:16";
    case "1:1": case "square": return "1:1";
    case "4:5": return "4:5";
    default: return "Original";
  }
}

const even = (value: number) => Math.max(2, Math.floor(value / 2) * 2);

/** Output pixel size: the first clip's display size limited by the preset, cropped to the aspect (iOS `renderSize`). */
export function outputSize(sourceSize: Size, aspectRatio: string, preset: ResolutionPreset = "source"): Size {
  const ratio = aspectRatioValue(aspectRatio) ?? sourceSize.width / Math.max(1, sourceSize.height);
  const maximum = PRESET_MAX_DIMENSION[preset] ?? Math.max(sourceSize.width, sourceSize.height);
  const width = Math.max(2, Math.min(sourceSize.width, maximum * Math.min(1, ratio)));
  return { width: even(width), height: even(width / ratio) };
}

/** Centred source rectangle with the target ratio (the visible region for a fixed aspect). `original` returns the full frame. */
export function cropRect(sourceSize: Size, aspectRatio: string): Rect {
  const ratio = aspectRatioValue(aspectRatio);
  if (ratio == null) return { x: 0, y: 0, ...sourceSize };
  const sourceRatio = sourceSize.width / Math.max(1, sourceSize.height);
  const width = sourceRatio > ratio ? sourceSize.height * ratio : sourceSize.width;
  const height = sourceRatio > ratio ? sourceSize.height : sourceSize.width / ratio;
  return { x: (sourceSize.width - width) / 2, y: (sourceSize.height - height) / 2, width, height };
}

/** Where a clip's display frame lands in the output. `original` fits (letterbox), fixed aspects fill (centred crop),
 *  matching EditorSequencePreview's `min`/`max` scale. The frame may extend past the output bounds. */
export function displayFrame(sourceSize: Size, output: Size, aspectRatio: string): Rect {
  const scaleX = output.width / Math.max(1, sourceSize.width);
  const scaleY = output.height / Math.max(1, sourceSize.height);
  const scale = aspectRatioValue(aspectRatio) == null ? Math.min(scaleX, scaleY) : Math.max(scaleX, scaleY);
  const width = sourceSize.width * scale, height = sourceSize.height * scale;
  return { x: (output.width - width) / 2, y: (output.height - height) / 2, width, height };
}

export interface SourceLocation {
  clipIndex: number;
  clip: CompositionClip;
  /** Output time at which the clip starts. */
  clipStart: number;
  /** Seconds into the clip on the output timeline. */
  elapsed: number;
  /** Source time whose frame is shown (held-frame clips stay on `startSeconds`). */
  sourceTime: number;
  /** Time used to evaluate annotations (held-frame clips advance at 1x from `startSeconds`). */
  annotationTime: number;
}

/** Source/annotation time inside one clip that starts at `clipStart` on the output timeline (clamped to the clip). */
export function locateInClip(clip: CompositionClip, clipStart: number, outputTime: number): Omit<SourceLocation, "clipIndex"> {
  const elapsed = Math.max(0, Math.min(clipPlaybackDuration(clip), outputTime - clipStart));
  const sourceTime = clip.freezeDuration == null ? Math.min(clip.endSeconds, clip.startSeconds + elapsed * clampRate(clip.rate)) : clip.startSeconds;
  return { clip, clipStart, elapsed, sourceTime, annotationTime: clip.startSeconds + elapsed * clipAnnotationRate(clip) };
}

/** Maps an output time to the clip and source time shown there. Returns null past the end. */
export function outputToSource(clips: readonly CompositionClip[], outputTime: number): SourceLocation | null {
  let cursor = 0;
  for (let index = 0; index < clips.length; index++) {
    const clip = clips[index]!;
    const duration = clipPlaybackDuration(clip);
    const isLast = index === clips.length - 1;
    if (outputTime < cursor + duration || (isLast && outputTime <= cursor + duration + 1e-9)) {
      return { clipIndex: index, ...locateInClip(clip, cursor, outputTime) };
    }
    cursor += duration;
  }
  return null;
}

/** Number of constant-rate output frames covering `duration` seconds (at least one for non-empty media). */
export function frameCount(duration: number, fps: number): number {
  if (!(duration > 0) || !(fps > 0)) return 0;
  return Math.max(1, Math.round(duration * fps));
}

/** Presentation time of output frame `index`, exact on the fps grid to avoid drift over long exports. */
export const frameTime = (index: number, fps: number) => index / fps;

/** Clamps a source frame rate to what the export/preview pipeline accepts (iOS: 1...60). */
export const clampFrameRate = (fps: number) => Math.max(1, Math.min(60, Math.round(fps)));
