import type { Point } from "./geometry";

/* OWNER: analysis agent. Ports of AnnotationTextLayout.swift, AnnotationLineStyle.swift and
   AnnotationLoupe.swift style records. Field names match the Swift `Codable` keys. */

export type AnnotationTextAlignment = "left" | "center" | "right";
export type AnnotationTextWeight = "regular" | "bold";

export interface AnnotationTextStyle {
  alignment: AnnotationTextAlignment;
  /** Font size as a fraction of source display width; identical at export scale. */
  size: number;
  weight: AnnotationTextWeight;
  background: boolean;
}
export const DEFAULT_TEXT_STYLE: AnnotationTextStyle = { alignment: "left", size: 0.036, weight: "bold", background: false };
export const textStyle = (overrides: Partial<AnnotationTextStyle> = {}): AnnotationTextStyle => ({ ...DEFAULT_TEXT_STYLE, ...overrides });

export type AnnotationLinePattern = "solid" | "dashed" | "dotted";
export const LINE_PATTERNS: readonly AnnotationLinePattern[] = ["solid", "dashed", "dotted"];
export type AnnotationEndpoint = "none" | "arrow" | "circle" | "point";
export const LINE_ENDPOINTS: readonly AnnotationEndpoint[] = ["none", "arrow", "circle", "point"];

/** Presentation-only line styling. Undefined on old annotations means the legacy solid stroke. */
export interface AnnotationLineStyle {
  pattern: AnnotationLinePattern;
  start: AnnotationEndpoint;
  end: AnnotationEndpoint;
}
export const DEFAULT_LINE_STYLE: AnnotationLineStyle = { pattern: "solid", start: "none", end: "none" };
export const LEGACY_ARROW_STYLE: AnnotationLineStyle = { pattern: "solid", start: "none", end: "arrow" };
export const CONNECTION_LINE_STYLE: AnnotationLineStyle = { pattern: "solid", start: "circle", end: "circle" };

/** Dash pattern in CSS pixels for a stroke of `width` pixels (port of `dashLengths(for:)`). */
export function dashLengths(style: AnnotationLineStyle, width: number): number[] {
  switch (style.pattern) {
    case "solid": return [];
    case "dashed": return [Math.max(4, width * 5), Math.max(3, width * 3.5)];
    case "dotted": return [Math.max(1, width * 0.8), Math.max(3, width * 3)];
  }
}

/** A fixed-size circular detail view attached to an annotation's tracked point. */
export interface AnnotationLoupeStyle {
  magnification: number;
  /** Lens diameter as a fraction of the source display-frame width. */
  diameter: number;
  /** Lens centre offset from the tracked point, in source-frame fractions. */
  offset: Point;
}
export const DEFAULT_LOUPE_STYLE: AnnotationLoupeStyle = { magnification: 2, diameter: 0.22, offset: { x: 0, y: -0.18 } };
export const loupeStyle = (overrides: Partial<AnnotationLoupeStyle> = {}): AnnotationLoupeStyle => ({ ...DEFAULT_LOUPE_STYLE, ...overrides });
