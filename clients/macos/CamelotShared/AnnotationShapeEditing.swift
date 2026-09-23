import Foundation
import CoreGraphics

extension AnalysisAnnotation {
    /// Rectangle-like shapes expose four real resize handles, not just their two
    /// stored diagonal points. Paths expose their vertices; freehand moves as a unit.
    func editHandles(at time: Double, ground: GroundCalibration? = nil) -> [CGPoint] {
        if [.rectangle, .ellipse].contains(tool), isGrounded(hasField: ground?.mode == .plane) {
            return groundShapeCorners(at: time, ground: ground) ?? []
        }
        let pose = points(at: time)
        guard let first = pose.first, let last = pose.last else { return [] }
        switch tool {
        case .pen: return []
        case .rectangle, .ellipse, .player, .spotlight:
            return [first, CGPoint(x: last.x, y: first.y), last, CGPoint(x: first.x, y: last.y)]
        default: return pose
        }
    }

    func reshaped(at time: Double, handle: Int?, delta: CGSize, ground: GroundCalibration? = nil) -> [CGPoint] {
        var pose = points(at: time)
        if ![.player, .spotlight].contains(tool), let plane = groundPlane(at: time, ground: ground) {
            let world = pose.compactMap { plane.worldPoint($0, at: time) }
            guard world.count == pose.count, let first = pose.first else { return pose }
            var moved = world
            if let handle, [.rectangle, .ellipse].contains(tool), world.count == 2 {
                let corners = editHandles(at: time, ground: plane)
                guard corners.indices.contains(handle),
                      let target = plane.worldPoint(.init(x: corners[handle].x + delta.width, y: corners[handle].y + delta.height), at: time) else { return pose }
                switch handle {
                case 0: moved[0] = target
                case 1: moved[1].x = target.x; moved[0].y = target.y
                case 2: moved[1] = target
                case 3: moved[0].x = target.x; moved[1].y = target.y
                default: return pose
                }
            } else if handle == nil {
                guard let origin = world.first,
                      let target = plane.worldPoint(.init(x: first.x + delta.width, y: first.y + delta.height), at: time) else { return pose }
                moved = world.map { .init(x: $0.x + target.x - origin.x, y: $0.y + target.y - origin.y) }
            } else if let handle, pose.indices.contains(handle) {
                pose[handle].x += delta.width; pose[handle].y += delta.height
                return pose
            }
            let projected = moved.compactMap { plane.imagePoint($0, at: time) }
            return projected.count == pose.count ? projected : pose
        }
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
