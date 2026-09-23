/* Appearance identity: exact ports of PlayerJerseySignature, PlayerJerseyProfile (PlayerTrackingIdentity.swift),
   PlayerIdentityMemory, PlayerNumberVotes, PlayerObservation (PlayerRoster.swift) and
   PlayerAppearanceGallery (PlayerAppearanceGallery.swift). Persisted shapes live in @/domain/tracking. */
import type { Rect } from "@/domain/geometry";
import type { PlayerAppearanceGallery, PlayerIdentityMemory, PlayerJerseyProfile, PlayerJerseySignature, PlayerNumberVotes } from "@/domain/tracking";
import { overlap, rectsEqual } from "./geometry";
import { pixelColor, type FramePixels, type RGB } from "./frame-pixels";
export type { RGB };

// MARK: - Jersey signatures

/** Hue histogram (12 hue bins + 3 neutral brightness bins). Green is never discarded categorically. */
export function signatureFromColors(colors: readonly RGB[]): PlayerJerseySignature {
  const histogram = new Array<number>(15).fill(0);
  for (const [r, g, b] of colors) {
    const high = Math.max(r, g, b), low = Math.min(r, g, b);
    const delta = high - low, saturation = high > 0 ? delta / high : 0;
    if (saturation < 0.2 || high < 0.12) {
      const value = Math.min(2, Math.max(0, high * 2));
      const lower = Math.min(2, Math.floor(value)), upper = Math.min(2, lower + 1), fraction = value - lower;
      histogram[12 + lower]! += 1 - fraction; histogram[12 + upper]! += fraction;
    } else {
      let hue = high === r ? (g - b) / delta : high === g ? 2 + (b - r) / delta : 4 + (r - g) / delta;
      if (hue < 0) hue += 6;
      const bin = hue * 2, index = Math.floor(bin) % 12, fraction = bin - Math.floor(bin);
      histogram[index]! += 1 - fraction; histogram[(index + 1) % 12]! += fraction;
    }
  }
  return normalized(histogram);
}

/** Chromaticity distribution (5×5 soft bins over r and b shares 0.2–0.5), independent of brightness. */
export function signatureFromChroma(colors: readonly RGB[]): PlayerJerseySignature {
  const histogram = new Array<number>(25).fill(0);
  for (const [r, g, b] of colors) {
    const sum = Math.max(0.05, r + g + b);
    const rr = Math.min(3.999, Math.max(0, ((r / sum - 0.2) / 0.3) * 4)), bb = Math.min(3.999, Math.max(0, ((b / sum - 0.2) / 0.3) * 4));
    const r0 = Math.floor(rr), b0 = Math.floor(bb), fr = rr - r0, fb = bb - b0;
    histogram[r0 * 5 + b0]! += (1 - fr) * (1 - fb);
    histogram[(r0 + 1) * 5 + b0]! += fr * (1 - fb);
    histogram[r0 * 5 + b0 + 1]! += (1 - fr) * fb;
    histogram[(r0 + 1) * 5 + b0 + 1]! += fr * fb;
  }
  return normalized(histogram);
}

/** Brightness distribution (15 bins): skin, hair and socks differ in tone more than in hue. */
export function signatureFromBrightness(colors: readonly RGB[]): PlayerJerseySignature {
  const histogram = new Array<number>(15).fill(0);
  for (const [r, g, b] of colors) {
    const value = Math.min(14, Math.max(0, (0.299 * r + 0.587 * g + 0.114 * b) * 14));
    const lower = Math.min(14, Math.floor(value)), upper = Math.min(14, lower + 1), fraction = value - lower;
    histogram[lower]! += 1 - fraction; histogram[upper]! += fraction;
  }
  return normalized(histogram);
}

function normalized(histogram: number[]): PlayerJerseySignature {
  const total = Math.max(1, histogram.reduce((a, b) => a + b, 0));
  return { bins: histogram.map((v) => v / total) };
}

/** Bhattacharyya coefficient between two signatures. */
export function signatureSimilarity(a: PlayerJerseySignature, b: PlayerJerseySignature): number {
  if (a.bins.length !== b.bins.length || a.bins.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < a.bins.length; i++) sum += Math.sqrt(Math.max(0, a.bins[i]! * b.bins[i]!));
  return sum;
}

