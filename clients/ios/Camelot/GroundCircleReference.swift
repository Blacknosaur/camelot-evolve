import Foundation
import CoreGraphics
import simd

/// An observed conic, the actual centre spot, and a known field direction.
/// The ellipse centre alone is not a perspective calibration.
struct GroundCircleReference: Codable, Equatable, Sendable {
    var conic: [Double] // symmetric 3×3, row major
    var center: CGPoint
    var halfway: [CGPoint]
    var outlineErrorPixels: Double
    var farTouchline: [CGPoint]? = nil

    /// Three known positions along the halfway line fix its 1D projectivity:
    /// the two circle crossings and the far touchline. Recover the true centre
    /// using their cross-ratio, not the midpoint of the observed ellipse.
    func centerFromTouchline(pitchWidth: Double, diameter: Double) -> CGPoint? {
        guard let farTouchline, farTouchline.count == 2, halfway.count == 2,
              pitchWidth.isFinite, diameter.isFinite, diameter > 0, pitchWidth > diameter else { return nil }
        func line(_ points: [CGPoint]) -> SIMD3<Double> {
            simd_cross(.init(points[0].x,points[0].y,1),.init(points[1].x,points[1].y,1))
        }
        let half = line(halfway), touch = line(farTouchline), intersection = simd_cross(half,touch)
        guard abs(intersection.z) > 1e-10, let crossings = intersections(half) else { return nil }
        let sorted = crossings.sorted { $0.y < $1.y }, far = sorted[0], near = sorted[1]
        let dx = near.x-far.x, dy = near.y-far.y, norm = dx*dx+dy*dy
        guard norm > 1e-8 else { return nil }
        let tx = intersection.x/intersection.z, ty = intersection.y/intersection.z
        let observed = ((tx-far.x)*dx+(ty-far.y)*dy)/norm
        let world = 0.5-pitchWidth/(2*diameter)
        guard observed < -0.02 else { return nil }
        let k = (world-observed)/(world*(observed-1))
        let position = (k+1)/(k+2)
        guard position.isFinite, position > 0.05, position < 0.95 else { return nil }
        return .init(x: far.x+position*dx,y: far.y+position*dy)
    }

    var matrix: simd_double3x3 {
        .init(rows: [.init(conic[0], conic[1], conic[2]), .init(conic[3], conic[4], conic[5]), .init(conic[6], conic[7], conic[8])])
    }

    var anchors: [CGPoint]? {
        guard conic.count == 9, conic.allSatisfy(\.isFinite), halfway.count == 2,
              center.x.isFinite, center.y.isFinite else { return nil }
        let c = SIMD3<Double>(center.x, center.y, 1), e = matrix
        guard simd_dot(c, e * c) < -1e-9 else { return nil }
        let direction = SIMD2<Double>(halfway[1].x-halfway[0].x, halfway[1].y-halfway[0].y)
        guard simd_length(direction) > 0.01 else { return nil }
        // Use the measured direction through the corrected centre. The pole of
        // the centre supplies the vanishing line even under strong perspective.
        let line = SIMD3<Double>(-direction.y, direction.x, direction.y*c.x-direction.x*c.y)
        let vanishing = e * c
        let v = simd_cross(line, vanishing)
        let perpendicular = e * v
        guard let across = intersections(line), let along = intersections(perpendicular) else { return nil }
        let nearFar = across.sorted { $0.y < $1.y }, leftRight = along.sorted { $0.x < $1.x }
        let result = [leftRight[0], nearFar[1], leftRight[1], nearFar[0]]
        guard GroundFieldOverlay.calibrationCorners(anchors: result, landmark: .centreCircle).count == 4 else { return nil }
        return result
    }

    func intersections(_ line: SIMD3<Double>) -> [CGPoint]? {
        guard conic.count == 9 else { return nil }
        let norm = hypot(line.x, line.y)
        guard norm > 1e-12 else { return nil }
        let p = SIMD3<Double>(-line.x*line.z/(norm*norm), -line.y*line.z/(norm*norm), 1)
        let d = SIMD3<Double>(-line.y/norm, line.x/norm, 0), e = matrix
        let a = simd_dot(d, e*d), b = 2*simd_dot(p, e*d), c = simd_dot(p, e*p)
        let discriminant = b*b-4*a*c
        guard a > 1e-12, discriminant > 1e-12 else { return nil }
        return [-1.0, 1].map { sign in
            let t = (-b+sign*sqrt(discriminant))/(2*a)
            return CGPoint(x: p.x+t*d.x, y: p.y+t*d.y)
        }
    }

