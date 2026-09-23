import SwiftUI
import UIKit

/// Turns raw touch positions into one-finger drags and two-finger pinch/rotate updates.
/// Pure so it can be unit tested; the first two touches drive a pinch.
struct BoardTouchTracker {
    enum Event: Equatable {
        case began(CGPoint)
        case moved(CGPoint)
        case ended(CGPoint)
        /// A second finger landed. `centroid` is the midpoint between the two fingers.
        case pinchBegan(centroid: CGPoint)
        /// `scale` and `rotation` (radians, clockwise on screen) are relative to the start of the pinch.
        case pinchChanged(centroid: CGPoint, scale: CGFloat, rotation: CGFloat)
        case pinchEnded
        case cancelled
    }

    private enum Phase { case idle, single, pinch, finishing }
    private var phase: Phase = .idle
    private var lastPoint: CGPoint = .zero
    private var startDistance: CGFloat = 1
    private var lastAngle: CGFloat = 0
    private var rotation: CGFloat = 0

    mutating func update(_ points: [CGPoint]) -> [Event] {
        switch phase {
        case .idle:
            if points.count >= 2 { return beginPinch(points) }
            guard let first = points.first else { return [] }
            phase = .single
            lastPoint = first
            return [.began(first)]
        case .single:
            if points.count >= 2 { return beginPinch(points) }
            guard let first = points.first else {
                phase = .idle
                return [.ended(lastPoint)]
            }
            guard first != lastPoint else { return [] }
            lastPoint = first
            return [.moved(first)]
        case .pinch:
            guard points.count >= 2 else {
                phase = points.isEmpty ? .idle : .finishing
                return [.pinchEnded]
            }
            let angle = Self.angle(points[0], points[1])
            var delta = angle - lastAngle
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            rotation += delta
            lastAngle = angle
            return [.pinchChanged(centroid: Self.centroid(points[0], points[1]), scale: Self.distance(points[0], points[1]) / startDistance, rotation: rotation)]
        case .finishing:
            if points.isEmpty { phase = .idle }
            return []
        }
    }

    mutating func cancel() -> [Event] {
        defer { phase = .idle }
        switch phase {
        case .single: return [.cancelled]
        case .pinch: return [.pinchEnded]
        case .idle, .finishing: return []
        }
    }

    private mutating func beginPinch(_ points: [CGPoint]) -> [Event] {
        phase = .pinch
        startDistance = max(1, Self.distance(points[0], points[1]))
        lastAngle = Self.angle(points[0], points[1])
        rotation = 0
        return [.pinchBegan(centroid: Self.centroid(points[0], points[1]))]
    }

    private static func centroid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
    private static func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat { atan2(b.y - a.y, b.x - a.x) }
}

/// Transparent UIKit view over the board canvas. UIKit reports the real touch count, so a
/// one-finger drag never competes with a pinch, and the pinch centroid is known on every update.
struct BoardTouchSurface: UIViewRepresentable {
    /// A VoiceOver custom action on the board element (direct touch cannot select or nudge anything).
    struct Action {
        let name: String
        let perform: () -> Void
    }

    var accessibilityValue: String
    /// Custom actions offered on the board element, in the order VoiceOver reads them.
    var actions: [Action] = []
    let onEvent: (BoardTouchTracker.Event) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ view: Surface, context: Context) {
        view.onEvent = onEvent
        view.accessibilityValue = accessibilityValue
        view.accessibilityCustomActions = actions.map { action in
            UIAccessibilityCustomAction(name: action.name) { _ in action.perform(); return true }
        }
    }

    final class Surface: UIView {
        var onEvent: ((BoardTouchTracker.Event) -> Void)?
        private var touches: [UITouch] = []
        private var tracker = BoardTouchTracker()

        init() {
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = "Board"
            accessibilityIdentifier = "board-canvas"
            accessibilityTraits = .allowsDirectInteraction
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func touchesBegan(_ added: Set<UITouch>, with event: UIEvent?) {
            touches.append(contentsOf: added.sorted { $0.timestamp < $1.timestamp })
            send()
        }

        override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?) { send() }

        override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
            // Deliver the final position of a one-finger drag before it ends.
            if touches.count == 1 { send() }
            touches.removeAll { ended.contains($0) }
            send()
        }

        override func touchesCancelled(_ cancelled: Set<UITouch>, with event: UIEvent?) {
            touches.removeAll()
            tracker.cancel().forEach { onEvent?($0) }
        }

        private func send() {
            tracker.update(touches.map { $0.location(in: self) }).forEach { onEvent?($0) }
        }
    }
}
