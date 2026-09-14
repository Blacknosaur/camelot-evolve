import CoreGraphics
import Foundation

/// Time-driven effects use source seconds, so paused frames, scrubbing and
/// exports always produce the same animation without a separate display timer.
enum GameAnnotationEffects {
    /// A screen-space light curtain anchored to the evaluated ground points.
    /// It follows the same camera/player/keyframe motion as the underlying shape.
    static func wall(points: [CGPoint], closed: Bool, mark: AnalysisAnnotation, time: Double, frame: CGRect, context: CGContext, width: CGFloat) {
        guard points.count >= 2 else { return }
        var edges = Array(zip(points, points.dropFirst()))
        if closed, let first = points.first, let last = points.last { edges.append((last, first)) }
        edges.sort { ($0.0.y + $0.1.y) < ($1.0.y + $1.1.y) }
        let height = frame.height * min(0.5, max(0.02, mark.wallHeight ?? 0.18))
        let opacity = min(0.8, max(0.05, mark.wallOpacity ?? 0.32))
        func top(_ point: CGPoint) -> CGPoint {
            let depth = min(1, max(0, (point.y - frame.minY) / max(1, frame.height)))
            return .init(x: point.x, y: point.y - height * (0.55 + depth * 0.45))
        }
        context.saveGState()
        for (a, b) in edges {
            guard hypot(a.x - b.x, a.y - b.y) > 0.5 else { continue }
            let upA = top(a), upB = top(b)
            let face = CGMutablePath(); face.addLines(between: [a, b, upB, upA]); face.closeSubpath()
            context.saveGState(); context.addPath(face); context.clip()
            let colors = [mark.color.cgColor.copy(alpha: 0.015)!, mark.color.cgColor.copy(alpha: opacity)!] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .init(x: (a.x + b.x) / 2, y: min(upA.y, upB.y)),
                                           end: .init(x: (a.x + b.x) / 2, y: max(a.y, b.y)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
            context.setLineWidth(max(1, width * 0.22))
            context.setStrokeColor(mark.color.cgColor.copy(alpha: 0.55)!)
            context.move(to: upA); context.addLine(to: a); context.addLine(to: b); context.addLine(to: upB); context.strokePath()
            // Subtle rising light band; deterministic during scrubbing/export.
            let phase = CGFloat((max(0, time - mark.start) / 2).truncatingRemainder(dividingBy: 1))
            context.setStrokeColor(mark.color.cgColor.copy(alpha: (1 - phase) * 0.5)!)
            context.move(to: .init(x: a.x, y: a.y + (upA.y - a.y) * phase))
            context.addLine(to: .init(x: b.x, y: b.y + (upB.y - b.y) * phase)); context.strokePath()
        }
        context.restoreGState()
    }

    static func spotlight(rect: CGRect, frame: CGRect, mark: AnalysisAnnotation, context: CGContext, width: CGFloat) {
        let radius = max(9, rect.width * 0.8)
        let feet = CGPoint(x: rect.midX, y: rect.maxY)
        let beam = CGMutablePath()
        beam.move(to: .init(x: feet.x - radius * 0.35, y: frame.minY))
        beam.addLine(to: .init(x: feet.x + radius * 0.35, y: frame.minY))
        beam.addLine(to: .init(x: feet.x + radius, y: feet.y))
        beam.addLine(to: .init(x: feet.x - radius, y: feet.y)); beam.closeSubpath()
        context.saveGState(); context.addPath(beam); context.clip()
        let colors = [mark.color.cgColor.copy(alpha: 0.04)!, mark.color.cgColor.copy(alpha: 0.28)!] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .init(x: feet.x, y: frame.minY), end: feet, options: [])
        }
        context.restoreGState()
        let halo = CGRect(x: feet.x - radius, y: feet.y - radius * 0.22, width: radius * 2, height: radius * 0.44)
        context.setFillColor(mark.color.cgColor.copy(alpha: 0.2)!); context.fillEllipse(in: halo)
        context.setLineWidth(max(1.5, min(width, radius * 0.1))); context.strokeEllipse(in: halo)
    }

    static func player(rect: CGRect, mark: AnalysisAnnotation, time: Double, context: CGContext, width: CGFloat) {
        let phase = (time - mark.start) * 2.2
        let pulse = mark.effect == .pulse ? 1 + sin(phase * 2) * 0.1 : 1
        let radius = max(9, rect.width * 0.78) * pulse
        let feet = CGPoint(x: rect.midX, y: rect.maxY)
        let ring = CGRect(x: feet.x - radius, y: feet.y - radius * 0.25, width: radius * 2, height: radius * 0.5)
        context.setFillColor(mark.color.cgColor.copy(alpha: 0.13)!)
        context.fillEllipse(in: ring)
        context.setLineWidth(max(1.5, min(width, radius * 0.10)))
        context.strokeEllipse(in: ring)
        context.saveGState()
        context.translateBy(x: feet.x, y: feet.y); context.scaleBy(x: 1, y: 0.25)
        for index in 0..<3 {
            let angle = phase + Double(index) * .pi * 2 / 3
            context.addArc(center: .zero, radius: radius * 1.18, startAngle: angle, endAngle: angle + 1.25, clockwise: false)
            context.strokePath()
        }
        context.restoreGState()
        // Floating controller marker; no invented player name, speed or rating.
        let marker = max(6, rect.width * 0.24)
        let y = rect.minY - marker * 1.5 - sin(phase) * marker * 0.15
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: rect.midX - marker, y: y - marker))
        triangle.addLine(to: CGPoint(x: rect.midX + marker, y: y - marker))
        triangle.addLine(to: CGPoint(x: rect.midX, y: y)); triangle.closeSubpath()
        context.setFillColor(mark.color.cgColor); context.addPath(triangle); context.fillPath()
        if mark.effect == .radar {
            context.saveGState()
            let beam = CGMutablePath()
            beam.move(to: CGPoint(x: feet.x - radius, y: feet.y))
            beam.addLine(to: CGPoint(x: feet.x - radius * 0.25, y: rect.minY - marker))
            beam.addLine(to: CGPoint(x: feet.x + radius * 0.25, y: rect.minY - marker))
            beam.addLine(to: CGPoint(x: feet.x + radius, y: feet.y)); beam.closeSubpath()
            context.addPath(beam); context.clip()
            let colors = [mark.color.cgColor.copy(alpha: 0.02)!, mark.color.cgColor.copy(alpha: 0.20)!] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: feet.x, y: rect.minY), end: feet, options: [])
            }
            context.restoreGState()
        }
    }

    static func area(points: [CGPoint], mark: AnalysisAnnotation, time: Double, context: CGContext, width: CGFloat, style: AnnotationLineStyle = .default) {
        let points = mark.linkedPlayers == nil ? points : convexHull(points)
        guard points.count >= 3 else { return }
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        context.setFillColor(mark.color.cgColor.copy(alpha: CGFloat(mark.areaFill ?? 0.18))!)
        context.addPath(path); context.fillPath()
        context.setLineWidth(max(1.5, width * 0.5)); context.setLineDash(phase: 0, lengths: style.dashLengths(for: max(1.5, width * 0.5))); context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
        if (mark.effect ?? .clean) != .clean {
            context.saveGState(); context.addPath(path); context.clip()
            context.setShadow(offset: .zero, blur: 0)
            context.setStrokeColor(mark.color.cgColor.copy(alpha: 0.20)!)
            context.setLineWidth(max(0.5, width * 0.16))
            let box = path.boundingBox, spacing = max(12, box.width / 12)
            var x = box.minX - box.height
            var stripeCount = 0
            while x < box.maxX && stripeCount < 256 {
                context.move(to: CGPoint(x: x, y: box.maxY)); context.addLine(to: CGPoint(x: x + box.height, y: box.minY)); x += spacing; stripeCount += 1
            }
            context.strokePath(); context.restoreGState()
            if mark.lineStyle == nil {
                context.setLineDash(phase: -CGFloat(time - mark.start) * 24, lengths: [8, 12])
                context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    static func connection(points: [CGPoint], mark: AnalysisAnnotation, time: Double, context: CGContext, width: CGFloat, style: AnnotationLineStyle = .default) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath(); path.addLines(between: points)
        context.setLineWidth(max(1, width * 0.45))
        if mark.lineStyle == nil {
            context.setStrokeColor(mark.color.cgColor.copy(alpha: 0.45)!)
            context.addPath(path); context.strokePath()
        }
        context.setStrokeColor(mark.color.cgColor)
        if style.pattern != .solid { context.setLineDash(phase: 0, lengths: style.dashLengths(for: max(1, width * 0.45))) }
        if (mark.effect ?? .clean) != .clean, mark.lineStyle == nil, style.pattern == .solid { context.setLineDash(phase: -CGFloat(time - mark.start) * 32, lengths: [10, 8]) }
        context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
        drawConnectionEndpoints(style, points: points, width: width, context: context, color: mark.color.cgColor)
        if (mark.effect ?? .clean) != .clean {
            let t = CGFloat((time - mark.start).truncatingRemainder(dividingBy: 1.6) / 1.6)
            context.setFillColor(CGColor(gray: 1, alpha: 0.95))
            for (a, b) in zip(points, points.dropFirst()) {
                let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                let radius = max(2, width * 0.55)
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    private static func drawConnectionEndpoints(_ style: AnnotationLineStyle, points: [CGPoint], width: CGFloat, context: CGContext, color: CGColor) {
        guard let first = points.first, let last = points.last else { return }
        func draw(_ endpoint: AnnotationEndpoint, at point: CGPoint, toward other: CGPoint) {
            let radius = max(4, width * 1.6); context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(max(1, width * 0.45))
            switch endpoint {
            case .circle: context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius * 0.55, width: radius * 2, height: radius * 1.1))
            case .point: context.fillEllipse(in: CGRect(x: point.x - radius * 0.45, y: point.y - radius * 0.45, width: radius * 0.9, height: radius * 0.9))
            case .arrow:
                let angle = atan2(point.y - other.y, point.x - other.x), head = max(width * 4, 12); context.move(to: point); context.addLine(to: CGPoint(x: point.x - cos(angle - 0.5) * head, y: point.y - sin(angle - 0.5) * head)); context.move(to: point); context.addLine(to: CGPoint(x: point.x - cos(angle + 0.5) * head, y: point.y - sin(angle + 0.5) * head)); context.strokePath()
            case .none: break
            }
        }
        draw(style.start, at: first, toward: points.dropFirst().first(where: { $0 != first }) ?? last)
        draw(style.end, at: last, toward: points.dropLast().reversed().first(where: { $0 != last }) ?? first)
    }

    /// Aerial tactical treatment: a translucent ground plane, soft contact
    /// shadow, and elevated curved roof edges. This is deliberately stylised
    /// screen-space depth, not a claim about recovered camera geometry.
    static func aerial(points: [CGPoint], mark: AnalysisAnnotation, time: Double, frame: CGRect, context: CGContext, width: CGFloat) {
        guard points.count >= 3 else { return }
        let vertices = mark.linkedPlayers == nil ? points : convexHull(points)
        let ground = CGMutablePath(); ground.addLines(between: vertices); ground.closeSubpath()
        context.saveGState(); context.addPath(ground); context.clip()
        context.setFillColor(mark.color.cgColor.copy(alpha: min(0.3, max(0.06, CGFloat(mark.areaFill ?? 0.14))))!); context.fill(frame)
        context.restoreGState()
        context.saveGState(); context.setShadow(offset: CGSize(width: 0, height: max(2, frame.height * 0.012)), blur: max(4, frame.width * 0.018), color: CGColor(gray: 0, alpha: 0.26)); context.setFillColor(CGColor(gray: 0, alpha: 0.16)); context.addPath(ground); context.fillPath(); context.restoreGState()
        let height = frame.height * min(0.5, max(0.02, mark.wallHeight ?? 0.18))
        let opacity = min(0.8, max(0.05, mark.wallOpacity ?? 0.32))
        let roofWidth = max(1.5, width * 0.45)
        context.saveGState(); context.setLineCap(.round); context.setLineJoin(.round); context.setLineDash(phase: -CGFloat(time - mark.start) * 10, lengths: [roofWidth * 5, roofWidth * 4]); context.setLineWidth(roofWidth); context.setStrokeColor(mark.color.cgColor.copy(alpha: CGFloat(opacity))!)
        for (a, b) in zip(vertices, Array(vertices.dropFirst()) + [vertices[0]]) {
            let upA = CGPoint(x: a.x, y: a.y - height * 0.65), upB = CGPoint(x: b.x, y: b.y - height * 0.65)
            let path = CGMutablePath(); path.move(to: upA); path.addQuadCurve(to: upB, control: CGPoint(x: (upA.x + upB.x) / 2, y: min(upA.y, upB.y) - height * 0.18)); context.addPath(path); context.strokePath()
        }
        context.restoreGState()
    }

    /// Player areas stay a valid envelope even when two players exchange order.
    /// Hand-drawn areas retain the user's authored (including concave) polygon.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in points {
                while result.count >= 2 {
                    let a = result[result.count - 2], b = result[result.count - 1]
                    if (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) > 0 { break }
                    result.removeLast()
                }
                result.append(point)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(Array(sorted.reversed())).dropLast())
    }
}
