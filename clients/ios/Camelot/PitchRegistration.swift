import CoreGraphics
import Foundation
import simd

/// Snaps a projected pitch template to the white markings actually painted on
/// the turf. Any starting alignment (an automatic proposal, traced lines or
/// dragged handles) is refined against source pixels, and the result reports
/// how much of the template found evidence so the user can judge it. It is a
/// refinement, not proof of metric accuracy: unseen lines are not measured.
enum PitchRegistration {
    struct Quality: Equatable, Sendable {
        enum Grade: String, Sendable {
            case good, check, poor
            var title: String {
                switch self {
                case .good: "Good fit"
                case .check: "Check fit"
                case .poor: "Weak fit"
                }
            }
        }
        /// Median perpendicular distance between supported samples and the
        /// snapped template, in source pixels.
        var residualPixels: Double
        /// Supported samples divided by template samples visible in the frame.
        var coverage: Double
        var supportedLines: Int
        var acrossSupported: Bool
        var alongSupported: Bool

        var grade: Grade {
            let directions = acrossSupported && alongSupported
            if directions, supportedLines >= 4, coverage >= 0.4, residualPixels <= 1.6 { return .good }
            if directions, supportedLines >= 3, coverage >= 0.2, residualPixels <= 3.2 { return .check }
            return .poor
        }

        var summary: String {
            "\(grade.title) · \(residualPixels.formatted(.number.precision(.fractionLength(1)))) px · \(supportedLines) line\(supportedLines == 1 ? "" : "s")"
        }
    }

    struct Result: Sendable {
        let calibration: GroundCalibration
        let quality: Quality
    }

    /// White-marking evidence for one frame, computed once and reused by every
    /// snap on that frame. Values live at a bounded working resolution; the
    /// sub-pixel search and all reported residuals are converted to source pixels.
    final class Evidence: @unchecked Sendable {
        let width: Int
        let height: Int
        let sourceSize: CGSize
        private let whiteness: [UInt8]
        private let turf: [UInt8]

        var sourceScale: Double { Double(sourceSize.width) / Double(width) }

        init?(image: CGImage, maximumWidth: Int = 1280) {
            guard image.width > 32, image.height > 32 else { return nil }
            let width = min(maximumWidth, image.width)
            let height = max(1, image.height * width / image.width)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            var whiteness = [UInt8](repeating: 0, count: width * height)
            var turf = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeBufferPointer { source in
                for index in 0..<(width * height) {
                    let r = Int(source[index * 4]), g = Int(source[index * 4 + 1]), b = Int(source[index * 4 + 2])
                    if g > 45, g * 100 > r * 94, g * 100 > b * 135 { turf[index] = 1 }
                    guard r * 10 > g * 8, b * 20 > g * 13 else { continue }
                    let value = min(r, g, b) * 2 - max(r, g, b)
                    if value > 0 { whiteness[index] = UInt8(min(255, value)) }
                }
            }
            self.width = width; self.height = height
            self.sourceSize = CGSize(width: image.width, height: image.height)
            self.whiteness = whiteness; self.turf = turf
        }

        @inline(__always) func white(_ x: Double, _ y: Double) -> Int {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, ix < width, iy >= 0, iy < height else { return 0 }
            return Int(whiteness[iy * width + ix])
        }

        @inline(__always) func isTurf(_ x: Double, _ y: Double) -> Bool {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, ix < width, iy >= 0, iy < height else { return false }
            return turf[iy * width + ix] == 1
        }

        /// Line response at a point: bright neutral paint against darker
        /// surroundings measured along the line normal.
        @inline(__always) func response(_ x: Double, _ y: Double, nx: Double, ny: Double, halfWidth: Double) -> (value: Int, score: Double) {
            let value = white(x, y)
            let background = Double(white(x - halfWidth * nx, y - halfWidth * ny) + white(x + halfWidth * nx, y + halfWidth * ny)) / 2
            return (value, Double(value) - background)
        }
    }

