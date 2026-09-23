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
        /// The pointer gesture currently navigating, and the point it started from.
        private weak var pointerGesture: UIGestureRecognizer?
        private var pointerOrigin = CGPoint.zero

        init() {
            super.init(frame: .zero)
            isMultipleTouchEnabled = true; backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = "Field placement image"
            accessibilityHint = "One finger places a corner. Two fingers pan and pinch to zoom."
            accessibilityIdentifier = "field-placement-touch-surface"
            addPointerNavigation()
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

        // MARK: Trackpad and mouse

        /// A trackpad or mouse drives a single pointer, so the two-finger navigation above can
        /// never begin on a Mac: pan and zoom would be unreachable. Scroll and magnify events
        /// emit the same navigation actions instead. Neither recogniser sees a direct touch, so
        /// finger navigation on iPhone and iPad behaves exactly as before.
        private func addPointerNavigation() {
            let scroll = ScrollNavigationGesture(target: self, action: #selector(scrolled))
            scroll.allowedScrollTypesMask = .all
            addGestureRecognizer(scroll)

            let magnify = UIPinchGestureRecognizer(target: self, action: #selector(magnified))
            #if !targetEnvironment(macCatalyst)
            // Only a trackpad pinch; a Mac has no direct touches to exclude.
            magnify.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            #endif
            addGestureRecognizer(magnify)
        }

        /// Two-finger scroll and the wheel pan. Holding Command or Control zooms about the
        /// pointer, the convention in Mac timeline and canvas apps.
        @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)
            let zooms = gesture.modifierFlags.contains(.command) || gesture.modifierFlags.contains(.control)
            navigate(gesture,
                     translation: zooms ? .zero : translation,
                     scale: zooms ? pow(2, -translation.y / 180) : 1)
        }

        @objc private func magnified(_ gesture: UIPinchGestureRecognizer) {
            navigate(gesture, translation: .zero, scale: gesture.scale)
        }

        /// `FieldPlacementViewport.navigating` anchors on the point the gesture started from,
        /// so the origin stays fixed and only the current point and cumulative scale move.
        private func navigate(_ gesture: UIGestureRecognizer, translation: CGPoint, scale: CGFloat) {
            switch gesture.state {
            case .began:
                guard pointerGesture == nil else { return }
                // A pointer gesture interrupts a half-finished placement rather than merging with it.
                interaction.cancel().forEach { action?($0) }
                touches = []
                pointerGesture = gesture
                pointerOrigin = gesture.location(in: self)
                action?(.beginNavigation)
            case .changed:
                guard pointerGesture === gesture else { return }
                action?(.navigate(scale: scale, from: pointerOrigin,
                                  to: CGPoint(x: pointerOrigin.x + translation.x, y: pointerOrigin.y + translation.y)))
            case .ended, .cancelled, .failed:
                guard pointerGesture === gesture else { return }
                pointerGesture = nil
                action?(.endNavigation)
            default: break
            }
        }
    }
}

/// Scroll events never deliver touches, so failing on the first touch leaves click-drags to
/// drawing while the wheel and two-finger scroll still navigate.
private final class ScrollNavigationGesture: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
}
