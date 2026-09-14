import SwiftUI

struct EditorPanelDivider: View {
    let title: String
    var vertical = false
    let value: CGFloat
    let limits: ClosedRange<CGFloat>
    let change: (CGFloat) -> Void
    @State private var origin: CGFloat?

    var body: some View {
        Capsule()
            .fill(.white.opacity(origin == nil ? 0.28 : 0.55))
            .frame(width: vertical ? 4 : 36, height: vertical ? 36 : 4)
        .frame(width: vertical ? 24 : nil, height: vertical ? nil : 20)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .background(Theme.inkPanel)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { gesture in
            if origin == nil { origin = value; UISelectionFeedbackGenerator().selectionChanged() }
            let translation = vertical ? gesture.translation.width : gesture.translation.height
            let next = min(limits.upperBound, max(limits.lowerBound, (origin ?? value) - translation))
            if abs(next - value) >= 0.5 {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { change(next) }
            }
        }.onEnded { _ in origin = nil })
        .accessibilityElement()
        .accessibilityLabel("Resize \(title.lowercased())")
        .accessibilityValue("\(Int(value)) points")
        .accessibilityHint("Drag to resize. Adjust up or down to change panel size.")
        .accessibilityAdjustableAction { direction in
            change(min(limits.upperBound, max(limits.lowerBound, value + (direction == .increment ? 40 : -40))))
        }
        .accessibilityIdentifier("resize-\(title.lowercased())")
    }
}

struct EditorActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 34)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(prominent ? Theme.signal : .white.opacity(configuration.isPressed ? 0.20 : 0.08), in: .rect(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.32)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct EditorRangeDraft: Equatable {
    let eventID: TimelineEventID?
    let start: Double
    let end: Double
}

@MainActor @Observable
final class EditorTimelineFeedback {
    var visibleSeconds: Double?
    var draft: EditorRangeDraft?
}

struct EditorRangeLabel: View {
    let feedback: EditorTimelineFeedback
    let eventID: TimelineEventID?
    let start: Double
    let end: Double
    var body: some View {
        let draft = feedback.draft.flatMap { $0.eventID == eventID ? $0 : nil }
        Text("\(timelineTimecode(draft?.start ?? start, includesTenths: true)) – \(timelineTimecode(draft?.end ?? end, includesTenths: true))")
            .monospacedDigit().contentTransition(.numericText())
    }
}
