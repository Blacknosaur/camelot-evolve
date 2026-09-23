import type { Point } from "@/domain/geometry";
import type { GroundCalibration } from "@/domain/ground";
import * as projection from "@/features/analysis/field/projection";

/* Ground calibration as the renderer and editing model need it. The geometry itself belongs to the
   vision agent (`@/features/analysis/field/projection`, port of GroundCalibration.swift,
   GroundEffectProjection.swift and AnalysisFieldGuide); this module only adapts names and nullability. */

export type GroundEffectProjection = projection.GroundEffectProjection;

export const groundValid = projection.calibrationIsValid;
export const groundIsApproximate = projection.calibrationIsApproximate;
export const worldPoint = projection.worldPoint;
export const imagePoint = projection.imagePoint;
export const groundDistance = projection.groundDistance;
export const groundSpeed = projection.groundSpeed;
export const groundCircle = projection.groundCircle;
export const frozenGround = projection.frozenCalibration;
export const fieldGuidePolylines = projection.fieldGuidePolylines;

/** A valid four-point plane; the only calibration that can define perspective. */
export const hasPlane = (g: GroundCalibration | null | undefined): g is GroundCalibration => !!g && g.mode === "plane" && projection.calibrationIsValid(g);

export const groundEffectProjection = (ground: GroundCalibration | null | undefined, time: number): GroundEffectProjection | null =>
  hasPlane(ground) ? projection.groundEffectProjection(ground, time) : null;

/** Image point on the floor raised by `meters`, or null when the extrusion is unstable. */
export const raisedPoint = (effect: GroundEffectProjection, image: Point, meters: number): Point | null => effect.raised(image, meters);
