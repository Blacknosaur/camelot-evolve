/* Port of CameraZoomModel.swift. Log spacing gives wide-angle and telephoto zoom the same precision
   per movement. The web dial is an arc: equal angles mean equal zoom ratios. */

export interface ZoomScale { minimum: number; maximum: number; lensFactors: number[] }

export const clampZoom = (scale: ZoomScale, value: number) => Math.min(scale.maximum, Math.max(scale.minimum, value));

/** Sorted, clamped and de-duplicated (values within 4% collapse to the first one). */
export function mergeStops(values: number[], minimum: number, maximum: number): number[] {
  const result: number[] = [];
  for (const value of [...values].sort((a, b) => a - b)) {
    if (value < minimum - 0.001 || value > maximum + 0.001) continue;
    const clamped = Math.min(maximum, Math.max(minimum, value));
    const last = result.at(-1);
    if (last != null && Math.abs(Math.log(clamped / last)) < 0.04) continue;
    result.push(clamped);
  }
  return result;
}

/** Camera.app-style pill row: the minimum when it starts below 1×, 1×, each lens, and a 2× crop
 *  stop unless a lens already sits at or just above 2×. A single-lens camera gets 1× and 2×. */
export function zoomPills(scale: ZoomScale): number[] {
  const candidates = [1, ...scale.lensFactors];
  if (scale.minimum < 0.95) candidates.push(scale.minimum);
  const hasLensNearTwo = scale.lensFactors.some((f) => f > 1.05 && f <= 2.5);
  if (!hasLensNearTwo && scale.maximum >= 2) candidates.push(2);
  return mergeStops(candidates, scale.minimum, scale.maximum);
}

/** Labelled stops on the dial: the lens stops plus the round factors in range. */
export const dialStops = (scale: ZoomScale) => mergeStops([0.5, 1, 2, 3, 4, 5, 6, ...scale.lensFactors], scale.minimum, scale.maximum);

/** The pill that owns the live factor: the largest stop not above the value. */
export function selectedPill(value: number, pills: number[]): number | null {
  return [...pills].reverse().find((p) => p <= value * 1.001) ?? pills[0] ?? null;
}

export function formatZoom(value: number, decimals: number): string {
  return value.toFixed(decimals);
}

/** Text on a pill: the live value on the selected pill, the stop on the others. */
export function pillLabel(stop: number, value: number, isSelected: boolean): string {
  if (isSelected) return `${formatZoom(value, 1)}×`;
  return formatZoom(stop, Number.isInteger(stop) ? 0 : 1);
}

export interface DialTick { zoom: number; /** Degrees from the pointer; negative is wider. */ angle: number; isStop: boolean }

/** Arc dial geometry. The pointer stays at the top; ticks swing under it as the value changes. */
export interface ArcDial {
  scale: ZoomScale;
  /** Degrees of arc per zoom doubling. */
  degreesPerOctave: number;
  /** Half of the visible arc, in degrees. */
  halfSweep: number;
  /** Pixels of horizontal drag per doubling. */
  pixelsPerOctave: number;
  /** Tick every tenth of an octave ≈ 7% zoom. */
  tickOctaves: number;
}

export const defaultArcDial = (scale: ZoomScale): ArcDial => ({ scale, degreesPerOctave: 48, halfSweep: 70, pixelsPerOctave: 120, tickOctaves: 0.1 });

const log2 = (v: number) => Math.log2(Math.max(v, 0.01));

/** Angle of `zoom` from the pointer while the dial is centred on `value`. */
export const dialAngle = (dial: ArcDial, zoom: number, value: number) => (log2(zoom) - log2(value)) * dial.degreesPerOctave;

/** Dragging right (positive translation) moves the ticks right, so the value falls. */
export const dialValue = (dial: ArcDial, start: number, translation: number) => clampZoom(dial.scale, start * Math.pow(2, -translation / dial.pixelsPerOctave));

/** Visible ticks for a dial centred on `value`, sorted from wide to tight. */
export function dialTicks(dial: ArcDial, value: number): DialTick[] {
  const { scale, tickOctaves, halfSweep } = dial;
  const stops = dialStops(scale);
  const ticks: DialTick[] = [];
  const low = Math.floor(log2(scale.minimum) / tickOctaves), high = Math.ceil(log2(Math.max(scale.minimum, scale.maximum)) / tickOctaves);
  for (let index = low; index <= high; index += 1) {
    const zoom = Math.pow(2, index * tickOctaves);
    if (zoom < scale.minimum * 0.999 || zoom > scale.maximum * 1.001) continue;
    const angle = dialAngle(dial, zoom, value);
    if (Math.abs(angle) > halfSweep) continue;
    if (stops.some((s) => Math.abs(Math.log(zoom / s)) < 0.02)) continue;
    ticks.push({ zoom, angle, isStop: false });
  }
  for (const stop of stops) {
    const angle = dialAngle(dial, stop, value);
    if (Math.abs(angle) <= halfSweep) ticks.push({ zoom: stop, angle, isStop: true });
  }
  return ticks.sort((a, b) => a.angle - b.angle);
}

/** The stop crossed between two values, for haptics. `null` when no stop lies between them. */
export function crossedStop(previous: number, current: number, stops: number[]): number | null {
  const low = Math.min(previous, current), high = Math.max(previous, current);
  return stops.find((s) => s > low * 0.999 && s <= high * 1.001 && Math.abs(Math.log(s / previous)) > 0.001) ?? null;
}

/** Snap a value within 2% of a stop onto it so a release lands on the lens. */
export function snapZoom(value: number, stops: number[], tolerance = 0.02): number {
  return stops.find((s) => Math.abs(Math.log(value / s)) < tolerance) ?? value;
}

/** Keyboard / accessibility step: one notch is a 10% change. */
export const stepZoom = (scale: ZoomScale, value: number, direction: 1 | -1) => clampZoom(scale, direction > 0 ? value * 1.1 : value / 1.1);

/** Cartesian point on an arc of `radius` around (cx, cy) at `angle` degrees from straight up. */
export function arcPoint(cx: number, cy: number, radius: number, angle: number): { x: number; y: number } {
  const rad = ((angle - 90) * Math.PI) / 180;
  return { x: cx + radius * Math.cos(rad), y: cy + radius * Math.sin(rad) };
}
