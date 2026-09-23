import type { Point, Rect } from "./geometry";
import type { UUID } from "./ids";
import type { PlayerMotion, AnnotationCameraMotion, PlayerTrajectoryStyle } from "./tracking";
import type { AnalysisFieldLayout } from "./ground";
import type { AnnotationTextStyle, AnnotationLineStyle, AnnotationLoupeStyle } from "./annotation-styles";

/* Port of clients/ios/Camelot/AnalysisAnnotation.swift.
   OWNER: analysis agent. Motion/geometry helpers (`annotationPoints`, `annotationOpacity`, …)
   live in src/features/analysis/model/ and must stay pure so the export worker can reuse them. */

export type AnalysisDrawingTool =
  | "select" | "pen" | "arrow" | "line" | "ellipse" | "rectangle" | "zone" | "text"
  | "player" | "spotlight" | "connection" | "zoom" | "trajectory" | "loupe";

/** Spotlight remains a persisted layer kind, but is configured inside Player. */
export const TOOLBAR_TOOLS: readonly AnalysisDrawingTool[] = ["select", "player", "pen", "arrow", "line", "ellipse", "rectangle", "zone", "text", "connection", "loupe", "zoom"];

export function toolTitle(tool: AnalysisDrawingTool): string {
  switch (tool) {
    case "ellipse": return "Circle";
    case "player": return "Player";
    case "zone": return "Polygon";
    case "connection": return "Connect";
    default: return tool.charAt(0).toUpperCase() + tool.slice(1);
  }
}

export interface AnnotationColor { red: number; green: number; blue: number }
export const ANNOTATION_YELLOW: AnnotationColor = { red: 0.86, green: 1, blue: 0.15 };
export const annotationCss = (c: AnnotationColor, alpha = 1) => `rgb(${Math.round(c.red * 255)} ${Math.round(c.green * 255)} ${Math.round(c.blue * 255)} / ${alpha})`;

export interface AnnotationKeyframe { id: UUID; time: number; points: Point[] }

export type AnnotationEffect = "clean" | "neon" | "pulse" | "radar" | "wall" | "aerial";
export const PLAYER_EFFECT_STYLES: readonly AnnotationEffect[] = ["clean", "neon", "pulse", "radar"];

/** Coordinates are fractions of the source display frame. Times are source seconds
 *  (held-frame clips use startSeconds + elapsed time). Keyframes are baked so saved
 *  edits and exports never depend on a regenerable detection cache. */
export interface AnalysisAnnotation {
  id: UUID;
  tool: AnalysisDrawingTool;
  points: Point[];
  color: AnnotationColor;
  /** Stroke width as a fraction of the frame width. */
  width: number;
  text: string;
  textStyle?: AnnotationTextStyle;
  start: number;
  end: number;
  fade: boolean;
  keyframes: AnnotationKeyframe[];
  playerMotion?: PlayerMotion;
  /** Links options from the Player panel even on a still frame, without motion. */
  playerEffectGroupID?: UUID;
  playerEffectBox?: Rect;
  isHidden?: boolean;
  isLocked?: boolean;
  layerName?: string;
  effect?: AnnotationEffect;
  areaFill?: number;
  wallHeight?: number;
  grounded?: boolean;
  groundReferenceTime?: number;
  wallHeightMeters?: number;
  wallOpacity?: number;
  linkedPlayers?: PlayerMotion[];
  cameraMotion?: AnnotationCameraMotion;
  zoomScale?: number;
  zoomRamp?: number;
  fieldLines?: boolean;
  fieldLayout?: AnalysisFieldLayout;
  trajectoryStyle?: PlayerTrajectoryStyle;
  trajectoryCameraMotion?: AnnotationCameraMotion;
  showsSpeed?: boolean;
  showsDistance?: boolean;
  lineStyle?: AnnotationLineStyle;
  loupeStyle?: AnnotationLoupeStyle;
}

export function annotationTitle(a: AnalysisAnnotation): string {
  if (a.layerName && a.layerName.length > 0) return a.layerName;
  if (a.tool === "text" && a.text) return a.text;
  return toolTitle(a.tool);
}

export const GROUNDABLE_TOOLS: readonly AnalysisDrawingTool[] = ["player", "spotlight", "zone", "rectangle", "ellipse", "line", "arrow", "pen", "connection"];
export const supportsGrounding = (a: AnalysisAnnotation) => GROUNDABLE_TOOLS.includes(a.tool) && a.fieldLines !== true;
export const isGrounded = (a: AnalysisAnnotation, hasField: boolean) => a.grounded ?? (hasField && (a.tool === "player" || a.tool === "spotlight"));
