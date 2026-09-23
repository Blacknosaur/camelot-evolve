/* Replacement for Vision's VNTrackObjectRequest (VisionPlayerTracker.swift): a normalized-cross-correlation
   template tracker over a downscaled luma image with a small scale search and slow template adaptation.
   Boxes are fractions of the frame; `confidence` is the best NCC score clamped to 0…1. */
import type { Rect } from "@/domain/geometry";
import { rectMidX, rectMidY } from "./geometry";
import type { GrayImage } from "./camera-registration";

export interface OpticalObservation { box: Rect; confidence: number }

const TEMPLATE_W = 12, TEMPLATE_H = 24;
const SCALES = [0.92, 1, 1.08];

export class OpticalTracker {
  private template: Float32Array | null = null;
  private box: Rect;

  constructor(seed: Rect) { this.box = seed; }

  /** A fresh detector observation starts a new identity: the template is rebuilt on the next frame. */
  reseed(box: Rect): void { this.box = box; this.template = null; }

  /** Follows the seeded region in `gray`; null before a template exists (the seeding frame primes it). */
  track(gray: GrayImage): OpticalObservation | null {
    if (!this.template) { this.template = sampleTemplate(gray, this.box); return this.template ? { box: this.box, confidence: 1 } : null; }
    const template = this.template;
    const radiusX = Math.max(3, Math.round(this.box.width * gray.width * 0.6)), radiusY = Math.max(3, Math.round(this.box.height * gray.height * 0.35));
    const cx = rectMidX(this.box) * gray.width, cy = rectMidY(this.box) * gray.height;
    let best: { score: number; box: Rect } | null = null;
    for (const scale of SCALES) {
      const w = this.box.width * scale, h = this.box.height * scale;
      const step = Math.max(1, Math.round(Math.min(radiusX, radiusY) / 12));
      for (let dy = -radiusY; dy <= radiusY; dy += step) for (let dx = -radiusX; dx <= radiusX; dx += step) {
        const candidate: Rect = { x: (cx + dx) / gray.width - w / 2, y: (cy + dy) / gray.height - h / 2, width: w, height: h };
        const score = ncc(gray, candidate, template);
        if (score != null && (!best || score > best.score)) best = { score, box: candidate };
      }
    }
    if (!best) return null;
    // Refine to single-pixel precision around the coarse optimum.
    const coarse = best;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      const candidate: Rect = { ...coarse.box, x: coarse.box.x + dx / gray.width, y: coarse.box.y + dy / gray.height };
      const score = ncc(gray, candidate, template);
      if (score != null && score > best.score) best = { score, box: candidate };
    }
    this.box = best.box;
    const confidence = Math.max(0, Math.min(1, best.score));
    if (confidence > 0.6) {
      const fresh = sampleTemplate(gray, best.box);
      if (fresh) for (let i = 0; i < template.length; i++) template[i] = template[i]! * 0.9 + fresh[i]! * 0.1;
    }
    return { box: best.box, confidence };
  }

  finish(): void { this.template = null; }
}

function sampleTemplate(gray: GrayImage, box: Rect): Float32Array | null {
  const values = new Float32Array(TEMPLATE_W * TEMPLATE_H);
  let mean = 0;
  for (let ty = 0; ty < TEMPLATE_H; ty++) for (let tx = 0; tx < TEMPLATE_W; tx++) {
    const v = bilinear(gray, (box.x + ((tx + 0.5) / TEMPLATE_W) * box.width) * gray.width, (box.y + ((ty + 0.5) / TEMPLATE_H) * box.height) * gray.height);
    if (v == null) return null;
    values[ty * TEMPLATE_W + tx] = v; mean += v;
  }
  mean /= values.length;
  let norm = 0;
  for (let i = 0; i < values.length; i++) { values[i]! -= mean; norm += values[i]! * values[i]!; }
  if (norm < 1e-4) return null;
  norm = Math.sqrt(norm);
  for (let i = 0; i < values.length; i++) values[i]! /= norm;
  return values;
}

function ncc(gray: GrayImage, box: Rect, template: Float32Array): number | null {
  let sum = 0, squares = 0, product = 0;
  for (let ty = 0; ty < TEMPLATE_H; ty++) for (let tx = 0; tx < TEMPLATE_W; tx++) {
    const v = bilinear(gray, (box.x + ((tx + 0.5) / TEMPLATE_W) * box.width) * gray.width, (box.y + ((ty + 0.5) / TEMPLATE_H) * box.height) * gray.height);
    if (v == null) return null;
    sum += v; squares += v * v; product += template[ty * TEMPLATE_W + tx]! * v;
  }
  const n = template.length, variance = squares - (sum * sum) / n;
  return variance > 1e-4 ? product / Math.sqrt(variance) : null;
}

function bilinear(gray: GrayImage, x: number, y: number): number | null {
  const x0 = Math.floor(x), y0 = Math.floor(y);
  if (x0 < 0 || y0 < 0 || x0 + 1 >= gray.width || y0 + 1 >= gray.height) return null;
  const fx = x - x0, fy = y - y0, i = y0 * gray.width + x0, v = gray.values;
  return (v[i]! * (1 - fx) + v[i + 1]! * fx) * (1 - fy) + (v[i + gray.width]! * (1 - fx) + v[i + gray.width + 1]! * fx) * fy;
}
