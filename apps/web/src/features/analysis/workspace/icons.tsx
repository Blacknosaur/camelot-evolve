import type { SVGProps } from "react";
import type { AnalysisDrawingTool } from "@/domain/annotation";
import { Icon } from "@/design/icons";
import { toolRegistry } from "../render/toolRegistry";

/* Tool glyphs mirroring the SF Symbols the iOS toolbar uses. Keyed by the registry's `icon` field. */
const base = (props: SVGProps<SVGSVGElement>) => ({ width: 20, height: 20, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, ...props });

export const AnalysisIcon = {
  cursor: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M5 3l14 8-6 2-3 6z" /></svg>,
  figure: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="12" cy="4.5" r="2" /><path d="M9 9h6l-1 6h-4zM10 15l-2 6M14 15l2 6M9 9l-3 3M15 9l3 3" /></svg>,
  beacon: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M9 14l3-10 3 10zM5 20h14M12 14v6" /></svg>,
  pencil: Icon.Pencil,
  arrow: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M5 19L19 5M10 5h9v9" /></svg>,
  line: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M5 19L19 5" /></svg>,
  circle: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="12" cy="12" r="8" /></svg>,
  rectangle: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="4" y="6" width="16" height="12" rx="1.5" /></svg>,
  pentagon: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 3l9 6.5-3.5 10.5h-11L3 9.5z" /></svg>,
  text: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M5 6h14M12 6v13M8 19h8" /></svg>,
  connect: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="5" cy="18" r="2" /><circle cx="12" cy="6" r="2" /><circle cx="19" cy="18" r="2" /><path d="M6.5 16.5L10.5 7.5M13.5 7.5l4 9M7 18h10" strokeDasharray="2 2" /></svg>,
  loupe: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="11" cy="11" r="6" /><path d="M15.5 15.5L20 20" /><circle cx="11" cy="11" r="2" /></svg>,
  zoom: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="11" cy="11" r="6" /><path d="M15.5 15.5L20 20M11 8v6M8 11h6" /></svg>,
  trail: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 5c0 8 5 3 8 8s8 0 8 6" strokeDasharray="3 3" /><circle cx="4" cy="5" r="1.5" fill="currentColor" /><circle cx="20" cy="19" r="1.5" fill="currentColor" /></svg>,
  ruler: Icon.Ruler,
  field: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="3" y="5" width="18" height="14" rx="1" /><path d="M12 5v14M3 9h3v6H3M21 9h-3v6h3" /><circle cx="12" cy="12" r="2" /></svg>,
  sliders: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 7h10M18 7h2M4 12h3M11 12h9M4 17h12M20 17h0" /><circle cx="16" cy="7" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="18" cy="17" r="2" /></svg>,
  run: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="14" cy="4.5" r="2" /><path d="M6 21l4-6 3 2 2-5-3-2-4 3M13 12l4 2 2 5" /></svg>,
  tracks: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M7 9h10M7 12h6M7 15h8" /></svg>,
  diamond: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)} fill="currentColor" stroke="none"><path d="M12 3l8 9-8 9-8-9z" /></svg>,
  move: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3M21 12l-3-3M21 12l-3 3" /></svg>,
  fit: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 10V4h6M20 14v6h-6M4 4l6 6M20 20l-6-6" /></svg>,
  stepBack: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)} fill="currentColor" stroke="none"><path d="M7 5h2v14H7zM18 6v12l-8-6z" /></svg>,
  stepForward: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)} fill="currentColor" stroke="none"><path d="M15 5h2v14h-2zM6 6v12l8-6z" /></svg>,
  lock: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="5" y="11" width="14" height="10" rx="2" /><path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg>,
  eye: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z" /><circle cx="12" cy="12" r="3" /></svg>,
  duplicate: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2M14 11v6M11 14h6" /></svg>,
  camera: Icon.Video,
  link: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M10 14a4 4 0 0 1 0-6l2-2a4 4 0 0 1 6 6l-1 1M14 10a4 4 0 0 1 0 6l-2 2a4 4 0 0 1-6-6l1-1" /></svg>,
  pin: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11z" /><circle cx="12" cy="10" r="2" /></svg>,
  scope: Icon.Scope,
  person2: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="9" cy="8" r="3" /><circle cx="17" cy="9" r="2.5" /><path d="M3 20a6 6 0 0 1 12 0M14 20a4.5 4.5 0 0 1 7 0" /></svg>,
  personPlus: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="10" cy="8" r="3.5" /><path d="M3 20a7 7 0 0 1 14 0M19 8v6M16 11h6" /></svg>,
  people: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="6" cy="8" r="2.5" /><circle cx="12" cy="7" r="2.5" /><circle cx="18" cy="8" r="2.5" /><path d="M2 20a4 4 0 0 1 8 0M8 19a4 4 0 0 1 8 0M14 20a4 4 0 0 1 8 0" /></svg>,
  sparkles: Icon.Sparkles,
  play: Icon.Play, pause: Icon.Pause, back: Icon.ChevronLeft, check: Icon.Check, more: Icon.More, trash: Icon.Trash, undo: Icon.Undo, redo: Icon.Redo, plus: Icon.Plus, close: Icon.Close, warning: Icon.Warning,
};

export type AnalysisIconName = keyof typeof AnalysisIcon;

export function ToolIcon({ tool, ...props }: { tool: AnalysisDrawingTool } & SVGProps<SVGSVGElement>) {
  const Glyph = AnalysisIcon[toolRegistry[tool].icon as AnalysisIconName] ?? AnalysisIcon.cursor;
  return <Glyph {...props} />;
}
