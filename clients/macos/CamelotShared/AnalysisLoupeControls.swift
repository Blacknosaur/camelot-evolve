import SwiftUI

struct AnalysisLoupeControls: View {
    @Binding var style: AnnotationLoupeStyle
    var beginEdit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Magnification \(style.magnification.formatted(.number.precision(.fractionLength(1))))×").font(.caption)
            Slider(value: $style.magnification, in: 1.5...5, onEditingChanged: { if $0 { beginEdit() } })
                .accessibilityIdentifier("analysis-loupe-magnification")
            Text("Lens size").font(.caption)
            Slider(value: $style.diameter, in: 0.12...0.4, onEditingChanged: { if $0 { beginEdit() } })
                .accessibilityIdentifier("analysis-loupe-size")
            HStack {
                Text("Position").font(.caption)
                Spacer()
                ForEach(["Above", "Left", "Right"], id: \.self) { side in
                    Button(side) {
                        beginEdit()
                        style.offset = side == "Above" ? CGPoint(x: 0, y: -0.22) : CGPoint(x: side == "Left" ? -0.2 : 0.2, y: -0.08)
                    }.buttonStyle(AnalysisControlStyle())
                }
            }
            Text("Drag the focus on the video. Follow a saved player without tracking again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
