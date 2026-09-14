import SwiftUI

struct AnalysisTextControls: View {
    @Binding var style: AnnotationTextStyle
    var sizeEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Alignment", selection: $style.alignment) {
                ForEach(AnnotationTextStyle.Alignment.allCases) { alignment in
                    Label(alignment.rawValue.capitalized, systemImage: "text.align\(alignment == .center ? "center" : alignment.rawValue)").tag(alignment)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("analysis-text-alignment")
            HStack {
                Text("Text size")
                Spacer()
                Text("\((style.size * 100).formatted(.number.precision(.fractionLength(1))))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(0.12, max(0.01, style.size)) }, set: { style.size = $0 }),
                   in: 0.01...0.12, onEditingChanged: sizeEditingChanged)
                .accessibilityLabel("Text size").accessibilityIdentifier("analysis-text-size")
            Picker("Weight", selection: $style.weight) {
                Text("Regular").tag(AnnotationTextStyle.Weight.regular)
                Text("Bold").tag(AnnotationTextStyle.Weight.bold)
            }.pickerStyle(.segmented).accessibilityIdentifier("analysis-text-weight")
            Toggle("Background", isOn: $style.background).accessibilityIdentifier("analysis-text-background")
        }.onDisappear { sizeEditingChanged(false) }
    }
}
