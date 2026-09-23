import AppKit
import SwiftUI

/// macOS uses one pointer for corner placement, trackpad magnification and
/// two-finger scroll for pan/zoom. The interaction model is unchanged.
struct FieldPlacementTouchSurface: NSViewRepresentable {
    var label = "Field placement image"
    var hint = "Drag to place a corner. Pinch or scroll to zoom and pan."
    var identifier = "field-placement-touch-surface"
    let action: (FieldPlacementTouchState.Action) -> Void

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.action = action
        return view
    }
    func updateNSView(_ view: Surface, context: Context) {
        view.action = action
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(hint)
        view.setAccessibilityIdentifier(identifier)
    }

    final class Surface: NSView {
        var action: ((FieldPlacementTouchState.Action) -> Void)?
        private var isDraggingCorner = false
        private var lastMiddleDragPoint: CGPoint?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            isDraggingCorner = true
            action?(.beginCorner(convert(event.locationInWindow, from: nil)))
        }
        override func mouseDragged(with event: NSEvent) {
            guard isDraggingCorner else { return }
            action?(.moveCorner(convert(event.locationInWindow, from: nil)))
        }
        override func mouseUp(with event: NSEvent) {
            guard isDraggingCorner else { return }
            isDraggingCorner = false
            action?(.endCorner)
        }

        /// Middle-button drag pans, matching trackpad two-finger scrolling.
        override func otherMouseDown(with event: NSEvent) {
            lastMiddleDragPoint = convert(event.locationInWindow, from: nil)
            action?(.beginNavigation)
        }
        override func otherMouseDragged(with event: NSEvent) {
            guard let previous = lastMiddleDragPoint else { return }
            let current = convert(event.locationInWindow, from: nil)
            lastMiddleDragPoint = current
            action?(.navigate(scale: 1, from: previous, to: current))
        }
        override func otherMouseUp(with event: NSEvent) {
            guard lastMiddleDragPoint != nil else { return }
            lastMiddleDragPoint = nil
            action?(.endNavigation)
        }

        override func magnify(with event: NSEvent) {
            let center = convert(event.locationInWindow, from: nil)
            navigate(scale: 1 + event.magnification, from: center, to: center)
        }

        override func scrollWheel(with event: NSEvent) {
            let center = convert(event.locationInWindow, from: nil)
            if event.modifierFlags.contains(.command) {
                // Mouse wheel + Command zooms around the pointer.
                navigate(scale: 1 - event.scrollingDeltaY * 0.01, from: center, to: center)
                return
            }
            let previous = CGPoint(x: center.x + event.scrollingDeltaX, y: center.y + event.scrollingDeltaY)
            navigate(scale: 1, from: previous, to: center)
        }

        private func navigate(scale: CGFloat, from: CGPoint, to: CGPoint) {
            action?(.beginNavigation)
            action?(.navigate(scale: scale, from: from, to: to))
            action?(.endNavigation)
        }
    }
}