export type BodyZone = "torso" | "shorts" | "head" | "legs";
const ZONE_HORIZONTAL: Record<BodyZone, [offset: number, width: number]> = { torso: [0.28, 0.44], shorts: [0.28, 0.44], head: [0.34, 0.32], legs: [0.28, 0.44] };
const ZONE_VERTICAL: Record<BodyZone, [offset: number, height: number]> = { torso: [0.2, 0.28], shorts: [0.52, 0.16], head: [0.01, 0.13], legs: [0.72, 0.22] };

/** 12×10 grid of colours inside a body zone of a detector box. */
export function sampleColors(frame: FramePixels, box: Rect, zone: BodyZone = "torso"): RGB[] {
  if (!(box.width > 0) || !(box.height > 0)) return [];
  const [hOffset, hWidth] = ZONE_HORIZONTAL[zone], [vOffset, vHeight] = ZONE_VERTICAL[zone];
  const colors: RGB[] = [];
  for (let row = 0; row < 10; row++) for (let column = 0; column < 12; column++) {
    const color = pixelColor(frame, box.x + box.width * (hOffset + ((column + 0.5) * hWidth) / 12), box.y + box.height * (vOffset + ((row + 0.5) * vHeight) / 10));
    if (color) colors.push(color);
  }
  return colors;
}

export const sampleSignature = (frame: FramePixels, box: Rect, zone: BodyZone = "torso"): PlayerJerseySignature | null => {
  const colors = sampleColors(frame, box, zone);
  return colors.length >= 60 ? signatureFromColors(colors) : null;
};
export const sampleTone = (frame: FramePixels, box: Rect, zone: BodyZone): PlayerJerseySignature | null => {
  const colors = sampleColors(frame, box, zone);
  return colors.length >= 60 ? signatureFromBrightness(colors) : null;
};
export function meanColor(colors: readonly RGB[]): RGB | null {
  if (colors.length === 0) return null;
  const sum: RGB = [0, 0, 0];
  for (const c of colors) { sum[0] += c[0]; sum[1] += c[1]; sum[2] += c[2]; }
  return [sum[0] / colors.length, sum[1] / colors.length, sum[2] / colors.length];
}

// MARK: - Jersey profile

export const emptyProfile = (): PlayerJerseyProfile => ({ examples: [] });
export const profileIsConfirmed = (p: PlayerJerseyProfile) => p.examples.length >= 2;

/** Correct can replace a provisional seed, never a confirmed identity. */
export function resumingProfile(profile: PlayerJerseyProfile | undefined | null): PlayerJerseyProfile {
  if (profile && profileIsConfirmed(profile)) return { examples: profile.examples.slice() };
  return emptyProfile();
}

export function profileSimilarity(p: PlayerJerseyProfile, signature: PlayerJerseySignature): number {
  const anchor = p.examples[0];
  if (!anchor) return 0;
  const best = Math.max(...p.examples.map((e) => signatureSimilarity(e, signature)));
  return signatureSimilarity(anchor, signature) * 0.6 + best * 0.4;
}

/** Mutates `p`. Learns only clear examples that agree with the anchor; bounded to 8. */
export function profileLearn(p: PlayerJerseyProfile, signature: PlayerJerseySignature, clear: boolean): void {
  if (!clear) return;
  if (p.examples.length > 0 && profileSimilarity(p, signature) < 0.78) return;
  if (p.examples.length === 8) p.examples.splice(1, 1);
  p.examples.push(signature);
}

// MARK: - Shirt numbers

export const emptyVotes = (): PlayerNumberVotes => ({ counts: {} });
export const MINIMUM_NUMBER_VOTES = 3;
export const isShirtNumber = (text: string) => text.length >= 1 && text.length <= 2 && /^[0-9]+$/.test(text) && text !== "0" && text !== "00";
export const totalVotes = (v: PlayerNumberVotes) => Object.values(v.counts).reduce((a, b) => a + b, 0);
export function confirmedNumber(v: PlayerNumberVotes): string | null {
  let best: [string, number] | null = null;
  for (const [key, value] of Object.entries(v.counts)) {
    // Swift picks the max by count, ties broken by the smaller key.
    if (!best || value > best[1] || (value === best[1] && key < best[0])) best = [key, value];
  }
  if (!best || best[1] < MINIMUM_NUMBER_VOTES || best[1] < totalVotes(v) * 0.6) return null;
  return best[0];
}
export function voteNumber(v: PlayerNumberVotes, text: string): void {
  if (!isShirtNumber(text)) return;
  v.counts[text] = (v.counts[text] ?? 0) + 1;
}

// MARK: - Appearance gallery

