import { ALL_FORMATS, BlobSource, Input } from "mediabunny";

/* OWNER: media agent. Reads container metadata without decoding. Works in workers (no DOM);
   falls back to a <video> element on the main thread when mediabunny cannot parse the file. */

export interface VideoProbe {
  /** Seconds. 0 when unknown. */
  duration: number;
  /** Display size in pixels, after the container rotation is applied (like AVAssetTrack preferredTransform). */
  width: number;
  height: number;
  /** Clockwise container rotation: 0, 90, 180 or 270. */
  rotation: number;
  mimeType: string;
  /** mediabunny codec name such as "avc", "hevc", "vp9", "av1"; null when unknown. */
  codec: string | null;
  frameRate: number | null;
  hasAudio: boolean;
}

export async function probeVideo(file: Blob): Promise<VideoProbe> {
  try {
    return await probeWithMediabunny(file);
  } catch (error) {
    if (typeof document === "undefined") throw error;
    return probeWithVideoElement(file);
  }
}

/** Opens a mediabunny Input over a Blob. Callers dispose it. */
export function openInput(file: Blob): Input<BlobSource> {
  return new Input({ formats: ALL_FORMATS, source: new BlobSource(file) });
}

async function probeWithMediabunny(file: Blob): Promise<VideoProbe> {
  const input = openInput(file);
  try {
    const video = await input.getPrimaryVideoTrack();
    if (!video) throw new Error("The file has no video track.");
    const [rotation, codec, audio, mimeType] = await Promise.all([video.getRotation(), video.getCodec(), input.getPrimaryAudioTrack(), input.getMimeType()]);
    const duration = (await input.getDurationFromMetadata()) ?? (await input.computeDuration());
    let frameRate: number | null = null;
    try {
      const stats = await video.computePacketStats(120);
      frameRate = Number.isFinite(stats.averagePacketRate) && stats.averagePacketRate > 0 ? stats.averagePacketRate : null;
    } catch { /* corrupt index; frame rate stays unknown */ }
    return {
      duration: Number.isFinite(duration) && duration > 0 ? duration : 0,
      width: await video.getDisplayWidth(),
      height: await video.getDisplayHeight(),
      rotation,
      mimeType: mimeType || file.type,
      codec,
      frameRate,
      hasAudio: audio !== null,
    };
  } finally {
    input.dispose();
  }
}

function probeWithVideoElement(file: Blob): Promise<VideoProbe> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";
    video.muted = true;
    const done = () => { URL.revokeObjectURL(url); video.removeAttribute("src"); video.load(); };
    video.onloadedmetadata = () => {
      const v = video as HTMLVideoElement & { mozHasAudio?: boolean; webkitAudioDecodedByteCount?: number; audioTracks?: { length: number } };
      const hasAudio = v.mozHasAudio === true || (v.webkitAudioDecodedByteCount ?? 0) > 0 || (v.audioTracks?.length ?? 0) > 0;
      const probe: VideoProbe = { duration: Number.isFinite(video.duration) ? video.duration : 0, width: video.videoWidth, height: video.videoHeight, rotation: 0, mimeType: file.type, codec: null, frameRate: null, hasAudio };
      done();
      resolve(probe);
    };
    video.onerror = () => { done(); reject(new Error("The browser could not read this video.")); };
    video.src = url;
  });
}
