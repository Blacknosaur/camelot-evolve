import { describe, expect, it } from "vitest";
import { byteCount, compactDuration, friendlyDate, preciseDuration } from "./format";

describe("compactDuration", () => {
  it("formats minutes and hours", () => {
    expect(compactDuration(0)).toBe("0:00");
    expect(compactDuration(65)).toBe("1:05");
    expect(compactDuration(3723)).toBe("1:02:03");
    expect(compactDuration(Number.NaN)).toBe("0:00");
    expect(compactDuration(-5)).toBe("0:00");
  });
  it("adds tenths for precise timecodes", () => {
    expect(preciseDuration(65.37)).toBe("1:05.3");
  });
});

describe("byteCount", () => {
  it("uses decimal units with one decimal under 10", () => {
    expect(byteCount(999)).toBe("999 bytes");
    expect(byteCount(1500)).toBe("1.5 KB");
    expect(byteCount(25_000_000)).toBe("25 MB");
    expect(byteCount(3_400_000_000)).toBe("3.4 GB");
  });
});

describe("friendlyDate", () => {
  const now = new Date(2026, 8, 17, 12, 0);
  it("names today, yesterday and tomorrow", () => {
    expect(friendlyDate(new Date(2026, 8, 17, 14, 30), now)).toMatch(/^Today, /);
    expect(friendlyDate(new Date(2026, 8, 16, 23, 59), now)).toMatch(/^Yesterday, /);
    expect(friendlyDate(new Date(2026, 8, 18, 0, 1), now)).toMatch(/^Tomorrow, /);
  });
  it("falls back to an absolute date", () => {
    const text = friendlyDate(new Date(2026, 0, 5, 9, 7), now);
    expect(text).not.toMatch(/^(Today|Yesterday|Tomorrow)/);
    expect(text).toContain("2026");
  });
});
