import CoreGraphics
import simd

/// Pinhole extrusion of the metric ground homography. Intrinsics are estimated
/// with a centred principal point and square pixels, not recovered lens metadata.
/// H = K[r1 r2 t]; its plane normal supplies the missing vertical column.
struct GroundEffectProjection {
    let plane: simd_float3x3
    let vertical: SIMD3<Float>
    let inverse: simd_float3x3
    let anchorDepth: Float

    init?(ground: GroundCalibration, at time: Double) {
        guard ground.mode == .plane, ground.valid, let camera = ground.cameraTransform(at: time),
              let h = AnalysisFieldGuide.projection(corners: ground.points) else { return nil }
        let pose = ground
        var matrix = h.matrix
        matrix[0] /= Float(pose.lengthMeters); matrix[1] /= Float(pose.widthMeters)
        let aspect = Float(pose.imageAspectRatio)
        func centred(_ v: SIMD3<Float>) -> SIMD3<Float> { .init(aspect * (v.x - 0.5 * v.z), v.y - 0.5 * v.z, v.z) }
        let a = centred(matrix[0]), b = centred(matrix[1])
        // Orthogonality and equal lengths give two linear constraints on f².
        let c = SIMD2(a.x * b.x + a.y * b.y, a.x * a.x + a.y * a.y - b.x * b.x - b.y * b.y)
        let d = SIMD2(a.z * b.z, a.z * a.z - b.z * b.z)
        let denominator = simd_dot(d, d)
        let squared = denominator > 1e-14 ? -simd_dot(c, d) / denominator : -1
        let focal = squared.isFinite && squared > 0.0625 && squared < 100 ? sqrt(squared) : max(1, aspect)
        func ray(_ v: SIMD3<Float>) -> SIMD3<Float> { .init(v.x / focal, v.y / focal, v.z) }
        let first = ray(a), second = ray(b)
        let scale = (simd_length(first) + simd_length(second)) / 2
        var normal = simd_cross(first, second)
        guard simd_length(normal) > 1e-9, scale.isFinite, scale > 0 else { return nil }
        normal = simd_normalize(normal)
        // Positive height points from the floor toward the camera, independent
        // of the corner ordering, roll or direction of the pitch axes.
        if simd_dot(normal, ray(centred(matrix[2]))) > 0 { normal = -normal }
        var column = SIMD3(focal / aspect * normal.x + 0.5 * normal.z,
                           focal * normal.y + 0.5 * normal.z, normal.z) * scale
        // Reuse the saved camera warp for the entire extrusion. Re-estimating
        // intrinsics each frame would make wall height breathe during a pan.
        matrix = camera.matrix * matrix
        column = camera.matrix * column
        let center = matrix * SIMD3(Float(pose.lengthMeters / 2), Float(pose.widthMeters / 2), 1)
        guard abs(matrix.determinant) > 1e-10, center.z.isFinite, abs(center.z) > 1e-6 else { return nil }
        plane = matrix; vertical = column; inverse = matrix.inverse; anchorDepth = center.z
    }

    func raised(_ imagePoint: CGPoint, meters: Double) -> CGPoint? {
        guard meters.isFinite, meters >= 0, meters <= 20 else { return nil }
        let raw = inverse * SIMD3(Float(imagePoint.x), Float(imagePoint.y), 1)
        guard abs(raw.z) > 1e-7 else { return nil }
        let floor = plane * (raw / raw.z)
        let top = floor + vertical * Float(meters)
        guard floor.z * anchorDepth > 0, top.z * floor.z > 0,
              abs(top.z) > abs(floor.z) * 0.1 else { return nil }
        let result = CGPoint(x: CGFloat(top.x / top.z), y: CGFloat(top.y / top.z))
        guard result.x.isFinite, result.y.isFinite, hypot(result.x - imagePoint.x, result.y - imagePoint.y) < 2 else { return nil }
        return result
    }
}
