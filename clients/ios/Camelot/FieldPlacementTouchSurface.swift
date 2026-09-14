import SwiftUI

/// UIKit supplies the actual touch count, so SwiftUI's single-finger drag cannot
/// compete with a simultaneous pinch. No gesture changes annotation persistence.
struct FieldPlacementTouchSurface: UIViewRepresentable {
    var label = "Field placement image"
    var hint = "One finger places a corner. Two fingers pan and pinch to zoom."
    var identifier = "field-placement-touch-surface"
    let action: (FieldPlacementTouchState.Action) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.action = action
        view.accessibilityLabel = label; view.accessibilityHint = hint
        view.accessibilityIdentifier = identifier
    }

    final class Surface: UIView {
        var action: ((FieldPlacementTouchState.Action) -> Void)?
        private var touches: [UITouch] = []
        private var interaction = FieldPlacementTouchState()

        init() {
            super.init(frame: .zero)
            isMultipleTouchEnabled = true; backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = "Field placement image"
            accessibilityHint = "One finger places a corner. Two fingers pan and pinch to zoom."
            accessibilityIdentifier = "field-placement-touch-surface"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func touchesBegan(_ added: Set<UITouch>, with event: UIEvent?) {
            touches.append(contentsOf: added); sendUpdate()
        }
        override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?) { sendUpdate() }
        override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
            // Preserve the final coordinate before ending a one-finger placement.
            if touches.count == 1 { sendUpdate() }
            touches.removeAll { ended.contains($0) }; sendUpdate()
        }
        override func touchesCancelled(_ cancelled: Set<UITouch>, with event: UIEvent?) {
            interaction.cancel().forEach { action?($0) }; touches = []
        }
        private func sendUpdate() {
            interaction.update(touches.map { $0.location(in: self) }).forEach { action?($0) }
        }
    }
}