    /// One template sample with its observed marking position.
    private struct Observation {
        var line: SIMD3<Double>        // template-space line, |(a,b)| = 1
        var observed: SIMD2<Double>    // template coordinates of the observed marking
        var pixelScale: Double         // source pixels per template unit along the normal
        var evidence: Double           // 0…1
        var polyline: Int
        var distance: Double           // search offset in working pixels
    }

    private struct Template {
        struct Polyline { let points: [SIMD2<Double>]; let across: Bool; let along: Bool }
        let polylines: [Polyline]
    }

    /// Coarse-to-fine schedule. `reach` limits which template samples take
    /// part, in multiples of the reference rectangle: markings near the
    /// reference are locked first, so a small far reference is not dragged by
    /// wildly extrapolated lines matching the wrong paint. Radii are working
    /// pixels; `threshold` (source pixels) is nil while everything found
    /// inside the radius should count.
    private struct Stage { let reach: Double; let radius: Double; let threshold: Double? }
    private static let stages: [Stage] = [
        .init(reach: 1.5, radius: 40, threshold: nil), .init(reach: 1.5, radius: 24, threshold: nil),
        .init(reach: 1.5, radius: 12, threshold: nil), .init(reach: 1.5, radius: 6, threshold: 4),
        .init(reach: 4, radius: 28, threshold: nil), .init(reach: 4, radius: 14, threshold: nil),
        .init(reach: 4, radius: 7, threshold: 4),
        .init(reach: .infinity, radius: 18, threshold: nil), .init(reach: .infinity, radius: 10, threshold: nil),
        .init(reach: .infinity, radius: 6, threshold: 3), .init(reach: .infinity, radius: 4, threshold: 2),
    ]

    /// Per-iteration diagnostics for tests: iteration, samples, used samples and corners.
    struct Trace { let iteration: Int; let visible: Int; let matched: Int; let corners: [CGPoint] }

    static func snap(_ calibration: GroundCalibration, evidence: Evidence, iterations: Int = 33,
                     trace: ((Trace) -> Void)? = nil) -> Result? {
        guard calibration.valid, calibration.mode == .plane, let reference = calibration.fieldReference,
              let template = template(reference: reference, length: calibration.lengthMeters, depth: calibration.widthMeters),
              var homography = homography(corners: calibration.points) else { return nil }
        var iteration = 0
        stages: for stage in stages {
            let wide = stage.radius * evidence.sourceScale * 1.2
            let threshold = min(wide, stage.threshold ?? wide)
            // Stay at one radius until the solution settles, so distant lines
            // are pulled in before the search narrows around nearby paint.
            for _ in 0..<3 {
                guard iteration < max(1, iterations) else { break stages }
                iteration += 1
                let sampling = observe(template: template, homography: homography, evidence: evidence, radius: stage.radius, reach: stage.reach)
                let observations = sampling.observations
                guard observations.count >= 12, let correction = solve(observations, homography: homography, threshold: threshold) else { continue stages }
                let next = homography * simd_inverse(correction)
                guard let before = corners(of: homography), let after = corners(of: next),
                      plausible(after, previous: calibration.points) else { continue stages }
                homography = next
                trace?(.init(iteration: iteration, visible: sampling.visibleSamples, matched: observations.count, corners: after))
                if maximumCornerMovement(from: before, to: after) * Double(evidence.sourceSize.width) < 0.5 { break }
            }
        }
        guard let corners = corners(of: homography) else { return nil }
        var result = calibration
        result.points = corners
        result.circleReference = nil
        guard result.valid else { return nil }
        let final = observe(template: template, homography: homography, evidence: evidence, radius: 4, reach: .infinity)
        return Result(calibration: result, quality: quality(final, template: template, evidence: evidence))
    }

