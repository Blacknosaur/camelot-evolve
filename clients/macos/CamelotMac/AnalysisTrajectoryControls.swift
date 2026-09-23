import SwiftUI

struct AnalysisTrajectoryControls: View {
    @Binding var style: PlayerTrajectoryStyle
    var body: some View {
        Stepper("Past: \(style.pastSeconds.formatted(.number.precision(.fractionLength(1))))s · solid", value: $style.pastSeconds, in: 0...10, step: 0.5)
            .accessibilityIdentifier("analysis-trajectory-past")
        Stepper("Future: \(style.futureSeconds.formatted(.number.precision(.fractionLength(1))))s · dashed", value: $style.futureSeconds, in: 0...10, step: 0.5)
            .accessibilityIdentifier("analysis-trajectory-future")
        ColorPicker("Future color", selection: Binding(get: {
            Color(red: style.futureColor.red, green: style.futureColor.green, blue: style.futureColor.blue)
        }, set: { value in
            let (r, g, b) = value.rgbComponents
            style.futureColor = .init(red: r, green: g, blue: b)
        }), supportsOpacity: false)
        Text("Set either duration to 0 to hide it. Future means confirmed movement later in this clip, not a prediction. Gaps are never joined.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