export const GALLERY_CAPACITY = 8;
export const MINIMUM_BODY_HEIGHT = 0.08;
export const MINIMUM_GALLERY_REFERENCES = 3;
export const emptyGallery = (): PlayerAppearanceGallery => ({ prints: [], times: [] });
export const galleryIsReady = (g: PlayerAppearanceGallery) => g.prints.length >= MINIMUM_GALLERY_REFERENCES;

export function cosine(a: readonly number[], b: readonly number[]): number {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i]! * b[i]!; na += a[i]! * a[i]!; nb += b[i]! * b[i]!; }
  return na > 0 && nb > 0 ? dot / (Math.sqrt(na) * Math.sqrt(nb)) : 0;
}
export function galleryPrintSimilarity(g: PlayerAppearanceGallery, print: readonly number[]): number | null {
  if (g.prints.length === 0) return null;
  return Math.max(...g.prints.map((p) => cosine(p, print)));
}
/** Another body must look less like this player than the player looks like themself on a bad day. */
export function galleryGate(g: PlayerAppearanceGallery): number {
  if (g.prints.length < 2) return 0.7;
  let lowest = 1;
  for (let i = 0; i < g.prints.length; i++) for (let j = i + 1; j < g.prints.length; j++) lowest = Math.min(lowest, cosine(g.prints[i]!, g.prints[j]!));
  return Math.min(0.8, Math.max(0.5, lowest - 0.03));
}
export function galleryAdd(g: PlayerAppearanceGallery, print: readonly number[], time: number): void {
  if (print.length === 0) return;
  const rounded = print.map((v) => Math.round(v * 1000) / 1000);
  const last = g.times[g.times.length - 1];
  if (last != null && time - last < 0.4) return;
  if (g.prints.length < GALLERY_CAPACITY) { g.prints.push(rounded); g.times.push(time); return; }
  let closest = 1, best = -1;
  for (let index = 1; index < g.prints.length; index++) {
    const value = cosine(g.prints[index]!, rounded);
    if (value > best) { best = value; closest = index; }
  }
  g.prints[closest] = rounded; g.times[closest] = time;
}

// MARK: - Observations

/** Per-detection features of one frame. Not persisted. */
export interface PlayerObservation {
  box: Rect;
  jersey?: PlayerJerseySignature;
  shorts?: PlayerJerseySignature;
  kitColor?: RGB;
  number?: string;
  crowded: boolean;
  head?: PlayerJerseySignature;
  legs?: PlayerJerseySignature;
  chroma?: PlayerJerseySignature;
  print?: number[];
  time: number;
}

export const observation = (box: Rect, extra: Partial<PlayerObservation> = {}): PlayerObservation => ({ box, crowded: false, time: 0, ...extra });

/** Every appearance cue for one detector box; tone cues need a tall enough body. */
export function observe(frame: FramePixels, box: Rect, among: readonly Rect[]): PlayerObservation {
  const torso = sampleColors(frame, box, "torso"), shorts = sampleColors(frame, box, "shorts");
  const tall = box.height >= 0.06;
  return {
    box,
    jersey: torso.length >= 60 ? signatureFromColors(torso) : undefined,
    shorts: shorts.length >= 60 ? signatureFromColors(shorts) : undefined,
    kitColor: meanColor(torso) ?? undefined,
    crowded: among.some((r) => !rectsEqual(r, box) && overlap(r, box) > 0.25),
    head: tall ? sampleTone(frame, box, "head") ?? undefined : undefined,
    legs: tall ? sampleTone(frame, box, "legs") ?? undefined : undefined,
    chroma: torso.length >= 60 ? signatureFromChroma(torso) : undefined,
    time: frame.time,
  };
}

// MARK: - Identity memory

export const emptyMemory = (): PlayerIdentityMemory => ({ jersey: emptyProfile(), shorts: emptyProfile(), number: emptyVotes() });
export const memoryIsConfirmed = (m: PlayerIdentityMemory) => profileIsConfirmed(m.jersey);

export function cloneMemory(m: PlayerIdentityMemory): PlayerIdentityMemory {
  return JSON.parse(JSON.stringify(m)) as PlayerIdentityMemory;
}

/** A saved player keeps its confirmed identity; a provisional jersey may be replaced. */
export function resumingMemory(memory: PlayerIdentityMemory | undefined | null, jersey: PlayerJerseyProfile | undefined | null): PlayerIdentityMemory {
  const result = memory ? cloneMemory(memory) : emptyMemory();
  if (result.jersey.examples.length === 0 && jersey) result.jersey = { examples: jersey.examples.slice() };
  result.jersey = resumingProfile(result.jersey);
  if (!profileIsConfirmed(result.jersey)) { result.shorts = emptyProfile(); result.number = emptyVotes(); }
  return result;
}

