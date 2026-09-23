/* Non-editable field guide over the analysis canvas: port of AnalysisFieldPreview.swift. Owns no calibration
   state; `frozenCalibration` decides whether the camera covers the playhead. */
import type { Rect } from "@/domain/geometry";
import type { GroundCalibration } from "@/domain/ground";
import { fieldPreviewGeometry } from "./overlay";

const path = (points: readonly { x: number; y: number }[]) => points.map((p, i) => `${i === 0 ? "M" : "L"}${p.x.toFixed(2)} ${p.y.toFixed(2)}`).join(" ");

/** SVG overlay in `bounds` pixel space; `frame` is where the video sits inside those bounds. */
export function AnalysisFieldPreview({ calibration, time, frame, bounds }: { calibration: GroundCalibration | undefined | null; time: number; frame: Rect; bounds: Rect }) {
  const geometry = fieldPreviewGeometry(calibration, time, frame);
  const clipId = `field-preview-clip-${Math.round(frame.x)}-${Math.round(frame.y)}`;
  return (
    <svg className="analysis-field-preview" width={bounds.width} height={bounds.height} viewBox={`${bounds.x} ${bounds.y} ${bounds.width} ${bounds.height}`} style={{ position: "absolute", inset: 0, pointerEvents: "none" }} aria-label="Field preview" role="img" data-testid="analysis-field-preview">
      <defs><clipPath id={clipId}><rect x={frame.x} y={frame.y} width={frame.width} height={frame.height} /></clipPath></defs>
      <g clipPath={`url(#${clipId})`} fill="none" strokeLinecap="round" strokeLinejoin="round">
        {geometry.referencePath.length > 1 && <path d={path(geometry.referencePath)} stroke="rgb(255 255 255 / 0.9)" strokeWidth={1.2} />}
        {geometry.calibratedPath.map((line, i) => <path key={i} d={path(line)} stroke="rgb(0 255 255 / 0.95)" strokeWidth={1.4} />)}
      </g>
      {geometry.status && (
        <foreignObject x={bounds.x + 8} y={bounds.y + 8} width={Math.max(1, bounds.width - 16)} height={40}>
          <div data-testid="analysis-field-preview-status" style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "6px 8px", borderRadius: 999, background: "rgb(0 0 0 / 0.72)", color: "#fff", font: "600 11px system-ui, sans-serif" }}>
            <span aria-hidden>⚠︀</span>{geometry.status}
          </div>
        </foreignObject>
      )}
    </svg>
  );
}
