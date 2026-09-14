import CoreGraphics
import CoreText
import Foundation

/// The editor and the video compositor share the exact same drawing code.
enum AnnotationRenderer {
    static func draw(_ marks: [AnalysisAnnotation], time: Double, in context: CGContext, frame: CGRect, editing: Bool = false, ground: GroundCalibration? = nil) {
        context.saveGState()
        context.clip(to: frame)
        for mark in marks {
            if mark.isHidden == true || mark.tool == .zoom || mark.tool == .loupe { continue }
            if !mark.hasMotion(at: time) { continue }
            let alpha = editing ? (mark.isActiveInEditor(at: time) ? 1.0 : 0) : mark.opacity(at: time)
            guard alpha > 0 else { continue }
            let points = mark.points(at: time).map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
            guard let first = points.first else { continue }
            let last = points.last ?? first
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: max(2, abs(last.x - first.x)), height: max(2, abs(last.y - first.y)))
            let width = max(1, frame.width * mark.width)
            var strokeWidth = width
            let style = mark.lineStyle ?? {
                if mark.tool == .arrow { return .legacyArrow }
                if mark.tool == .connection { return AnnotationLineStyle(pattern: .solid, start: .circle, end: .circle) }
                return .default
            }()
            let path = CGMutablePath()
            context.saveGState()
            let pulse = mark.effect == .pulse ? 0.8 + 0.2 * sin((time - mark.start) * 4.4) : 1
            context.setAlpha(alpha * pulse)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setStrokeColor(mark.color.cgColor)
            context.setFillColor(mark.color.cgColor)
            if let effect = mark.effect, effect != .clean {
                context.setShadow(offset: .zero, blur: max(3, width * 2), color: mark.color.cgColor.copy(alpha: 0.7))
            }
            switch mark.tool {
            case .select, .zoom, .loupe: break
            case .trajectory: PlayerTrajectory.draw(mark: mark, time: time, frame: frame, in: context)
            case .text:
                var label = mark; label.text = AnnotationMeasurements.text(for: mark, at: time, ground: ground)
                AnnotationTextLayout(mark: label, frameWidth: frame.width).draw(at: first, background: mark.resolvedTextStyle.background, in: context)
            case .player:
                if GroundPlayerEffects.draw(mark: mark, rect: rect, time: time, ground: ground, frame: frame, width: width, in: context) { break }
                if let effect = mark.effect, effect != .clean {
                    GameAnnotationEffects.player(rect: rect, mark: mark, time: time, context: context, width: width)
                    break
                }
                let ring = CGRect(x: rect.minX - rect.width * 0.2, y: rect.maxY - rect.width * 0.2, width: rect.width * 1.4, height: max(8, rect.width * 0.4))
                strokeWidth = min(width, ring.height * 0.2)
                context.setFillColor(mark.color.cgColor.copy(alpha: 0.22)!)
                context.fillEllipse(in: ring)
                path.addEllipse(in: ring)
            case .spotlight:
                if GroundPlayerEffects.draw(mark: mark, rect: rect, time: time, ground: ground, frame: frame, width: width, in: context) { break }
                if let effect = mark.effect, effect != .clean {
                    GameAnnotationEffects.spotlight(rect: rect, frame: frame, mark: mark, context: context, width: width)
                    break
                }
                let shade = CGMutablePath(); shade.addRect(frame)
                shade.addEllipse(in: rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.08))
                context.addPath(shade); context.setFillColor(CGColor(gray: 0, alpha: 0.5)); context.drawPath(using: .eoFill)
                path.addEllipse(in: CGRect(x: rect.minX, y: rect.maxY - rect.width * 0.15, width: rect.width, height: rect.width * 0.3))
            case .ellipse:
                path.addEllipse(in: rect)
            case .rectangle:
                path.addRect(rect)
                if mark.effect == .aerial { GameAnnotationEffects.aerial(points: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)], mark: mark, time: time, frame: frame, context: context, width: width) }
            case .zone:
                if mark.fieldLines == true {
                    path.addPath(AnalysisFieldGuide.path(corners: points, layout: mark.fieldLayout ?? .legacy))
                    break
                }
                // Two-point legacy areas retain their original triangle.
                let vertices = points.count >= 3 ? points : [first, CGPoint(x: last.x, y: first.y), last]
                if mark.effect == .aerial {
                    GameAnnotationEffects.aerial(points: vertices, mark: mark, time: time, frame: frame, context: context, width: width)
                } else {
                    GameAnnotationEffects.area(points: vertices, mark: mark, time: time, context: context, width: width, style: style)
                }
                if mark.effect == .wall {
                    GameAnnotationEffects.wall(points: mark.linkedPlayers == nil ? vertices : GameAnnotationEffects.convexHull(vertices), closed: true, mark: mark, time: time, frame: frame, context: context, width: width)
                }
            case .connection:
                GameAnnotationEffects.connection(points: points, mark: mark, time: time, context: context, width: width, style: style)
                if mark.effect == .wall { GameAnnotationEffects.wall(points: points, closed: false, mark: mark, time: time, frame: frame, context: context, width: width) }
            case .pen:
                path.addLines(between: points)
                if points.count == 1 { path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)) }
            case .line, .arrow:
                if mark.effect == .wall, mark.tool == .line { GameAnnotationEffects.wall(points: points, closed: false, mark: mark, time: time, frame: frame, context: context, width: width) }
                path.move(to: first); path.addLine(to: last)
            }
            context.setLineDash(phase: 0, lengths: style.dashLengths(for: strokeWidth))
            context.addPath(path); context.setStrokeColor(CGColor(gray: 0, alpha: 0.5)); context.setLineWidth(strokeWidth + 2); context.strokePath()
            context.addPath(path); context.setStrokeColor(mark.color.cgColor); context.setLineWidth(strokeWidth); context.strokePath()
            if [.line, .arrow, .pen].contains(mark.tool) { drawEndpoints(style, points: points, width: strokeWidth, color: mark.color.cgColor, in: context) }
            context.setLineDash(phase: 0, lengths: [])
            AnnotationMeasurements.drawDistances(for: mark, at: time, ground: ground, frame: frame, in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func drawEndpoints(_ style: AnnotationLineStyle, points: [CGPoint], width: CGFloat, color: CGColor, in context: CGContext) {
        guard let firstIndex = points.indices.first, let lastIndex = points.indices.last, points.count >= 2 else { return }
        let first = points[firstIndex], last = points[lastIndex]
        let next = points.dropFirst().first(where: { hypot($0.x - first.x, $0.y - first.y) > 0.5 }) ?? last
        let previous = points.dropLast().reversed().first(where: { hypot($0.x - last.x, $0.y - last.y) > 0.5 }) ?? first
        func draw(_ endpoint: AnnotationEndpoint, at point: CGPoint, toward other: CGPoint) {
            guard endpoint != .none else { return }
            let radius = max(3, width * 1.8)
            context.saveGState(); context.setLineDash(phase: 0, lengths: []); context.setFillColor(color); context.setStrokeColor(color); context.setLineWidth(width)
            switch endpoint {
            case .point: context.fillEllipse(in: CGRect(x: point.x - radius * 0.55, y: point.y - radius * 0.55, width: radius * 1.1, height: radius * 1.1))
            case .circle: context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            case .arrow:
                let angle = atan2(point.y - other.y, point.x - other.x), head = max(width * 4, 12)
                let path = CGMutablePath(); path.move(to: point); path.addLine(to: CGPoint(x: point.x - cos(angle - 0.5) * head, y: point.y - sin(angle - 0.5) * head)); path.move(to: point); path.addLine(to: CGPoint(x: point.x - cos(angle + 0.5) * head, y: point.y - sin(angle + 0.5) * head)); context.addPath(path); context.strokePath()
            case .none: break
            }
            context.restoreGState()
        }
        draw(style.start, at: first, toward: next); draw(style.end, at: last, toward: previous)
    }
}