export function chromaDistance(a: RGB, b: RGB): number {
  const sumA = Math.max(0.05, a[0] + a[1] + a[2]), sumB = Math.max(0.05, b[0] + b[1] + b[2]);
  return Math.max(Math.abs(a[0] / sumA - b[0] / sumB), Math.abs(a[1] / sumA - b[1] / sumB), Math.abs(a[2] / sumA - b[2] / sumB));
}

export function memoryConflicts(m: PlayerIdentityMemory, o: PlayerObservation): boolean {
  const mine = confirmedNumber(m.number);
  return mine != null && o.number != null && mine !== o.number;
}

/** Null when the torso could not be read. Cues combine as gates, not a soft average. */
export function memorySimilarity(m: PlayerIdentityMemory, o: PlayerObservation): number | null {
  const torso = o.jersey;
  if (!torso || m.jersey.examples.length === 0) return null;
  if (memoryConflicts(m, o)) return 0;
  let score = profileSimilarity(m.jersey, torso);
  if (o.box.height >= MINIMUM_BODY_HEIGHT && m.gallery && galleryIsReady(m.gallery) && o.print) {
    const likeness = galleryPrintSimilarity(m.gallery, o.print);
    if (likeness != null) {
      const gate = galleryGate(m.gallery);
      if (likeness < gate - 0.1) return 0;
      if (likeness < gate - 0.04) score *= 0.5;
      else if (likeness < gate) score *= 0.8;
      else if (m.gallery.prints.length >= 6 && likeness > gate + 0.1) score = Math.min(1, score + 0.04);
    }
  }
  if (m.chroma && profileIsConfirmed(m.chroma) && o.chroma) {
    const agreement = profileSimilarity(m.chroma, o.chroma);
    if (agreement < 0.5) return 0;
    if (agreement < 0.65) score *= 0.7;
  }
  if (o.shorts && m.shorts.examples.length > 0) score = score * 0.85 + Math.min(score, profileSimilarity(m.shorts, o.shorts)) * 0.15;
  for (const [profile, tone] of [[m.head, o.head], [m.legs, o.legs]] as const) {
    if (!profile || !profileIsConfirmed(profile) || !tone) continue;
    const agreement = profileSimilarity(profile, tone);
    if (agreement < 0.4) return 0;
    if (agreement < 0.55) score *= 0.6;
    else if (agreement < 0.7) score *= 0.85;
    else if (agreement > 0.88) score = Math.min(1, score + 0.03);
  }
  const mine = confirmedNumber(m.number);
  if (mine != null && o.number != null && mine === o.number) score = Math.min(1, score + 0.1);
  return score;
}

/** Mutates `m`. */
export function memoryLearn(m: PlayerIdentityMemory, o: PlayerObservation, clear: boolean): void {
  if (o.jersey) {
    const unknown = m.jersey.examples.length === 0;
    profileLearn(m.jersey, o.jersey, clear);
    if (m.jersey.examples.length > 0 && o.kitColor) {
      const color = o.kitColor;
      const mine = m.kitColor;
      if (unknown || !mine || mine.length !== 3) m.kitColor = [color[0], color[1], color[2]];
      else if (clear && chromaDistance([mine[0]!, mine[1]!, mine[2]!], color) < 0.06) {
        m.kitColor = [mine[0]! * 0.9 + color[0] * 0.1, mine[1]! * 0.9 + color[1] * 0.1, mine[2]! * 0.9 + color[2] * 0.1];
      }
    }
  }
  if (!clear || m.jersey.examples.length === 0) return;
  if (o.shorts) profileLearn(m.shorts, o.shorts, true);
  if (o.chroma) { const profile = m.chroma ?? emptyProfile(); profileLearn(profile, o.chroma, true); m.chroma = profile; }
  if (o.print && o.box.height >= MINIMUM_BODY_HEIGHT) { const gallery = m.gallery ?? emptyGallery(); galleryAdd(gallery, o.print, o.time); m.gallery = gallery; }
  if (o.head) { const profile = m.head ?? emptyProfile(); profileLearn(profile, o.head, true); m.head = profile; }
  if (o.legs) { const profile = m.legs ?? emptyProfile(); profileLearn(profile, o.legs, true); m.legs = profile; }
  if (o.number != null) voteNumber(m.number, o.number);
}