    func transformed(by transform: CameraTransform) -> Self? {
        guard conic.count == 9, let anchors, let center = transform.point(center) else { return nil }
        let m = transform.matrix
        let h = simd_double3x3(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
        let inverse = simd_inverse(h)
        let e = inverse.transpose * matrix * inverse
        var result = self
        result.conic = (0..<3).flatMap { row in (0..<3).map { column in e[column][row] } }
        result.center = center; result.halfway = [anchors[3],anchors[1]].compactMap { transform.point($0) }
        result.farTouchline = farTouchline?.compactMap { transform.point($0) }
        return result.anchors == nil ? nil : result
    }

    /// Perturb the centre by one source pixel and measure the largest overlay
    /// displacement in the visible neighbourhood. This is a stability warning,
    /// not a calibrated confidence percentage or a metric error bound.
    func pixelSensitivity(imageSize: CGSize) -> Double? {
        guard imageSize.width > 0, imageSize.height > 0, let anchors,
              let original = AnalysisFieldGuide.projection(corners: GroundFieldOverlay.calibrationCorners(anchors: anchors,landmark: .centreCircle)) else { return nil }
        var maximum = 0.0
        for offset in [CGPoint(x: 1,y: 0),.init(x: -1,y: 0),.init(x: 0,y: 1),.init(x: 0,y: -1)] {
            var changed = self
            changed.center.x += offset.x/imageSize.width; changed.center.y += offset.y/imageSize.height
            guard let adjusted = changed.anchors,
                  let projection = AnalysisFieldGuide.projection(corners: GroundFieldOverlay.calibrationCorners(anchors: adjusted,landmark: .centreCircle)) else { return .infinity }
            for x in -2...3 { for y in -2...3 {
                let p = CGPoint(x: x,y: y)
                guard let a = original.point(p), a.x >= 0, a.x <= 1, a.y >= 0, a.y <= 1 else { continue }
                guard let b = projection.point(p) else { return .infinity }
                maximum = max(maximum,hypot((a.x-b.x)*imageSize.width,(a.y-b.y)*imageSize.height))
            } }
        }
        return maximum
    }

    /// Fit all observed curve samples, not four apparent ellipse extrema.
    static func fit(outline: [CGPoint], halfway: [CGPoint], imageSize: CGSize) -> Self? {
        guard outline.count >= 24, halfway.count == 2, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let n = Double(outline.count)
        let cx = outline.reduce(0.0) { $0+$1.x }/n, cy = outline.reduce(0.0) { $0+$1.y }/n
        let sx = sqrt(outline.reduce(0.0) { $0+pow($1.x-cx,2) }/n)
        let sy = sqrt(outline.reduce(0.0) { $0+pow($1.y-cy,2) }/n)
        guard sx > 0.02, sy > 0.003 else { return nil }
        let normalized = outline.map { CGPoint(x: ($0.x-cx)/sx, y: ($0.y-cy)/sy) }
        var accepted = normalized, coefficients: [Double] = []
        for _ in 0..<3 {
            let rows = accepted.map { p -> [Double] in
                let x = Double(p.x), y = Double(p.y)
                return [x*x, 2*x*y, y*y, 2*x, 2*y]
            }
            guard let solution = solve(rows) else { return nil }
            coefficients = solution
            let errors = normalized.map { p -> Double in
                let x = Double(p.x), y = Double(p.y)
                let quadratic = solution[0]*x*x + 2*solution[1]*x*y + solution[2]*y*y
                let value = quadratic + 2*solution[3]*x + 2*solution[4]*y - 1
                let dx = 2*(solution[0]*x+solution[1]*y+solution[3])
                let dy = 2*(solution[1]*x+solution[2]*y+solution[4])
                return abs(value)/max(1e-9,hypot(dx,dy))
            }
            let cutoff = max(0.025, errors.sorted()[errors.count/2]*3)
            accepted = zip(normalized,errors).filter { $0.1 <= cutoff }.map(\.0)
            guard accepted.count >= normalized.count*2/3 else { return nil }
        }
        let q = coefficients
        guard q[0] > 0, q[2] > 0, q[0]*q[2]-q[1]*q[1] > 1e-8 else { return nil }
        let local = simd_double3x3(rows: [.init(q[0],q[1],q[3]),.init(q[1],q[2],q[4]),.init(q[3],q[4],-1)])
        let normalization = simd_double3x3(rows: [.init(1/sx,0,-cx/sx),.init(0,1/sy,-cy/sy),.init(0,0,1)])
        let e = normalization.transpose * local * normalization
        let determinant = q[0]*q[2]-q[1]*q[1]
        let center = CGPoint(x: cx+sx*(q[1]*q[4]-q[2]*q[3])/determinant,
                             y: cy+sy*(q[1]*q[3]-q[0]*q[4])/determinant)
        let errors = outline.map { p -> Double in
            let v = SIMD3<Double>(p.x,p.y,1), ev = e*v
            return abs(simd_dot(v,ev))/max(1e-9,2*hypot(ev.x/imageSize.width,ev.y/imageSize.height))
        }.sorted()
        let residual = errors[errors.count*3/4]
        guard residual < 4 else { return nil }
        let result = Self(conic: (0..<3).flatMap { row in (0..<3).map { column in e[column][row] } },
                          center: center, halfway: halfway, outlineErrorPixels: residual)
        return result.anchors == nil ? nil : result
    }

    private static func solve(_ rows: [[Double]]) -> [Double]? {
        var system = Array(repeating: Array(repeating: 0.0, count: 6), count: 5)
        for row in rows { for i in 0..<5 {
            for j in 0..<5 { system[i][j] += row[i]*row[j] }
            system[i][5] += row[i]
        } }
        for i in 0..<5 {
            guard let pivot = (i..<5).max(by: { abs(system[$0][i]) < abs(system[$1][i]) }), abs(system[pivot][i]) > 1e-9 else { return nil }
            system.swapAt(i,pivot)
            let divisor = system[i][i]
            for j in i...5 { system[i][j] /= divisor }
            for k in 0..<5 where k != i {
                let factor = system[k][i]
                for j in i...5 { system[k][j] -= factor*system[i][j] }
            }
        }
        return system.map { $0[5] }
    }
}
