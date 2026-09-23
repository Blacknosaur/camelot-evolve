import CoreGraphics
import Foundation

enum AnalysisDrawingTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case select, pen, arrow, line, ellipse, rectangle, zone, text, player, spotlight, connection, zoom, trajectory, loupe
    var id: String { rawValue }
    /// Spotlight remains a persisted layer kind, but is configured inside Player.
    static let toolbarTools: [Self] = [.select, .player, .pen, .arrow, .line, .ellipse, .rectangle, .zone, .text, .connection, .loupe, .zoom]
    var title: String {
        switch self {
        case .ellipse: "Circle"
        case .player: "Player"
        case .zone: "Polygon"
        case .connection: "Connect"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .ellipse: "circle"
        case .rectangle: "rectangle"
        case .zone: "pentagon"
        case .text: "textformat"
        case .player: "figure.stand"
        case .spotlight: "light.beacon.max"
        case .connection: "point.3.connected.trianglepath.dotted"
        case .zoom: "plus.magnifyingglass"
        case .loupe: "magnifyingglass.circle"
        case .trajectory: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

struct AnnotationColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    static let yellow = Self(red: 0.86, green: 1, blue: 0.15)
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
}

struct AnnotationKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var points: [CGPoint]

    private enum CodingKeys: String, CodingKey { case id, time, points }
}

extension AnnotationKeyframe {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        time = try values.decode(Double.self, forKey: .time)
        points = try values.decode([CGPoint].self, forKey: .points)
        if let stored = try values.decodeIfPresent(UUID.self, forKey: .id) { id = stored }
        else {
            // Legacy manifests are decoded repeatedly by the editor. Random IDs
            // here would make an unchanged composition look edited every time.
            var bits = time.bitPattern.bigEndian
            id = withUnsafeBytes(of: &bits) { bytes in
                UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 1, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]))
            }
        }
    }
}

