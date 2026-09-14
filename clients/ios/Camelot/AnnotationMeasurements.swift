import CoreGraphics
import Foundation

enum AnnotationMeasurements {
    static func text(for mark: AnalysisAnnotation, at time: Double, ground: GroundCalibration?) -> String {
        guard mark.showsSpeed == true else { return mark.text }
        let speed = mark.playerMotion.flatMap { ground?.speed(of: $0, at: time) }
        let value = speed.map { formatted($0 * 3.6, approximate: ground?.isApproximate == true) } ?? "—"
        return [mark.text, "\(value) km/h"].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func distances(for mark: AnalysisAnnotation, at time: Double, ground: GroundCalibration?) -> [(point: CGPoint, text: String)] {
        guard mark.showsDistance == true, mark.fieldLines != true,
              [.line, .arrow, .connection, .zone].contains(mark.tool) else { return [] }
        var points = mark.points(at: time)
        if mark.tool == .zone, mark.linkedPlayers != nil { points = GameAnnotationEffects.convexHull(points) }
        if mark.tool == .zone, let first = points.first, points.count > 2 { points.append(first) }
        return zip(points, points.dropFirst()).map { a, b in
            let distance = ground?.distance(from: a, to: b, at: time)
            let value = distance.map { formatted($0, approximate: ground?.isApproximate == true) } ?? "—"
            return (.init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), "\(value) m")
        }
    }

    private static func formatted(_ value: Double, approximate: Bool) -> String {
        (approximate ? "≈ " : "") + value.formatted(.number.precision(.fractionLength(1)))
    }

    static func drawDistances(for mark: AnalysisAnnotation, at time: Double, ground: GroundCalibration?, frame: CGRect, in context: CGContext) {
        for label in distances(for: mark, at: time, ground: ground) {
            var text = mark; text.tool = .text; text.text = label.text
            text.textStyle = .init(alignment: .center, size: 0.018, weight: .bold, background: true)
            AnnotationTextLayout(mark: text, frameWidth: frame.width).draw(at: .init(x: frame.minX + label.point.x * frame.width,
                                                                                 y: frame.minY + label.point.y * frame.height), background: true, in: context)
        }
    }
}

/// Ground-plane footprints share calibration across all player effects. The
/// body box supplies visible feet; it is never extrapolated through an occlusion.
enum GroundPlayerEffects {
    static func draw(mark: AnalysisAnnotation, rect: CGRect, time: Double, ground: GroundCalibration?, frame: CGRect, width: CGFloat, in context: CGContext) -> Bool {
        guard let ground, ground.mode == .plane, frame.width > 0, frame.height > 0 else { return false }
        let feet = CGPoint(x: (rect.midX - frame.minX) / frame.width, y: (rect.maxY - frame.minY) / frame.height)
        let pulse = mark.effect == .pulse ? 1 + sin((time - mark.start) * 4.4) * 0.1 : 1
        guard let ring = ground.circle(center: feet, radiusMeters: 0.6 * pulse, at: time) else { return false }
        let points = ring.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
        guard !points.isEmpty else { return false }
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        let bounds = path.boundingBox
        guard bounds.width < frame.width * 0.4, bounds.height < frame.height * 0.4 else { return false }
        if mark.tool == .spotlight && (mark.effect ?? .clean) == .clean {
            let shade = CGMutablePath(); shade.addRect(frame); shade.addEllipse(in: rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.08))
            context.addPath(shade); context.setFillColor(CGColor(gray: 0, alpha: 0.5)); context.drawPath(using: .eoFill)
        } else if mark.tool == .spotlight || mark.effect == .radar {
            let top = mark.tool == .spotlight ? frame.minY : rect.minY
            let beam = CGMutablePath(); beam.addLines(between: [.init(x: rect.midX - rect.width * 0.2, y: top),
                .init(x: rect.midX + rect.width * 0.2, y: top), .init(x: bounds.maxX, y: rect.maxY), .init(x: bounds.minX, y: rect.maxY)]); beam.closeSubpath()
            context.saveGState(); context.addPath(beam); context.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [mark.color.cgColor.copy(alpha: 0.02)!, mark.color.cgColor.copy(alpha: 0.25)!] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .init(x: rect.midX, y: top), end: .init(x: rect.midX, y: rect.maxY), options: [])
            }
            context.restoreGState()
        }
        context.setFillColor(mark.color.cgColor.copy(alpha: 0.16)!); context.addPath(path); context.fillPath()
        context.setStrokeColor(mark.color.cgColor); context.setLineWidth(max(1, min(width, bounds.width * 0.04)))
        context.addPath(path); context.strokePath()
        if mark.tool == .player && (mark.effect ?? .clean) != .clean {
            let phase = Int(max(0, time - mark.start) * 12) % points.count
            context.setLineWidth(max(1.5, min(width * 0.6, bounds.width * 0.06)))
            for section in 0..<3 {
                context.move(to: points[(phase + section * 10) % points.count])
                for i in 1...5 { context.addLine(to: points[(phase + section * 10 + i) % points.count]) }
                context.strokePath()
            }
            let marker = max(5, rect.width * 0.2)
            context.move(to: .init(x: rect.midX - marker, y: rect.minY - marker * 2))
            context.addLine(to: .init(x: rect.midX + marker, y: rect.minY - marker * 2))
            context.addLine(to: .init(x: rect.midX, y: rect.minY - marker)); context.closePath()
            context.setFillColor(mark.color.cgColor); context.fillPath()
        }
        return true
    }
}
