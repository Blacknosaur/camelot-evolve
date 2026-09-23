import Foundation
import CoreGraphics
import simd

/// Named pitch lines are constraints, not guessed corner correspondences.
/// A user can trace any visible portion, even when its intersections are offscreen.
enum GroundPitchLine: String, Codable, CaseIterable, Identifiable, Sendable {
    case farTouch, nearTouch, halfway, leftGoal, rightGoal
    case leftBoxFront, leftBoxFar, leftBoxNear, rightBoxFront, rightBoxFar, rightBoxNear
    case leftSmallFront, leftSmallFar, leftSmallNear, rightSmallFront, rightSmallFar, rightSmallNear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .farTouch: "Far touchline"
        case .nearTouch: "Near touchline"
        case .halfway: "Halfway line"
        case .leftGoal: "Left goal line"
        case .rightGoal: "Right goal line"
        case .leftBoxFront: "Left penalty area · front"
        case .leftBoxFar: "Left penalty area · far side"
        case .leftBoxNear: "Left penalty area · near side"
        case .rightBoxFront: "Right penalty area · front"
        case .rightBoxFar: "Right penalty area · far side"
        case .rightBoxNear: "Right penalty area · near side"
        case .leftSmallFront: "Left goal area · front"
        case .leftSmallFar: "Left goal area · far side"
        case .leftSmallNear: "Left goal area · near side"
        case .rightSmallFront: "Right goal area · front"
        case .rightSmallFar: "Right goal area · far side"
        case .rightSmallNear: "Right goal area · near side"
        }
    }
    var across: Bool {
        [.halfway, .leftGoal, .rightGoal, .leftBoxFront, .rightBoxFront, .leftSmallFront, .rightSmallFront].contains(self)
    }
    func coordinate(length: Double, width: Double) -> Double {
        switch self {
        case .farTouch, .leftGoal: 0
        case .nearTouch, .rightGoal: 1
        case .halfway: 0.5
        case .leftBoxFront: 16.5 / length
        case .rightBoxFront: 1 - 16.5 / length
        case .leftSmallFront: 5.5 / length
        case .rightSmallFront: 1 - 5.5 / length
        case .leftBoxFar, .rightBoxFar: (width - 40.32) / (2 * width)
        case .leftBoxNear, .rightBoxNear: (width + 40.32) / (2 * width)
        case .leftSmallFar, .rightSmallFar: (width - 18.32) / (2 * width)
        case .leftSmallNear, .rightSmallNear: (width + 18.32) / (2 * width)
        }
    }
}

struct GroundLineObservation: Codable, Equatable, Identifiable, Sendable {
    var kind: GroundPitchLine
    var points: [CGPoint]
    var id: GroundPitchLine { kind }
}

enum GroundLineAlignment {
    struct Fit {
        let calibration: GroundCalibration
        /// Residual in normalized image coordinates, not a metric accuracy claim.
        let residual: Double
        let minimumCrossingAngle: Double
    }

    static func fit(_ lines: [GroundLineObservation], length: Double, width: Double,
                    time: Double, aspect: Double, fixed: Bool) -> Fit? {
        guard length.isFinite, width.isFinite, length > 33, width > 40.32 else { return nil }
        let usable = lines.filter { $0.points.count == 2 && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
            hypot($0.points[1].x - $0.points[0].x, $0.points[1].y - $0.points[0].y) >= 0.035 }
        guard usable.count >= 4, Set(usable.map(\.kind)).count == usable.count else { return nil }
        var equations: [[Double]] = [], values: [Double] = []
        for line in usable {
            let k = line.kind.coordinate(length: length, width: width)
            for p in line.points {
                let u = Double(p.x), v = Double(p.y)
                equations.append(line.kind.across ? [0, 0, 0, u, v, 1, -k*u, -k*v] : [u, v, 1, 0, 0, 0, -k*u, -k*v])
                values.append(k)
            }
        }
        guard let h = solve(equations, values: values) else { return nil }
        let matrix = simd_double3x3(columns: (.init(h[0], h[3], h[6]), .init(h[1], h[4], h[7]), .init(h[2], h[5], 1)))
        guard abs(simd_determinant(matrix)) > 1e-9 else { return nil }
        let inverse = simd_inverse(matrix)
        var corners: [CGPoint] = []
        var sign: Double?
        for p in GroundFieldOverlay.rectangle {
            let result = inverse * SIMD3<Double>(Double(p.x), Double(p.y), 1)
            guard result.z.isFinite, abs(result.z) > 1e-7, sign == nil || sign! * result.z > 0 else { return nil }
            sign = result.z
            let x = result.x / result.z, y = result.y / result.z
            guard x.isFinite, y.isFinite, abs(x) < 32, abs(y) < 32 else { return nil }
            corners.append(.init(x: x, y: y))
        }
        var residual = 0.0
        for line in usable {
            let k = line.kind.coordinate(length: length, width: width)
            let a = line.kind.across ? h[3] - k*h[6] : h[0] - k*h[6]
            let b = line.kind.across ? h[4] - k*h[7] : h[1] - k*h[7]
            let c = line.kind.across ? h[5] - k : h[2] - k
            guard hypot(a, b) > 1e-9 else { return nil }
            for p in line.points { residual = max(residual, abs(a*Double(p.x) + b*Double(p.y) + c) / hypot(a,b)) }
        }
        guard residual < 0.012 else { return nil }
        var calibration = GroundCalibration(mode: .plane, points: corners, lengthMeters: width,
            widthMeters: length, referenceTime: time, imageAspectRatio: aspect, fixedCamera: fixed)
        calibration.fieldReference = .init(landmark: .fullPitch, pitchLength: length, pitchWidth: width)
        calibration.lineReferences = usable
        guard calibration.valid else { return nil }
        var minimumAngle = 90.0
        for a in usable where a.kind.across {
            for b in usable where !b.kind.across {
                let ax = (a.points[1].x-a.points[0].x)*aspect, ay = a.points[1].y-a.points[0].y
                let bx = (b.points[1].x-b.points[0].x)*aspect, by = b.points[1].y-b.points[0].y
                let cosine = min(1,abs(ax*bx+ay*by)/max(1e-12,hypot(ax,ay)*hypot(bx,by)))
                minimumAngle = min(minimumAngle,acos(cosine)*180/Double.pi)
            }
        }
        return .init(calibration: calibration, residual: residual, minimumCrossingAngle: minimumAngle)
    }

    /// Small, pivoted least-squares system. Rank checks reject parallel or
    /// redundant references instead of returning a plausible-looking seed.
    private static func solve(_ rows: [[Double]], values: [Double]) -> [Double]? {
        var matrix = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)
        for (row, value) in zip(rows, values) {
            for i in 0..<8 {
                for j in 0..<8 { matrix[i][j] += row[i] * row[j] }
                matrix[i][8] += row[i] * value
            }
        }
        let scale = matrix.flatMap { $0.prefix(8) }.map(abs).max() ?? 1
        for i in 0..<8 {
            guard let pivot = (i..<8).max(by: { abs(matrix[$0][i]) < abs(matrix[$1][i]) }),
                  abs(matrix[pivot][i]) > scale * 1e-10 else { return nil }
            matrix.swapAt(i, pivot)
            let divisor = matrix[i][i]
            for j in i...8 { matrix[i][j] /= divisor }
            for k in 0..<8 where k != i {
                let factor = matrix[k][i]
                for j in i...8 { matrix[k][j] -= factor * matrix[i][j] }
            }
        }
        let result = matrix.map { $0[8] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}