/// Coordinates are fractions of the source display frame. Times are source seconds
/// (held-frame clips use startSeconds + elapsed time). Keyframes are baked so saved
/// edits and exports never depend on a regenerable detection cache.
struct AnalysisAnnotation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var tool: AnalysisDrawingTool
    var points: [CGPoint]
    var color: AnnotationColor = .yellow
    var width: Double = 0.006
    var text = ""
    var textStyle: AnnotationTextStyle? = nil
    var start: Double
    var end: Double
    var fade = false
    var keyframes: [AnnotationKeyframe] = []
    var playerMotion: PlayerMotion? = nil
    /// Links options from the Player panel even on a still frame, without motion.
    var playerEffectGroupID: UUID? = nil
    var playerEffectBox: CGRect? = nil
    var isHidden: Bool? = nil
    var isLocked: Bool? = nil
    var layerName: String? = nil
    var effect: AnnotationEffect? = nil
    var areaFill: Double? = nil
    var wallHeight: Double? = nil
    var grounded: Bool? = nil
    var groundReferenceTime: Double? = nil
    var wallHeightMeters: Double? = nil
    var wallOpacity: Double? = nil
    var linkedPlayers: [PlayerMotion]? = nil
    var cameraMotion: AnnotationCameraMotion? = nil
    var zoomScale: Double? = nil
    var zoomRamp: Double? = nil
    var fieldLines: Bool? = nil
    var fieldLayout: AnalysisFieldLayout? = nil
    var trajectoryStyle: PlayerTrajectoryStyle? = nil
    var trajectoryCameraMotion: AnnotationCameraMotion? = nil
    var showsSpeed: Bool? = nil
    var showsDistance: Bool? = nil
    var lineStyle: AnnotationLineStyle? = nil
    var loupeStyle: AnnotationLoupeStyle? = nil
    var title: String { layerName.flatMap { $0.isEmpty ? nil : $0 } ?? (tool == .text && !text.isEmpty ? text : tool.title) }
    var supportsGrounding: Bool { [.player, .spotlight, .zone, .rectangle, .ellipse, .line, .arrow, .pen, .connection].contains(tool) && fieldLines != true }
    func isGrounded(hasField: Bool) -> Bool { grounded ?? (hasField && [.player, .spotlight].contains(tool)) }

    var displayPlayerMotion: PlayerMotion? {
        guard var motion = playerMotion else { return nil }
        if tool == .text, motion.smoothing == nil { motion.smoothing = 0.95 }
        return motion
    }

    func points(at time: Double) -> [CGPoint] {
        if let cameraMotion, let projected = cameraMotion.points(points, at: time) { return projected }
        if let linkedPlayers, linkedPlayers.count == points.count {
            return zip(points, linkedPlayers).map { point, motion in
                guard let reference = motion.reference, let box = motion.box(at: time) else { return point }
                return CGPoint(x: box.midX + point.x - reference.midX, y: box.maxY + point.y - reference.maxY)
            }
        }
        if let motion = displayPlayerMotion, let reference = motion.reference, let box = motion.box(at: time) {
            if [.player, .spotlight].contains(tool) {
                guard let body = motion.effectBodyBox(at: time), let feet = motion.groundPoint(at: time) else { return [] }
                return points.map { CGPoint(x: feet.x + ($0.x - reference.midX) * body.width / max(0.001, reference.width),
                                            y: feet.y + ($0.y - reference.maxY) * body.height / max(0.001, reference.height)) }
            }
            // Labels translate from the body centre with a fixed offset. Scaling
            // their offset by a noisy full-body box amplified every leg/height change.
            if tool == .text || tool == .loupe {
                return points.map { CGPoint(x: $0.x + box.midX - reference.midX, y: $0.y + box.midY - reference.midY) }
            }
            let sx = box.width / max(0.001, reference.width), sy = box.height / max(0.001, reference.height)
            return points.map { CGPoint(x: box.midX + ($0.x - reference.midX) * sx, y: box.maxY + ($0.y - reference.maxY) * sy) }
        }
        guard let first = keyframes.first else { return points }
        if time <= first.time { return first.points }
        guard let next = keyframes.firstIndex(where: { $0.time > time }) else { return keyframes.last?.points ?? points }
        let a = keyframes[next - 1], b = keyframes[next]
        guard a.points.count == b.points.count else { return a.points }
        let fraction = CGFloat((time - a.time) / max(0.001, b.time - a.time))
        return zip(a.points, b.points).map { CGPoint(x: $0.x + ($1.x - $0.x) * fraction, y: $0.y + ($1.y - $0.y) * fraction) }
    }

    mutating func setKeyframe(at time: Double, points: [CGPoint]) {
        if let index = keyframes.firstIndex(where: { abs($0.time - time) < 1.0 / 60 }) {
            keyframes[index].points = points
            return
        }
        keyframes.append(.init(time: time, points: points))
        keyframes.sort { $0.time < $1.time }
    }

    func opacity(at time: Double) -> CGFloat {
        guard isHidden != true, time >= start, time < end else { return 0 }
        guard hasMotion(at: time) else { return 0 }
        if let motion = playerMotion, motion.box(at: time) == nil { return 0 }
        guard fade else { return 1 }
        let ramp = min(0.18, (end - start) / 4)
        return CGFloat(min(1, min((time - start) / ramp, (end - time) / ramp)))
    }

    /// Exact seeks round to the source timebase. Keep the drawing/handles visible
    /// at their authored In when that rounding lands a fraction of a frame early.
    func isActiveInEditor(at time: Double) -> Bool {
        time >= start - 1 / 600 && time <= end + 1 / 600 && hasMotion(at: time)
    }

    func hasMotion(at time: Double) -> Bool {
        if let linkedPlayers {
            if tool == .connection {
                guard linkedPlayers.count == points.count, renderedPoints(at: time).count >= 2 else { return false }
            } else if linkedPlayers.contains(where: { $0.box(at: time) == nil }) { return false }
        }
        if let cameraMotion, cameraMotion.transform(at: time) == nil { return false }
        return playerMotion == nil || playerMotion?.box(at: time) != nil
    }

    /// Keep the authored endpoint array intact for corrections. Render only
    /// confirmed players, reconnecting survivors in their original order.
    func renderedPoints(at time: Double) -> [CGPoint] {
        guard tool == .connection, let links = linkedPlayers, links.count == points.count else { return points(at: time) }
        return zip(points, links).compactMap { point, motion in
            guard let reference = motion.reference, let feet = motion.groundPoint(at: time) else { return nil }
            return CGPoint(x: feet.x + point.x - reference.midX, y: feet.y + point.y - reference.maxY)
        }
    }
}

enum AnnotationEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case clean, neon, pulse, radar, wall, aerial
    static let playerStyles: [Self] = [.clean, .neon, .pulse, .radar]
    var id: Self { self }
    var title: String { rawValue.capitalized }
}
