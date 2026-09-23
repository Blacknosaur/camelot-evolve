import type { AnalysisDrawingTool } from "@/domain/annotation";
import { toolRegistry, toolbarTools } from "../render/toolRegistry";
import { AnalysisIcon, ToolIcon } from "./icons";
import { Sheet } from "./Sheet";

/* Drawing tools live behind one toolbar button so the workspace keeps its bottom row for the
   selected layer, player or running pass (port of AnalysisToolPickerSheet.swift). */
export function ToolPickerSheet({ tool, fieldPreview, hasField, choose, measure, field, onClose }: { tool: AnalysisDrawingTool; fieldPreview: boolean; hasField: boolean; choose(tool: AnalysisDrawingTool): void; measure(): void; field(): void; onClose(): void }) {
  return (
    <Sheet title="Tools" onClose={onClose}>
      <div className="an-grid" data-testid="analysis-drawing-tools" style={{ marginTop: 8 }}>
        {toolbarTools.map((item) => (
          <button key={item} type="button" className="an-grid-button" data-prominent={tool === item || undefined} data-testid={`analysis-tool-${item}`} onClick={() => { choose(item); onClose(); }} title={toolRegistry[item].shortcut ? `${toolRegistry[item].title} (${toolRegistry[item].shortcut!.toUpperCase()})` : toolRegistry[item].title}>
            <ToolIcon tool={item} />{toolRegistry[item].title}
          </button>
        ))}
      </div>
      <h3 style={{ margin: "18px 4px 8px", fontSize: 12, color: "var(--fg-secondary)" }}>Setup</h3>
      <div className="an-grid">
        <button type="button" className="an-grid-button" aria-label="Measurements" data-testid="analysis-tool-measure" onClick={() => { onClose(); measure(); }}><AnalysisIcon.ruler />Measure</button>
        <button type="button" className="an-grid-button" data-prominent={fieldPreview || undefined} data-testid="analysis-tool-field-preview" aria-label={!hasField ? "Set up field preview" : fieldPreview ? "Hide field preview" : "Show field preview"} onClick={() => { onClose(); field(); }}><AnalysisIcon.field />Field</button>
      </div>
    </Sheet>
  );
}
