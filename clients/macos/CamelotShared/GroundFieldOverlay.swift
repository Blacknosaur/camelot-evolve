import CoreGraphics
import Foundation
import simd

/// The semantic reference survives reopening, separately from metric corner data.
struct GroundFieldReference: Codable, Equatable, Sendable {
    var landmark: GroundLandmark
    var pitchLength: Double = 105
    var pitchWidth: Double = 68
}

/// Shared geometry for live alignment, the reference diagram and verification.
/// World X runs across the pitch; Y runs away from the chosen goal line.
enum GroundFieldOverlay {
    static let rectangle: [CGPoint] = [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]

    static func referenceAnchors(_ landmark: GroundLandmark) -> [CGPoint] {
        landmark == .centreCircle
            ? [.init(x: 0.5, y: 0), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1), .init(x: 0, y: 0.5)]
            : rectangle
    }

    static func seed(_ landmark: GroundLandmark, goalOnRight: Bool = true) -> [CGPoint] {
        let quad: [CGPoint] = [.init(x: 0.65, y: 0.34), .init(x: 0.88, y: 0.67), .init(x: 0.30, y: 0.90), .init(x: 0.20, y: 0.46)]
        let transform = AnalysisFieldGuide.projection(corners: quad)!
        let anchors = landmark.mode == .plane ? referenceAnchors(landmark) : [.init(x: 0.3, y: 0.55), .init(x: 0.7, y: 0.55)]
        return anchors.map {
            let point = landmark.mode == .plane ? transform.point($0)! : $0
            return goalOnRight ? point : CGPoint(x: 1 - point.x, y: point.y)
        }
    }

    static func calibrationCorners(anchors: [CGPoint], landmark: GroundLandmark) -> [CGPoint] {
        guard landmark == .centreCircle else { return anchors }
        guard let target = AnalysisFieldGuide.projection(corners: anchors),
              let source = AnalysisFieldGuide.projection(corners: referenceAnchors(landmark)) else { return [] }
        let matrix = target.matrix * simd_inverse(source.matrix)
        let center = matrix * SIMD3<Float>(0.5, 0.5, 1)
        let corners = rectangle.compactMap { point -> CGPoint? in
            let p = matrix * SIMD3(Float(point.x), Float(point.y), 1)
            guard p.z * center.z > 0, abs(p.z) > 0.00001 else { return nil }
            return CGPoint(x: Double(p.x / p.z), y: Double(p.y / p.z))
        }
        return corners.count == 4 && AnalysisFieldGuide.projection(corners: corners) != nil ? corners : []
    }

    static func editingAnchors(_ calibration: GroundCalibration, landmark: GroundLandmark) -> [CGPoint] {
        guard landmark == .centreCircle, let projection = AnalysisFieldGuide.projection(corners: calibration.points) else { return calibration.points }
        return referenceAnchors(landmark).compactMap { projection.point($0) }
    }

    static func handleNames(_ landmark: GroundLandmark, count: Int) -> [String] {
        switch landmark {
        case .centreCircle: ["Circle · goal side", "Halfway · near side", "Circle · opposite side", "Halfway · far side"]
        case .penaltyArea, .goalArea: ["Goal line · far corner", "Goal line · near corner", "Box · near corner", "Box · far corner"]
        case .halfPitch: ["Goal line · far corner", "Goal line · near corner", "Halfway · near corner", "Halfway · far corner"]
        case .fullPitch: ["Goal line · far corner", "Goal line · near corner", "Opposite goal · near", "Opposite goal · far"]
        case .goalWidth: ["First post · ground", "Second post · ground"]
        case .custom: (1...count).map { "Reference point \($0)" }
        }
    }

    /// Ground paths in metres, relative to the calibrated reference rectangle.
    static func worldLines(reference: GroundFieldReference, length: Double, depth: Double) -> [[CGPoint]] {
        guard length > 0, depth > 0, length.isFinite, depth.isFinite,
              reference.pitchLength.isFinite, reference.pitchWidth.isFinite,
              reference.pitchLength > 33, reference.pitchWidth > 40.32 else { return [] }
        let landmark = reference.landmark
        guard landmark.mode == .plane, landmark != .custom else { return [] }
        let pitchWidth = [.halfPitch, .fullPitch].contains(landmark) ? length : reference.pitchWidth
        let pitchLength = landmark == .fullPitch ? depth : landmark == .halfPitch ? depth * 2 : reference.pitchLength
        let centerX = length / 2
        let goalY = landmark == .centreCircle ? depth / 2 - pitchLength / 2 : 0
        let left = centerX - pitchWidth / 2, right = centerX + pitchWidth / 2
        var lines: [[CGPoint]] = []
        func line(_ points: [CGPoint]) { lines.append(points) }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            line([.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h), .init(x: x, y: y)])
        }
        box(left, goalY, pitchWidth, pitchLength)
        line([.init(x: left, y: goalY + pitchLength / 2), .init(x: right, y: goalY + pitchLength / 2)])
        let radius = landmark == .centreCircle ? length / 2 : 9.15
        line((0...64).map { i in
            let a = Double(i) / 64 * 2 * .pi
            return CGPoint(x: centerX + cos(a) * radius, y: goalY + pitchLength / 2 + sin(a) * radius)
        })
        for side in [0, 1] {
            let y = goalY + Double(side) * pitchLength, sign = side == 0 ? 1.0 : -1.0
            let penaltyWidth = landmark == .penaltyArea ? length : 40.32
            let penaltyDepth = landmark == .penaltyArea ? depth : 16.5
            let goalWidth = landmark == .goalArea ? length : 18.32
            let goalDepth = landmark == .goalArea ? depth : 5.5
            box(centerX - penaltyWidth / 2, y, penaltyWidth, sign * penaltyDepth)
            box(centerX - goalWidth / 2, y, goalWidth, sign * goalDepth)
            // Goal mouth on the floor, not the vertical net.
            line([.init(x: centerX - 3.66, y: y), .init(x: centerX + 3.66, y: y)])
            let spotY = y + sign * 11
            line([.init(x: centerX - 0.15, y: spotY), .init(x: centerX + 0.15, y: spotY)])
            let angle = acos(min(1, max(-1, (penaltyDepth - 11) / 9.15)))
            line((0...32).map { i in
                let a = -angle + Double(i) / 32 * angle * 2
                return CGPoint(x: centerX + sin(a) * 9.15, y: spotY + sign * cos(a) * 9.15)
            })
        }
        return lines
    }

    static func path(calibration: GroundCalibration, frame: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard calibration.valid, calibration.mode == .plane,
              let reference = calibration.fieldReference,
              let projection = AnalysisFieldGuide.projection(corners: calibration.points) else { return path }
        let matrix = projection.matrix, center = matrix * SIMD3<Float>(0.5, 0.5, 1)
        for line in worldLines(reference: reference, length: calibration.lengthMeters, depth: calibration.widthMeters) {
            var continuing = false
            for point in line {
                let p = matrix * SIMD3(Float(point.x / calibration.lengthMeters), Float(point.y / calibration.widthMeters), 1)
                guard p.z.isFinite, p.z * center.z > 0, abs(p.z) > 0.0001 else { continuing = false; continue }
                let x = Double(p.x / p.z), y = Double(p.y / p.z)
                guard x.isFinite, y.isFinite, abs(x) < 32, abs(y) < 32 else { continuing = false; continue }
                let mapped = CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
                if continuing { path.addLine(to: mapped) } else { path.move(to: mapped) }
                continuing = true
            }
        }
        return path
    }

    static func referencePath(calibration: GroundCalibration, frame: CGRect) -> CGPath {
        let path = CGMutablePath()
        func mapped(_ point: CGPoint) -> CGPoint { .init(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height) }
        if calibration.fieldReference?.landmark == .centreCircle,
           let projection = AnalysisFieldGuide.projection(corners: calibration.points) {
            let circle = (0...64).compactMap { i in
                let a = Double(i) / 64 * 2 * .pi
                return projection.point(.init(x: 0.5 + cos(a) * 0.5, y: 0.5 + sin(a) * 0.5)).map(mapped)
            }
            if circle.count == 65 { path.addLines(between: circle) }
        } else {
            path.addLines(between: calibration.points.map(mapped))
            if calibration.mode == .plane, calibration.points.count == 4 { path.closeSubpath() }
        }
        return path
    }
}