    /// Moves traced line endpoints onto the snapped template so a lines draft
    /// stays editable and reproduces the refined alignment.
    static func reproject(_ lines: [GroundLineObservation], onto calibration: GroundCalibration,
                          pitchLength: Double, pitchWidth: Double) -> [GroundLineObservation]? {
        guard let homography = homography(corners: calibration.points) else { return nil }
        let inverse = simd_inverse(homography)
        var result: [GroundLineObservation] = []
        for line in lines {
            let k = line.kind.coordinate(length: pitchLength, width: pitchWidth)
            var points: [CGPoint] = []
            for point in line.points {
                let q = inverse * SIMD3(Double(point.x), Double(point.y), 1)
                guard abs(q.z) > 1e-9 else { return nil }
                var template = SIMD2(q.x / q.z, q.y / q.z)
                if line.kind.across { template.y = k } else { template.x = k }
                let p = homography * SIMD3(template.x, template.y, 1)
                guard abs(p.z) > 1e-9, (p.x / p.z).isFinite, (p.y / p.z).isFinite else { return nil }
                points.append(CGPoint(x: p.x / p.z, y: p.y / p.z))
            }
            result.append(.init(kind: line.kind, points: points))
        }
        return result
    }

    // MARK: - Template

    private static func template(reference: GroundFieldReference, length: Double, depth: Double) -> Template? {
        let lines = GroundFieldOverlay.worldLines(reference: reference, length: length, depth: depth)
        guard !lines.isEmpty, length > 0, depth > 0 else { return nil }
        let polylines = lines.compactMap { line -> Template.Polyline? in
            let points = line.map { SIMD2(Double($0.x) / length, Double($0.y) / depth) }
            guard points.count >= 2 else { return nil }
            var across = false, along = false
            for (a, b) in zip(points, points.dropFirst()) {
                let d = b - a
                if abs(d.x) >= abs(d.y) { across = true } else { along = true }
            }
            return .init(points: points, across: across, along: along)
        }
        return polylines.isEmpty ? nil : Template(polylines: polylines)
    }

    static func homography(corners: [CGPoint]) -> simd_double3x3? {
        guard let projection = AnalysisFieldGuide.projection(corners: corners), projection.values.count == 9,
              projection.values.allSatisfy(\.isFinite) else { return nil }
        let v = projection.values
        let matrix = simd_double3x3(rows: [.init(v[0], v[1], v[2]), .init(v[3], v[4], v[5]), .init(v[6], v[7], v[8])])
        return abs(simd_determinant(matrix)) > 1e-12 ? matrix : nil
    }

    private static func corners(of homography: simd_double3x3) -> [CGPoint]? {
        let center = homography * SIMD3(0.5, 0.5, 1)
        guard abs(center.z) > 1e-9 else { return nil }
        var result: [CGPoint] = []
        for point in GroundFieldOverlay.rectangle {
            let p = homography * SIMD3(Double(point.x), Double(point.y), 1)
            guard abs(p.z) > 1e-9, p.z * center.z > 0 else { return nil }
            let x = p.x / p.z, y = p.y / p.z
            guard x.isFinite, y.isFinite, abs(x) < 32, abs(y) < 32 else { return nil }
            result.append(CGPoint(x: x, y: y))
        }
        return AnalysisFieldGuide.projection(corners: result) == nil ? nil : result
    }

    private static func plausible(_ corners: [CGPoint], previous: [CGPoint]) -> Bool {
        maximumCornerMovement(from: previous, to: corners) < 0.35
    }

    private static func maximumCornerMovement(from a: [CGPoint], to b: [CGPoint]) -> Double {
        zip(a, b).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max() ?? .infinity
    }

    // MARK: - Sampling

    private struct Sampling {
        var observations: [Observation] = []
        var visibleSamples = 0
        var visiblePerLine: [Int: Int] = [:]
    }

