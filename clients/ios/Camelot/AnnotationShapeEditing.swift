import Foundation
import CoreGraphics

extension AnalysisAnnotation {
    /// Rectangle-like shapes expose four real resize handles, not just their two
    /// stored diagonal points. Paths expose their vertices; freehand moves as a unit.
    func editHandles(at time: Double) -> [CGPoint] {
        let pose = points(at: time)
        guard let first = pose.first, let last = pose.last else { return [] }
        switch tool {
        case .pen: return []
        case .rectangle, .ellipse, .player, .spotlight:
            return [first, CGPoint(x: last.x, y: first.y), last, CGPoint(x: first.x, y: last.y)]
        default: return pose
        }
    }

    func reshaped(at time: Double, handle: Int?, delta: CGSize) -> [CGPoint] {
        var pose = points(at: time)
        guard let handle else { return pose.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) } }
        if [.rectangle, .ellipse, .player, .spotlight].contains(tool), pose.count == 2 {
            switch handle {
            case 0: pose[0].x += delta.width; pose[0].y += delta.height
            case 1: pose[1].x += delta.width; pose[0].y += delta.height
            case 2: pose[1].x += delta.width; pose[1].y += delta.height
            case 3: pose[0].x += delta.width; pose[1].y += delta.height
            default: break
            }
        } else if pose.indices.contains(handle) {
            pose[handle].x += delta.width; pose[handle].y += delta.height
        }
        return pose
    }

    /// Keep topology identical in every authored keyframe. Linked-player polygons
    /// cannot gain/remove anchors without selecting an actual player to track.
    mutating func insertPolygonCorner(after index: Int) {
        guard tool == .zone, fieldLines != true, linkedPlayers == nil, isLocked != true,
              points.count >= 3, points.count < 12, points.indices.contains(index),
              keyframes.allSatisfy({ $0.points.count == points.count }) else { return }
        func inserting(_ pose: [CGPoint]) -> [CGPoint] {
            var result = pose
            let a = pose[index], b = pose[(index + 1) % pose.count]
            result.insert(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), at: index + 1)
            return result
        }
        points = inserting(points)
        for i in keyframes.indices { keyframes[i].points = inserting(keyframes[i].points) }
    }

    mutating func removePolygonCorner(at index: Int) {
        guard tool == .zone, fieldLines != true, linkedPlayers == nil, isLocked != true, points.count > 3,
              points.indices.contains(index), keyframes.allSatisfy({ $0.points.count == points.count }) else { return }
        points.remove(at: index)
        for i in keyframes.indices { keyframes[i].points.remove(at: index) }
    }
}
