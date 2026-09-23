/* OWNER: media agent. Feature detection used to gate WebCodecs decode, OPFS storage,
   WebGPU effects and camera capture formats. Safe to call from the main thread or a worker. */

export interface MediaCapabilities {
  /** VideoDecoder/VideoEncoder/VideoFrame are present. Without them mediabunny cannot decode. */
  webCodecs: boolean;
  /** Origin Private File System is available in this context. */
  opfs: boolean;
  webGPU: boolean;
  sharedArrayBuffer: boolean;
  /** MediaRecorder MIME types this browser can capture, best first. Empty when MediaRecorder is missing. */
  mediaRecorderMimeTypes: string[];
}

const RECORDER_CANDIDATES = [
  "video/mp4;codecs=hvc1.1.6.L153.B0,mp4a.40.2",
  "video/mp4;codecs=avc1.640028,mp4a.40.2",
  "video/mp4;codecs=avc1.42E01E,mp4a.40.2",
  "video/mp4",
  "video/webm;codecs=vp9,opus",
  "video/webm;codecs=vp8,opus",
  "video/webm",
];

let cached: MediaCapabilities | null = null;

export function detectMediaCapabilities(): MediaCapabilities {
  if (cached) return cached;
  const g = globalThis as Record<string, unknown>;
  const recorder = g.MediaRecorder as { isTypeSupported?(type: string): boolean } | undefined;
  cached = {
    webCodecs: typeof g.VideoDecoder === "function" && typeof g.VideoFrame === "function",
    opfs: typeof navigator !== "undefined" && typeof navigator.storage?.getDirectory === "function",
    webGPU: typeof navigator !== "undefined" && "gpu" in navigator,
    sharedArrayBuffer: typeof g.SharedArrayBuffer === "function" && (g.crossOriginIsolated === true || typeof g.crossOriginIsolated === "undefined"),
    mediaRecorderMimeTypes: recorder?.isTypeSupported ? RECORDER_CANDIDATES.filter((type) => recorder.isTypeSupported!(type)) : [],
  };
  return cached;
}

/** Test hook. */
export function resetMediaCapabilitiesForTests() { cached = null; }