    private static func observe(template: Template, homography: simd_double3x3, evidence: Evidence, radius: Double, reach: Double) -> Sampling {
        let width = Double(evidence.width), height = Double(evidence.height)
        let inverse = simd_inverse(homography)
        let center = homography * SIMD3(0.5, 0.5, 1)
        guard abs(center.z) > 1e-9 else { return Sampling() }
        let halfWidth = 6.0
        var sampling = Sampling()
        var claimed: [Int: Int] = [:]   // evidence cell → observation index
        func image(_ t: SIMD2<Double>) -> SIMD2<Double>? {
            let p = homography * SIMD3(t.x, t.y, 1)
            guard abs(p.z) > 1e-9, p.z * center.z > 0 else { return nil }
            let x = p.x / p.z * width, y = p.y / p.z * height
            return x.isFinite && y.isFinite ? SIMD2(x, y) : nil
        }
        for (index, polyline) in template.polylines.enumerated() {
            var lastSample: SIMD2<Double>?
            for (a, b) in zip(polyline.points, polyline.points.dropFirst()) {
                let direction = b - a
                let length = simd_length(direction)
                guard length > 1e-9 else { continue }
                let tangent = direction / length
                let normal = SIMD2(-tangent.y, tangent.x)
                let line = SIMD3(normal.x, normal.y, -simd_dot(normal, a))
                // Sample about every half metre of template line; near markings
                // then get many samples and far ones are thinned by spacing.
                let count = max(2, Int((length * 200).rounded(.up)))
                for step in 0...count {
                    let t = a + direction * (Double(step) / Double(count))
                    guard abs(t.x - 0.5) <= reach + 0.5, abs(t.y - 0.5) <= reach + 0.5,
                          let p = image(t), p.x >= 2, p.x < width - 2, p.y >= 2, p.y < height - 2 else { continue }
                    if let lastSample, simd_length(p - lastSample) < 4 { continue }
                    lastSample = p
                    let epsilon = 0.0005
                    guard let ahead = image(t + tangent * epsilon), let behind = image(t - tangent * epsilon),
                          let side = image(t + normal * epsilon) else { continue }
                    let imageTangent = ahead - behind
                    let tangentLength = simd_length(imageTangent)
                    guard tangentLength > 1e-9 else { continue }
                    let n = SIMD2(-imageTangent.y, imageTangent.x) / tangentLength
                    let pixelScale = abs(simd_dot(side - p, n)) / epsilon * evidence.sourceScale
                    guard pixelScale.isFinite, pixelScale > 0 else { continue }
                    sampling.visibleSamples += 1
                    sampling.visiblePerLine[index, default: 0] += 1
                    guard let hit = search(from: p, normal: n, tangent: imageTangent / tangentLength, radius: radius, halfWidth: halfWidth, evidence: evidence) else { continue }
                    let q = inverse * SIMD3(hit.point.x / width, hit.point.y / height, 1)
                    guard abs(q.z) > 1e-9, q.z * (inverse * SIMD3(p.x / width, p.y / height, 1)).z > 0 else { continue }
                    let observation = Observation(line: line, observed: SIMD2(q.x / q.z, q.y / q.z),
                                                  pixelScale: min(pixelScale, 20000), evidence: hit.evidence, polyline: index,
                                                  distance: simd_length(hit.point - p))
                    // One painted mark supports one template line: when two
                    // lines claim the same paint, keep the closer template line.
                    let cell = Int(hit.point.y / 3) * (evidence.width / 3 + 2) + Int(hit.point.x / 3)
                    if let existing = claimed[cell], sampling.observations[existing].polyline != index {
                        if sampling.observations[existing].distance > observation.distance { sampling.observations[existing] = observation }
                        continue
                    }
                    claimed[cell] = sampling.observations.count
                    sampling.observations.append(observation)
                }
            }
        }
        return sampling
    }

