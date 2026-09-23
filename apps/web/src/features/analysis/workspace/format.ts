/** "m:ss" or "m:ss.t" for timeline labels (port of `timelineTimecode`). */
export function formatTimecode(seconds: number, includesTenths = false): string {
  const safe = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const minutes = Math.floor(safe / 60), remainder = safe - minutes * 60;
  const whole = Math.floor(remainder), tenths = Math.floor((remainder - whole) * 10);
  const base = `${minutes}:${whole.toString().padStart(2, "0")}`;
  return includesTenths ? `${base}.${tenths}` : base;
}

export const seconds1 = (value: number) => `${value.toFixed(1)} s`;
export const percent1 = (value: number) => `${(value * 100).toFixed(1)}%`;
