import type { SVGProps } from "react";
import { Icon } from "@/design/icons";

/* Editor-only glyphs that the shared set does not carry; kept here so design/icons.tsx stays owned by the design agent. */
const base = (props: SVGProps<SVGSVGElement>) => ({ width: 18, height: 18, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, ...props });

export const EditorIcon = {
  ZoomIn: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="11" cy="11" r="7" /><path d="M20 20l-4-4M8 11h6M11 8v6" /></svg>,
  ZoomOut: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="11" cy="11" r="7" /><path d="M20 20l-4-4M8 11h6" /></svg>,
  Fit: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M3 12h18M7 8l-4 4 4 4M17 8l4 4-4 4" /></svg>,
  Speed: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 16a8 8 0 0 1 16 0" /><path d="M12 16l4-6" /><circle cx="12" cy="16" r="1.5" fill="currentColor" /></svg>,
  Aspect: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M7 9v6M17 9v6" /></svg>,
  Split: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><rect x="3" y="6" width="18" height="12" rx="2" /><path d="M12 4v16" /></svg>,
  StepBack: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)} fill="currentColor" stroke="none"><rect x="5" y="5" width="3" height="14" rx="1" /><path d="M19 5l-9 7 9 7z" /></svg>,
  StepForward: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)} fill="currentColor" stroke="none"><rect x="16" y="5" width="3" height="14" rx="1" /><path d="M5 5l9 7-9 7z" /></svg>,
  Search: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><circle cx="11" cy="11" r="7" /><path d="M20 20l-4-4" /></svg>,
  Filter: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 7h16M7 12h10M10 17h4" /></svg>,
  Freeze: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 3v18M4 7l16 10M4 17L20 7" /></svg>,
  Repeat: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M17 2l4 4-4 4" /><path d="M3 11V9a4 4 0 0 1 4-4h14M7 22l-4-4 4-4" /><path d="M21 13v2a4 4 0 0 1-4 4H3" /></svg>,
  Sliders: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M4 8h10M18 8h2M4 16h4M12 16h8" /><circle cx="16" cy="8" r="2" /><circle cx="10" cy="16" r="2" /></svg>,
  Save: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 3v13M7 11l5 5 5-5" /><path d="M5 21h14" /></svg>,
  Layers: (p: SVGProps<SVGSVGElement>) => <svg {...base(p)}><path d="M12 3l9 5-9 5-9-5z" /><path d="M3 13l9 5 9-5" /></svg>,
};

export function eventKindIcon(kind: string, props: SVGProps<SVGSVGElement> = {}) {
  switch (kind) {
    case "Goal": return <Icon.Ball {...props} />;
    case "Shot": return <Icon.Scope {...props} />;
    case "Save": return <Icon.Hand {...props} />;
    case "Foul": return <Icon.Warning {...props} />;
    case "Card": return <Icon.CardIcon {...props} />;
    case "Note": return <Icon.Note {...props} />;
    default: return <Icon.Flag {...props} />;
  }
}
