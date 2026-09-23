import SwiftUI

/// Drawing tools live behind one toolbar button so the workspace keeps its
/// bottom row for the selected layer, player or running pass.
struct AnalysisToolPickerSheet: View {
    let tool: AnalysisDrawingTool
    let fieldPreview: Bool
    let hasField: Bool
    let choose: (AnalysisDrawingTool) -> Void
    let measure: () -> Void
    let field: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(AnalysisDrawingTool.toolbarTools) { item in
                            Button { choose(item); dismiss() } label: {
                                Label(item.title, systemImage: item.symbol).frame(maxWidth: .infinity)
                            }.buttonStyle(EditorActionStyle(prominent: tool == item)).frame(height: 48)
                                .accessibilityIdentifier("analysis-tool-\(item.rawValue)")
                        }
                    }
                    Text("Setup").font(.caption.bold()).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        Button { dismiss(); measure() } label: {
                            Label("Measure", systemImage: "ruler").frame(maxWidth: .infinity)
                        }.buttonStyle(EditorActionStyle()).frame(height: 48)
                            .accessibilityLabel("Measurements").accessibilityIdentifier("analysis-tool-measure")
                        Button { dismiss(); field() } label: {
                            Label("Field", systemImage: fieldPreview ? "sportscourt.fill" : "sportscourt").frame(maxWidth: .infinity)
                        }.buttonStyle(EditorActionStyle(prominent: fieldPreview)).frame(height: 48)
                            .accessibilityLabel(!hasField ? "Set up field preview" : fieldPreview ? "Hide field preview" : "Show field preview")
                            .accessibilityIdentifier("analysis-tool-field-preview")
                    }
                }.padding(16)
            }
            .accessibilityIdentifier("analysis-drawing-tools")
            .navigationTitle("Tools").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }
}
