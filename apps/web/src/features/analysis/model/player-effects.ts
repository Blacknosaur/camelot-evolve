import type { Rect } from "@/domain/geometry";
import { rectMaxX, rectMaxY, rectMidX, rectMidY } from "@/domain/geometry";
import type { CompositionClip } from "@/domain/records";
import type { UUID } from "@/domain/ids";
import { newId } from "@/domain/ids";
import type { AnalysisAnnotation, AnalysisDrawingTool, AnnotationColor, AnnotationEffect } from "@/domain/annotation";
import { DEFAULT_LOUPE_STYLE, textStyle, type AnnotationLoupeStyle, type AnnotationTextStyle } from "@/domain/annotation-styles";
import { DEFAULT_TRAJECTORY_STYLE, type PlayerMotion, type PlayerTrajectoryStyle } from "@/domain/tracking";
import { bound } from "@/features/analysis/tracking/motion";
import { newAnnotation, resolvedTextStyle } from "./annotation";
import { clipAnnotationEnd } from "@/domain/records";
import { cameraAt } from "@/features/analysis/tracking/library";

/* Port of AnalysisPlayerEffects.swift: one Player panel produces independent layers that share one
   source track. */

export interface PlayerEffectOptions {
  ring: boolean;
  spotlight: boolean;
  label: boolean;
  trajectory: boolean;
  loupe: boolean;
  loupeStyle: AnnotationLoupeStyle;
  trajectoryStyle: PlayerTrajectoryStyle;
  text: string;
  showsSpeed: boolean;
  textStyle: AnnotationTextStyle;
  ringStyle: AnnotationEffect;
  spotlightStyle: AnnotationEffect;
  color: AnnotationColor;
}

export function playerEffectOptions(layers: readonly AnalysisAnnotation[] = [], name = "Player"): PlayerEffectOptions {
  const options: PlayerEffectOptions = {
    ring: true, spotlight: false, label: false, trajectory: false, loupe: false,
    loupeStyle: DEFAULT_LOUPE_STYLE, trajectoryStyle: DEFAULT_TRAJECTORY_STYLE, text: name, showsSpeed: false,
    textStyle: textStyle({ alignment: "center" }), ringStyle: "radar", spotlightStyle: "neon", color: { red: 0.86, green: 1, blue: 0.15 },
  };
  if (layers.length === 0) return options;
  const find = (tool: AnalysisDrawingTool) => layers.find((l) => l.tool === tool);
  const text = find("text");
  return {
    ...options,
    ring: !!find("player"), spotlight: !!find("spotlight"), label: !!text, trajectory: !!find("trajectory"), loupe: !!find("loupe"),
    loupeStyle: find("loupe")?.loupeStyle ?? options.loupeStyle,
    trajectoryStyle: find("trajectory")?.trajectoryStyle ?? options.trajectoryStyle,
    ringStyle: find("player")?.effect ?? "radar", spotlightStyle: find("spotlight")?.effect ?? "neon",
    text: text?.text ?? name, showsSpeed: text?.showsSpeed === true,
    textStyle: text ? resolvedTextStyle(text) : options.textStyle,
    color: layers[0]?.color ?? options.color,
  };
}

export const playerEffectTools = (o: PlayerEffectOptions): AnalysisDrawingTool[] => [
  ...(o.trajectory ? ["trajectory" as const] : []), ...(o.ring ? ["player" as const] : []), ...(o.spotlight ? ["spotlight" as const] : []),
  ...(o.loupe ? ["loupe" as const] : []), ...(o.label ? ["text" as const] : []),
];

export function styleWithEffects(mark: AnalysisAnnotation, o: PlayerEffectOptions): AnalysisAnnotation {
  const result = { ...mark, color: o.color };
  switch (mark.tool) {
    case "player": result.effect = o.ringStyle; break;
    case "spotlight": result.effect = o.spotlightStyle; break;
    case "text": result.text = o.text; result.textStyle = o.textStyle; result.showsSpeed = o.showsSpeed; break;
    case "trajectory": result.trajectoryStyle = o.trajectoryStyle; result.effect = "clean"; break;
    case "loupe": result.loupeStyle = o.loupeStyle; break;
  }
  return result;
}

/** Port of `CompositionClip.applyPlayerEffects`: updates or creates one layer per chosen effect. */
export function applyPlayerEffects(clip: CompositionClip, options: PlayerEffectOptions, replacing: ReadonlySet<UUID>, box: Rect, motion: PlayerMotion | null, time: number): { clip: CompositionClip; selected: UUID | null } {
  const existing = clip.annotations.filter((a) => replacing.has(a.id));
  const groupID = existing.find((a) => a.playerEffectGroupID)?.playerEffectGroupID ?? newId();
  const tools = playerEffectTools(options);
  let annotations = clip.annotations.filter((a) => !(replacing.has(a.id) && a.isLocked !== true && !tools.includes(a.tool)));
  let selected: UUID | null = null;
  const annotationEnd = clipAnnotationEnd(clip);
  for (const tool of tools) {
    const matches = existing.filter((a) => a.tool === tool);
    if (matches.length > 0) {
      for (const match of matches) {
        annotations = annotations.map((a) => (a.id !== match.id || a.isLocked === true ? a : { ...styleWithEffects(a, options), playerEffectGroupID: groupID, playerEffectBox: box }));
        selected = match.id;
      }
      continue;
    }
    const points = tool === "text" ? [{ x: rectMidX(box), y: box.y - 0.02 }] : tool === "loupe" ? [{ x: rectMidX(box), y: rectMidY(box) }] : [{ x: box.x, y: box.y }, { x: rectMaxX(box), y: rectMaxY(box) }];
    let mark = styleWithEffects(newAnnotation(tool, points, Math.min(time, annotationEnd - 0.05), Math.min(annotationEnd, time + 6)), options);
    mark = { ...mark, playerEffectGroupID: groupID, playerEffectBox: box, playerMotion: motion ? bound(motion, time, tool === "text" ? 0.95 : undefined) ?? undefined : undefined };
    if (tool === "trajectory") mark.trajectoryCameraMotion = cameraAt(clip.trackingLibrary, time) ?? undefined;
    annotations = [...annotations, mark];
    selected = mark.id;
  }
  return { clip: { ...clip, annotations }, selected };
}