    private static func search(from p: SIMD2<Double>, normal n: SIMD2<Double>, tangent: SIMD2<Double>, radius: Double,
                               halfWidth: Double, evidence: Evidence) -> (point: SIMD2<Double>, evidence: Double)? {
        let steps = Int(radius.rounded(.up))
        var scores = [Double](repeating: 0, count: steps * 2 + 1)
        var best: (index: Int, score: Double)?
        for offset in -steps...steps {
            let x = p.x + Double(offset) * n.x, y = p.y + Double(offset) * n.y
            let response = evidence.response(x, y, nx: n.x, ny: n.y, halfWidth: halfWidth)
            scores[offset + steps] = max(0, response.score)
            guard response.value >= 50, response.score >= 24 else { continue }
            // Prefer the nearest of several peaks: a farther marking wins only
            // when it is much stronger, so parallel neighbours are not confused.
            let ranked = response.score * (1 - 0.5 * Double(abs(offset)) / Double(steps))
            if ranked > (best?.score ?? -.infinity) { best = (offset + steps, ranked) }
        }
        guard let best else { return nil }
        let peak = scores[best.index]
        // Thick near markings form a plateau: use its centroid rather than the
        // plateau pixel nearest the current estimate, which would bias the fit.
        var low = best.index, high = best.index
        while low > 0, scores[low - 1] >= peak * 0.6 { low -= 1 }
        while high < scores.count - 1, scores[high + 1] >= peak * 0.6 { high += 1 }
        var offset: Double
        if high > low {
            var weighted = 0.0, total = 0.0
            for index in low...high { weighted += Double(index - steps) * scores[index]; total += scores[index] }
            offset = total > 0 ? weighted / total : Double(best.index - steps)
        } else {
            offset = Double(best.index - steps)
            if best.index > 0, best.index < scores.count - 1 {
                let left = scores[best.index - 1], right = scores[best.index + 1]
                let denominator = left - 2 * peak + right
                if denominator < -1e-6 { offset += max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) }
            }
        }
        let bx = p.x + offset * n.x, by = p.y + offset * n.y
        // The paint must continue along the template line's direction, so a
        // line sample does not settle on a curve or a crossing line.
        let value = Double(evidence.white(bx, by))
        guard Double(evidence.white(bx + 5 * tangent.x, by + 5 * tangent.y)) >= value * 0.4,
              Double(evidence.white(bx - 5 * tangent.x, by - 5 * tangent.y)) >= value * 0.4 else { return nil }
        // A marking is a thin bright stripe: darker on both sides, with turf on
        // at least one. Touchlines at the edge of the grass keep their far side
        // dark; wide bright regions such as tracks, boards and stands fail.
        let margin = halfWidth + 3 + Double(high - low) / 2
        let sideA = SIMD2(bx + margin * n.x, by + margin * n.y), sideB = SIMD2(bx - margin * n.x, by - margin * n.y)
        guard Double(evidence.white(sideA.x, sideA.y)) <= value * 0.4, Double(evidence.white(sideB.x, sideB.y)) <= value * 0.4,
              evidence.isTurf(sideA.x, sideA.y) || evidence.isTurf(sideB.x, sideB.y) else { return nil }
        return (SIMD2(bx, by), min(1, peak / 80))
    }

    // MARK: - Solving

    /// Solves a small correction homography in template space so observed
    /// markings fall on their template lines. Damping keeps unsupported degrees
    /// of freedom at the current alignment instead of inventing them.
    private static func solve(_ observations: [Observation], homography: simd_double3x3, threshold: Double) -> simd_double3x3? {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        var used = 0
        for observation in observations {
            let a = observation.line.x, b = observation.line.y, c = observation.line.z
            let q = observation.observed
            let residual = a * q.x + b * q.y + c
            let pixels = residual * observation.pixelScale
            guard abs(pixels) < threshold else { continue }
            let ratio = pixels / threshold
            let robust = (1 - ratio * ratio) * (1 - ratio * ratio)
            // Residuals are in template units; squaring the local pixel scale
            // makes one pixel of error count the same anywhere in the frame.
            let weight = observation.pixelScale * observation.pixelScale * observation.evidence * robust
            guard weight.isFinite, weight > 0 else { continue }
            let row = [a * q.x, a * q.y, a, b * q.x, b * q.y, b, c * q.x, c * q.y]
            accumulate(&normal, row: row, value: -residual, weight: weight)
            used += 1
        }
        guard used >= 12 else { return nil }
        for point in GroundFieldOverlay.rectangle {
            let cx = Double(point.x), cy = Double(point.y)
            let scale = min(4000, max(1, cornerPixelScale(homography, at: SIMD2(cx, cy))))
            let damping = 0.3 * scale * scale
            accumulate(&normal, row: [cx, cy, 1, 0, 0, 0, -cx * cx, -cx * cy], value: 0, weight: damping)
            accumulate(&normal, row: [0, 0, 0, cx, cy, 1, -cy * cx, -cy * cy], value: 0, weight: damping)
        }
        guard let d = solveNormal(normal) else { return nil }
        let correction = simd_double3x3(rows: [.init(1 + d[0], d[1], d[2]), .init(d[3], 1 + d[4], d[5]), .init(d[6], d[7], 1)])
        return abs(simd_determinant(correction)) > 1e-9 ? correction : nil
    }

    private static func cornerPixelScale(_ homography: simd_double3x3, at t: SIMD2<Double>) -> Double {
        let epsilon = 0.001
        func map(_ p: SIMD2<Double>) -> SIMD2<Double>? {
            let v = homography * SIMD3(p.x, p.y, 1)
            guard abs(v.z) > 1e-9 else { return nil }
            return SIMD2(v.x / v.z * 1920, v.y / v.z * 1080)
        }
        guard let a = map(t), let b = map(t + SIMD2(epsilon, epsilon)) else { return 4000 }
        return simd_length(b - a) / (epsilon * 1.4142)
    }

    private static func accumulate(_ normal: inout [[Double]], row: [Double], value: Double, weight: Double) {
        for i in 0..<8 {
            let wi = row[i] * weight
            guard wi != 0 else { continue }
            for j in 0..<8 { normal[i][j] += wi * row[j] }
            normal[i][8] += wi * value
        }
    }

    private static func solveNormal(_ system: [[Double]]) -> [Double]? {
        var matrix = system
        let scale = matrix.flatMap { $0.prefix(8) }.map(abs).max() ?? 1
        for i in 0..<8 {
            guard let pivot = (i..<8).max(by: { abs(matrix[$0][i]) < abs(matrix[$1][i]) }),
                  abs(matrix[pivot][i]) > scale * 1e-12 else { return nil }
            matrix.swapAt(i, pivot)
            let divisor = matrix[i][i]
            for j in i...8 { matrix[i][j] /= divisor }
            for k in 0..<8 where k != i {
                let factor = matrix[k][i]
                guard factor != 0 else { continue }
                for j in i...8 { matrix[k][j] -= factor * matrix[i][j] }
            }
        }
        let result = matrix.map { $0[8] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    // MARK: - Quality

    private static func quality(_ sampling: Sampling, template: Template, evidence: Evidence) -> Quality {
        var residuals: [Double] = []
        var supportedPerLine: [Int: Int] = [:]
        for observation in sampling.observations {
            let residual = abs(observation.line.x * observation.observed.x + observation.line.y * observation.observed.y + observation.line.z)
            residuals.append(residual * observation.pixelScale)
            supportedPerLine[observation.polyline, default: 0] += 1
        }
        residuals.sort()
        var supportedLines = 0, across = false, along = false
        for (index, visible) in sampling.visiblePerLine where visible >= 3 {
            let supported = supportedPerLine[index] ?? 0
            guard supported >= 3, Double(supported) >= Double(visible) * 0.4 else { continue }
            supportedLines += 1
            if template.polylines[index].across { across = true }
            if template.polylines[index].along { along = true }
        }
        let coverage = sampling.visibleSamples > 0 ? Double(sampling.observations.count) / Double(sampling.visibleSamples) : 0
        return Quality(residualPixels: residuals.isEmpty ? .infinity : residuals[residuals.count / 2],
                       coverage: coverage, supportedLines: supportedLines,
                       acrossSupported: across, alongSupported: along)
    }
}
