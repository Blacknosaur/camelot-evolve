/** Formatting helpers shared by every surface (port of DesignSystem.swift). */

/** "1:02:03" or "4:05". */
export function compactDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainder = total % 60;
  const pad = (n: number) => n.toString().padStart(2, "0");
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(remainder)}` : `${minutes}:${pad(remainder)}`;
}

/** Timecode with tenths for editing surfaces: "4:05.3". */
export function preciseDuration(seconds: number): string {
  const safe = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const tenths = Math.floor((safe % 1) * 10);
  return `${compactDuration(safe)}.${tenths}`;
}

export function byteCount(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let index = 0;
  while (value >= 1000 && index < units.length - 1) { value /= 1000; index += 1; }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}`;
}

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const dateFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit" });

/** Relative or absolute date for list rows ("Today, 14:30" / "12 Sep 2026, 14:30"). */
export function friendlyDate(date: Date, now = new Date()): string {
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((startOf(date) - startOf(now)) / 86_400_000);
  if (days === 0) return `Today, ${timeFormat.format(date)}`;
  if (days === -1) return `Yesterday, ${timeFormat.format(date)}`;
  if (days === 1) return `Tomorrow, ${timeFormat.format(date)}`;
  return dateFormat.format(date);
}
