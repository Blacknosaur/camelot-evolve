import CoreGraphics
import Foundation

/// Authored handles stay in image coordinates. Expand curved/rectangular shapes
/// in metric field coordinates before projecting every vertex back to the image.
/// This keeps existing tracking, keyframes and saved projects in one coordinate contract.
extension AnalysisAnnotation {
    mutating func setGrounding(_ enabled: Bool, at time: Double, ground: GroundCalibration?) {
        grounded = enabled
        if enabled, playerMotion == nil, linkedPlayers == nil, cameraMotion == nil, keyframes.isEmpty { groundReferenceTime = time }
        // Reuse the saved camera pass for every authored point. Independent
        // player tracks and explicit keyframes retain their authored motion.
        if enabled, playerMotion == nil, linkedPlayers == nil,
           cameraMotion == nil, keyframes.isEmpty, var camera = ground?.cameraMotion {
            makeStatic(at: time)
            camera.referenceTime = time; cameraMotion = camera
        }
    }

    func groundPlane(at time: Double, ground: GroundCalibration?) -> GroundCalibration? {
        guard supportsGrounding, isGrounded(hasField: ground?.mode == .plane),
              ground?.mode == .plane else { return nil }
        return ground?.frozen(at: time)
    }

    func groundShapeCorners(at time: Double, ground: GroundCalibration?) -> [CGPoint]? {
        guard [.rectangle, .ellipse].contains(tool),
              let plane = groundPlane(at: time, ground: ground) else { return nil }
        let pose = points(at: time)
        guard let first = pose.first, let last = pose.last,
              let a = plane.worldPoint(first, at: time),
              let b = plane.worldPoint(last, at: time) else { return nil }
        return projectGroundPoints([a, .init(x: b.x, y: a.y), b, .init(x: a.x, y: b.y)], plane: plane, time: time)
    }

    /// Normalized image vertices shared by rendering, selection and measurements.
    func shapeBoundary(at time: Double, ground: GroundCalibration?) -> [CGPoint] {
        let pose = renderedPoints(at: time)
        guard supportsGrounding, isGrounded(hasField: ground?.mode == .plane) else { return pose }
        guard let plane = groundPlane(at: time, ground: ground) else { return [] }
        guard let first = pose.first, let last = pose.last else { return [] }
        if tool == .rectangle { return groundShapeCorners(at: time, ground: plane) ?? [] }
        if tool == .ellipse {
            guard let a = plane.worldPoint(first, at: time), let b = plane.worldPoint(last, at: time) else { return [] }
            let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let vertices = (0..<96).map { index in
                let angle = Double(index) * 2 * .pi / 96
                return CGPoint(x: center.x + (b.x - a.x) / 2 * CGFloat(cos(angle)),
                               y: center.y + (b.y - a.y) / 2 * CGFloat(sin(angle)))
            }
            return projectGroundPoints(vertices, plane: plane, time: time) ?? []
        }
        // Legacy two-handle polygons also need their implicit corner on the floor.
        if tool == .zone, pose.count == 2 {
            guard let a = plane.worldPoint(first, at: time), let b = plane.worldPoint(last, at: time) else { return [] }
            return projectGroundPoints([a, .init(x: b.x, y: a.y), b], plane: plane, time: time) ?? []
        }
        return pose
    }

    private func projectGroundPoints(_ points: [CGPoint], plane: GroundCalibration, time: Double) -> [CGPoint]? {
        let projected = points.compactMap { plane.imagePoint($0, at: time) }
        // Never connect across a vertex that crossed the plane's horizon.
        return projected.count == points.count ? projected : nil
    }
}
