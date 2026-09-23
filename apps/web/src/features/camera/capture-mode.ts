/* Port of `CaptureMode` and `CaptureQuality` (CameraControls.swift / CameraView.swift). */

export type CaptureMode = "full" | "rolling5" | "rolling10";
export const CAPTURE_MODES: readonly CaptureMode[] = ["full", "rolling5", "rolling10"];

export const isRollingMode = (mode: CaptureMode) => mode !== "full";
/** Length of one throw-away segment; `null` for a continuous recording. */
export const bufferSeconds = (mode: CaptureMode): number | null => (mode === "rolling5" ? 5 : mode === "rolling10" ? 10 : null);
export const captureModeShortTitle = (mode: CaptureMode) => (mode === "full" ? "Full video" : mode === "rolling5" ? "Replay 5s" : "Replay 10s");
export const captureModeTitle = (mode: CaptureMode) => (mode === "full" ? "Full video" : mode === "rolling5" ? "Keep 5 seconds before events" : "Keep 10 seconds before events");

export type CaptureQuality = "720p" | "1080p" | "4k";
export const CAPTURE_QUALITIES: readonly CaptureQuality[] = ["720p", "1080p", "4k"];

export const qualityTitle = (q: CaptureQuality) => (q === "720p" ? "720p · smaller files" : q === "1080p" ? "1080p HD" : "4K Ultra HD");
export const qualityShortTitle = (q: CaptureQuality) => (q === "720p" ? "720p" : q === "1080p" ? "HD" : "4K");
export const qualitySize = (q: CaptureQuality) => (q === "720p" ? { width: 1280, height: 720 } : q === "1080p" ? { width: 1920, height: 1080 } : { width: 3840, height: 2160 });

/** The preset a browser actually applied, judged by the shorter side of the delivered frame. */
export function qualityForSize(width: number, height: number): CaptureQuality {
  const short = Math.min(width, height);
  if (short >= 2000) return "4k";
  if (short >= 1000) return "1080p";
  return "720p";
}

/** Presets the track can deliver, judged by its capability range (all three when the browser hides it). */
export function availableQualities(maxWidth: number | undefined, maxHeight: number | undefined): CaptureQuality[] {
  if (!maxWidth || !maxHeight) return ["720p", "1080p"];
  const longest = Math.max(maxWidth, maxHeight), shortest = Math.min(maxWidth, maxHeight);
  return CAPTURE_QUALITIES.filter((q) => { const s = qualitySize(q); return longest >= s.width && shortest >= s.height; });
}

export const STORAGE_FLOOR_BYTES = 500 * 1024 * 1024;
