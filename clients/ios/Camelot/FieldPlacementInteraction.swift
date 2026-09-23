import CoreGraphics

enum FieldPointNudge {
    /// Source display pixels, independent of preview fit, pan, zoom or downsampling.
    /// Offscreen landmarks remain editable instead of snapping to the image edge.
    static func move(_ point: CGPoint, dx: Int, dy: Int, sourceSize: CGSize) -> CGPoint {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return point }
        return .init(x: point.x + CGFloat(dx) / sourceSize.width,
                     y: point.y + CGFloat(dy) / sourceSize.height)
    }
}

/// Inspection is local to placement; authored corners remain in source coordinates.
struct FieldPlacementViewport: Equatable {
    var zoom: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)

    func frame(fitted: CGRect) -> CGRect {
        CGRect(x: fitted.midX - fitted.width * zoom * center.x,
               y: fitted.midY - fitted.height * zoom * center.y,
               width: fitted.width * zoom, height: fitted.height * zoom)
    }

    func navigating(scale: CGFloat, from start: CGPoint, to current: CGPoint, fitted: CGRect) -> Self {
        guard scale.isFinite, scale > 0, fitted.width > 0, fitted.height > 0 else { return self }
        let anchor = AnnotationViewport.sourcePoint(start, frame: frame(fitted: fitted), allowsOffscreen: true)
        let nextZoom = min(8, max(0.25, zoom * scale))
        return Self(zoom: nextZoom, center: CGPoint(
            x: anchor.x + (fitted.midX - current.x) / (fitted.width * nextZoom),
            y: anchor.y + (fitted.midY - current.y) / (fitted.height * nextZoom)))
    }

    static func loupeCenter(finger: CGPoint, bounds: CGRect, size: CGSize) -> CGPoint {
        let insetX = min(bounds.width / 2, size.width / 2 + 8)
        let insetY = min(bounds.height / 2, size.height / 2 + 8)
        let candidates = [CGPoint(x: finger.x, y: finger.y - size.height / 2 - 54),
                          CGPoint(x: finger.x, y: finger.y + size.height / 2 + 54),
                          CGPoint(x: finger.x - size.width / 2 - 54, y: finger.y),
                          CGPoint(x: finger.x + size.width / 2 + 54, y: finger.y)].map {
            CGPoint(x: min(bounds.maxX - insetX, max(bounds.minX + insetX, $0.x)),
                    y: min(bounds.maxY - insetY, max(bounds.minY + insetY, $0.y)))
        }
        func clearance(_ point: CGPoint) -> CGFloat {
            hypot(max(0, abs(finger.x - point.x) - size.width / 2), max(0, abs(finger.y - point.y) - size.height / 2))
        }
        return candidates.first { clearance($0) >= 40 } ?? candidates.max { clearance($0) < clearance($1) } ?? bounds.origin
    }
}

/// One finger edits, two fingers navigate. Lifting just one navigation finger
/// must never turn the remaining finger into a new corner-placement gesture.
struct FieldPlacementTouchState {
    enum Action: Equatable {
        case beginCorner(CGPoint), moveCorner(CGPoint), endCorner, cancelCorner
        /// `rotation` is the change in the angle between the two fingers, in radians.
        case beginNavigation, navigate(scale: CGFloat, from: CGPoint, to: CGPoint, rotation: CGFloat = 0), endNavigation
    }
    private enum Mode { case idle, corner, navigation, waiting }
    private var mode = Mode.idle
    private var navigationCenter = CGPoint.zero
    private var navigationDistance: CGFloat = 1
    private var navigationAngle: CGFloat = 0

    mutating func update(_ points: [CGPoint]) -> [Action] {
        if points.count > 2 {
            let actions = cancel(); mode = .waiting; return actions
        }
        switch mode {
        case .idle:
            if points.count == 1 { mode = .corner; return [.beginCorner(points[0])] }
            if points.count >= 2 { beginNavigation(points); return [.beginNavigation] }
        case .corner:
            if points.isEmpty { mode = .idle; return [.endCorner] }
            if points.count >= 2 { beginNavigation(points); return [.cancelCorner, .beginNavigation] }
            return [.moveCorner(points[0])]
        case .navigation:
            if points.count < 2 { mode = points.isEmpty ? .idle : .waiting; return [.endNavigation] }
            var turn = angle(points) - navigationAngle
            if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
            return [.navigate(scale: distance(points) / navigationDistance, from: navigationCenter, to: center(points), rotation: turn)]
        case .waiting:
            if points.isEmpty { mode = .idle }
        }
        return []
    }

    mutating func cancel() -> [Action] {
        defer { mode = .idle }
        switch mode {
        case .corner: return [.cancelCorner]
        case .navigation: return [.endNavigation]
        default: return []
        }
    }

    private mutating func beginNavigation(_ points: [CGPoint]) {
        mode = .navigation; navigationCenter = center(points); navigationDistance = max(1, distance(points))
        navigationAngle = angle(points)
    }
    private func center(_ points: [CGPoint]) -> CGPoint { .init(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2) }
    private func distance(_ points: [CGPoint]) -> CGFloat { hypot(points[0].x - points[1].x, points[0].y - points[1].y) }
    private func angle(_ points: [CGPoint]) -> CGFloat { atan2(points[1].y - points[0].y, points[1].x - points[0].x) }
}
