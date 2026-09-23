import { useEffect, useRef, useState, type RefObject } from "react";

/** Describes the current container so screens can choose a portrait or landscape arrangement.
 *  Port of `LayoutMetrics` — decided by the actual size, which works on phones, tablets and desktop windows alike. */
export interface LayoutMetrics {
  width: number;
  height: number;
  isLandscape: boolean;
  /** Enough room for two columns. */
  isWide: boolean;
  /** Vertical space is scarce (phone landscape). */
  isShort: boolean;
  /** Pointer is coarse (touch) — larger targets, no hover affordances. */
  isTouch: boolean;
  gridColumns: number;
}

export function layoutMetrics(width: number, height: number, isTouch: boolean): LayoutMetrics {
  return {
    width,
    height,
    isLandscape: width > height,
    isWide: width >= 700,
    isShort: height < 500,
    isTouch,
    gridColumns: width >= 1100 ? 4 : width >= 760 ? 3 : width >= 520 ? 2 : 1,
  };
}

const coarsePointer = () => typeof matchMedia !== "undefined" && matchMedia("(pointer: coarse)").matches;

/** Measures an element once per resize and hands `LayoutMetrics` to its consumer. Port of `AdaptiveLayout`. */
export function useLayoutMetrics<T extends HTMLElement>(): [RefObject<T | null>, LayoutMetrics] {
  const ref = useRef<T>(null);
  const [metrics, setMetrics] = useState(() => layoutMetrics(typeof window === "undefined" ? 0 : window.innerWidth, typeof window === "undefined" ? 0 : window.innerHeight, coarsePointer()));
  useEffect(() => {
    const element = ref.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => {
      if (!entry) return;
      const { width, height } = entry.contentRect;
      setMetrics((previous) => (previous.width === width && previous.height === height ? previous : layoutMetrics(width, height, coarsePointer())));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return [ref, metrics];
}
