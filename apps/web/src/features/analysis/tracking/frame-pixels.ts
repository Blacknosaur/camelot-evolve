/* RGBA pixel buffers in display orientation. Frames decoded by `@/media/frame-source` are already
   rotated, so the iOS `bufferPoint(orientation:)` remap is the identity here. */
import type { Rect } from "@/domain/geometry";

export interface FramePixels {
  width: number;
  height: number;
  /** Tightly packed RGBA, `width * height * 4` bytes. */
  data: Uint8ClampedArray | Uint8Array;
  time: number;
}

export type RGB = [number, number, number];

/** Nearest-pixel colour (0…1 channels); null outside the frame. */
export function pixelColor(frame: FramePixels, fx: number, fy: number): RGB | null {
  const x = Math.floor(fx * frame.width), y = Math.floor(fy * frame.height);
  if (x < 0 || y < 0 || x >= frame.width || y >= frame.height) return null;
  const i = (y * frame.width + x) * 4;
  return [frame.data[i]! / 255, frame.data[i + 1]! / 255, frame.data[i + 2]! / 255];
}

/** Single-channel luma (0…1 floats) of the whole frame or a downscaled copy. */
export function toGray(frame: FramePixels, targetWidth = frame.width): { width: number; height: number; values: Float32Array } {
  const width = Math.min(targetWidth, frame.width);
  const height = Math.max(2, Math.round((frame.height * width) / frame.width));
  const values = new Float32Array(width * height);
  const sx = frame.width / width, sy = frame.height / height;
  for (let y = 0; y < height; y++) {
    // Box-average the source pixels covering each destination pixel for a cleaner downscale.
    const y0 = Math.floor(y * sy), y1 = Math.max(y0 + 1, Math.floor((y + 1) * sy));
    for (let x = 0; x < width; x++) {
      const x0 = Math.floor(x * sx), x1 = Math.max(x0 + 1, Math.floor((x + 1) * sx));
      let sum = 0, count = 0;
      for (let yy = y0; yy < y1 && yy < frame.height; yy++) for (let xx = x0; xx < x1 && xx < frame.width; xx++) {
        const i = (yy * frame.width + xx) * 4;
        sum += 0.299 * frame.data[i]! + 0.587 * frame.data[i + 1]! + 0.114 * frame.data[i + 2]!; count++;
      }
      values[y * width + x] = count ? sum / (255 * count) : 0;
    }
  }
  return { width, height, values };
}

/** Nearest-neighbour crop + resize of a normalized region into `w × h` RGBA. */
export function cropRegion(frame: FramePixels, region: Rect, w: number, h: number): FramePixels {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const sx = Math.min(frame.width - 1, Math.max(0, Math.floor((region.x + ((x + 0.5) / w) * region.width) * frame.width)));
    const sy = Math.min(frame.height - 1, Math.max(0, Math.floor((region.y + ((y + 0.5) / h) * region.height) * frame.height)));
    const si = (sy * frame.width + sx) * 4, di = (y * w + x) * 4;
    data[di] = frame.data[si]!; data[di + 1] = frame.data[si + 1]!; data[di + 2] = frame.data[si + 2]!; data[di + 3] = 255;
  }
  return { width: w, height: h, data, time: frame.time };
}

/** Converts a decoded VideoFrame into RGBA at most `maxEdge` pixels wide/tall. Worker-safe (OffscreenCanvas). */
export async function framePixels(frame: VideoFrame, time: number, maxEdge: number, canvas?: OffscreenCanvas): Promise<FramePixels> {
  const width = frame.displayWidth, height = frame.displayHeight;
  const scale = Math.min(1, maxEdge / Math.max(width, height));
  const w = Math.max(2, Math.floor((width * scale) / 2) * 2), h = Math.max(2, Math.floor((height * scale) / 2) * 2);
  const target = canvas ?? new OffscreenCanvas(w, h);
  if (target.width !== w || target.height !== h) { target.width = w; target.height = h; }
  const context = target.getContext("2d", { willReadFrequently: true });
  if (!context) throw new Error("2D canvas unavailable in worker");
  context.drawImage(frame, 0, 0, w, h);
  const image = context.getImageData(0, 0, w, h);
  return { width: w, height: h, data: image.data, time };
}
