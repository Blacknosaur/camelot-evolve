import SwiftUI

/// Compact visual controls retain separate, non-overlapping 44-point touch targets.
struct AnalysisControlSurface: ViewModifier {
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(minWidth: 32, minHeight: 30)
            .background(.white.opacity(pressed ? 0.18 : 0.07), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.10)) }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct AnalysisControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(AnalysisControlSurface(pressed: configuration.isPressed))
    }
}

struct AnalysisMotionControls: View {
    let selection: AnnotationMotionMode
    let allowsPlayer: Bool
    let showsCamera: Bool
    let select: (AnnotationMotionMode) -> Void

    private var modes: [AnnotationMotionMode] {
        [.still, .keyframes] + (allowsPlayer ? [.player] : []) + (showsCamera ? [.camera] : [])
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(modes, id: \.self) { mode in
                Button { select(mode) } label: {
                    Text(mode == .player && showsCamera ? "Player" : mode == .camera ? "Camera" : mode.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(mode == selection ? .black : .white)
                        .background(mode == selection ? Theme.signal : .white.opacity(0.07), in: .rect(cornerRadius: 6))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }.buttonStyle(.plain).accessibilityAddTraits(mode == selection ? [.isSelected] : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Layer motion")
            .accessibilityIdentifier("analysis-motion-mode")
    }
}
