import SwiftUI

/// One task at a time, with native form rows sized for a phone.
struct AnalysisInspectorSheet<Style: View, Timing: View, Layer: View>: View {
    let title: String
    let hasLayer: Bool
    @ViewBuilder let style: () -> Style
    @ViewBuilder let timing: () -> Timing
    @ViewBuilder let layer: () -> Layer
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.style

    private enum Tab: String, CaseIterable, Identifiable {
        case style = "Style", timing = "Timing", layer = "Layer"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AnalysisSheetHeader(title: title, action: { dismiss() })
                if hasLayer {
                    Picker("Layer settings", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 4)
                        .accessibilityIdentifier("analysis-inspector-tabs")
                }
                Form {
                    switch tab {
                    case .style: style()
                    case .timing: timing()
                    case .layer: layer()
                    }
                }.scrollContentBackground(.hidden)
                    .font(.subheadline)
                    .environment(\.defaultMinListRowHeight, 44)
                    .listSectionSpacing(.compact)
                    .accessibilityIdentifier("analysis-inspector-form")
            }.background(Theme.inkPanel)
                .toolbar(.hidden, for: .navigationBar)
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .preferredColorScheme(.dark).tint(Theme.signal)
    }
}
