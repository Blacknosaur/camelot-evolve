import CoreGraphics

/// The four handles describe the visible reference, not necessarily the pitch
/// perimeter. Nil on an old annotation means the original whole-pitch guide.
struct AnalysisFieldLayout: Codable, Equatable, Sendable {
    enum Region: String, Codable, CaseIterable, Identifiable, Sendable {
        case penaltyArea, halfPitch, fullPitch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .penaltyArea: "Penalty area"
            case .halfPitch: "Half pitch"
            case .fullPitch: "Whole pitch"
            }
        }
    }
    enum GoalSide: String, Codable, CaseIterable, Identifiable, Sendable {
        case left, right
        var id: String { rawValue }
    }
    var region: Region = .penaltyArea
    var goalSide: GoalSide = .right
    static let legacy = Self(region: .fullPitch)
}

/// A projective pitch guide, not metric calibration. Corner order is clockwise:
/// far left, far right, near right, near left. Invalid/crossed quads draw nothing.
enum AnalysisFieldGuide {
    static func projection(corners p: [CGPoint]) -> CameraTransform? {
        guard p.count == 4 else { return nil }
        let turns = (0..<4).map { i -> CGFloat in
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 0.000001 }) || turns.allSatisfy({ $0 < -0.000001 }) else { return nil }
        let dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x
        let dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y
        let dx3 = p[0].x - p[1].x + p[2].x - p[3].x
        let dy3 = p[0].y - p[1].y + p[2].y - p[3].y
        let determinant = dx1 * dy2 - dx2 * dy1
        guard abs(determinant) > 0.000001 else { return nil }
        let g = (dx3 * dy2 - dx2 * dy3) / determinant
        let h = (dx1 * dy3 - dx3 * dy1) / determinant
        return CameraTransform(values: [
            p[1].x - p[0].x + g * p[1].x, p[3].x - p[0].x + h * p[3].x, p[0].x,
            p[1].y - p[0].y + g * p[1].y, p[3].y - p[0].y + h * p[3].y, p[0].y,
            g, h, 1
        ].map(Double.init))
    }

    static func path(corners: [CGPoint], layout: AnalysisFieldLayout = .legacy) -> CGPath {
        let path = CGMutablePath()
        guard let projection = projection(corners: corners) else { return path }
        func line(_ points: [CGPoint], closed: Bool = false) {
            let mapped = points.compactMap { point in
                let oriented = layout.region != .fullPitch && layout.goalSide == .right ? CGPoint(x: 1 - point.x, y: point.y) : point
                return projection.point(oriented)
            }
            guard mapped.count == points.count, let first = mapped.first else { return }
            path.move(to: first)
            for point in mapped.dropFirst() { path.addLine(to: point) }
            if closed { path.closeSubpath() }
        }
        line([.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)], closed: true)
        if layout.region != .fullPitch {
            // Draw only the chosen reference: no extrapolation into an unseen
            // half, and no unstable projection across the camera horizon.
            let length = layout.region == .halfPitch ? 52.5 : 16.5
            let breadth = layout.region == .halfPitch ? 68.0 : 40.32
            let boxes = layout.region == .halfPitch ? [(16.5, 20.16), (5.5, 9.16)] : [(5.5, 9.16)]
            for (depth, halfWidth) in boxes {
                line([.init(x: 0, y: 0.5 - halfWidth / breadth), .init(x: depth / length, y: 0.5 - halfWidth / breadth),
                      .init(x: depth / length, y: 0.5 + halfWidth / breadth), .init(x: 0, y: 0.5 + halfWidth / breadth)])
            }
            if layout.region == .halfPitch {
                line((0...32).map { index in
                    let angle = .pi / 2 + Double(index) / 32 * .pi
                    return CGPoint(x: 1 + cos(angle) * 9.15 / length, y: 0.5 + sin(angle) * 9.15 / breadth)
                })
            }
            return path
        }
        line([.init(x: 0.5, y: 0), .init(x: 0.5, y: 1)])
        // Standard proportions are a visual template only, not measured distances.
        for side in [0.0, 1.0] {
            let sign = side == 0 ? 1.0 : -1.0
            for (depth, halfWidth) in [(16.5 / 105, 20.16 / 68), (5.5 / 105, 9.16 / 68)] {
                line([.init(x: side, y: 0.5 - halfWidth), .init(x: side + sign * depth, y: 0.5 - halfWidth),
                      .init(x: side + sign * depth, y: 0.5 + halfWidth), .init(x: side, y: 0.5 + halfWidth)])
            }
        }
        line((0..<64).map { index in
            let angle = Double(index) / 64 * .pi * 2
            return CGPoint(x: 0.5 + cos(angle) * 9.15 / 105, y: 0.5 + sin(angle) * 9.15 / 68)
        }, closed: true)
        return path
    }
}
