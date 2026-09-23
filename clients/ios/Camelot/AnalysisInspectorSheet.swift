import SwiftUI

/// Style for the selected drawing: how it looks, then when it shows. One
/// scrolling page instead of tabs, so nothing is hidden behind a mode.
struct AnalysisInspectorSheet<Style: View, Timing: View>: View {
    let title: String
    @ViewBuilder let style: () -> Style
    @ViewBuilder let timing: () -> Timing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AnalysisSheetHeader(title: title, action: { dismiss() })
                Form {
                    style()
                    timing()
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
