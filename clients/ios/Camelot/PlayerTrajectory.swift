import CoreGraphics
import Foundation
import simd

struct PlayerTrajectoryStyle: Codable, Equatable, Sendable {
    var pastSeconds = 3.0
    var futureSeconds = 3.0
    var futureColor = AnnotationColor(red: 0.2, green: 0.8, blue: 1)
}

enum PlayerTrajectory {
    /// Bounded, source-time paths. No extrapolation and no bridging tracking gaps.
    /// Camera compensation maps historical feet into the current camera view.
    static func paths(mark: AnalysisAnnotation, time: Double, future: Bool) -> [[CGPoint]] {
        guard let motion = mark.displayPlayerMotion, let first = motion.samples.first, let last = motion.samples.last,
              time >= first.time, time <= last.time, let current = motion.box(at: time) else { return [] }
        let drawn = mark.points(at: time)
        guard let left = drawn.first, let right = drawn.last else { return [] }
        let style = mark.trajectoryStyle ?? .init()
        let duration = min(10, max(0, future ? style.futureSeconds : style.pastSeconds))
        guard duration > 0 else { return [] }
        let lower = future ? time : max(first.time, time - duration)
        let upper = future ? min(last.time, time + duration) : time
        guard upper > lower else { return [] }
        let count = min(120, max(1, Int(ceil((upper - lower) * 24))))
        let offset = CGPoint(x: (left.x + right.x) / 2 - current.midX, y: max(left.y, right.y) - current.maxY)
        let camera = mark.trajectoryCameraMotion
        let now = camera?.transform(at: time)
        if camera != nil && now == nil { return [] }
        var paths: [[CGPoint]] = [], path: [CGPoint] = []
        var previousTime: Double?
        func flush() { if path.count > 1 { paths.append(path) }; path = []; previousTime = nil }
        for index in 0...count {
            let seconds = lower + (upper - lower) * Double(index) / Double(count)
            if let previousTime, motion.gaps?.contains(where: { $0.lowerBound <= seconds && $0.upperBound >= previousTime }) == true { flush() }
            guard let box = motion.box(at: seconds) else { flush(); continue }
            var point = CGPoint(x: box.midX, y: box.maxY)
            if let camera, let now {
                guard let then = camera.transform(at: seconds), abs(then.matrix.determinant) > 0.00001,
                      let projected = CameraTransform(now.matrix * then.matrix.inverse).point(point) else { flush(); continue }
                point = projected
            }
            point.x += offset.x; point.y += offset.y
            path.append(point); previousTime = seconds
        }
        flush()
        return paths
    }

    static func draw(mark: AnalysisAnnotation, time: Double, frame: CGRect, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        let width = max(1.5, frame.width * mark.width * 0.6)
        for future in [false, true] {
            let color = future ? (mark.trajectoryStyle ?? .init()).futureColor : mark.color
            for points in paths(mark: mark, time: time, future: future) {
                let mapped = points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                let path = CGMutablePath(); path.addLines(between: mapped)
                context.setLineDash(phase: 0, lengths: future ? [width * 3, width * 2] : [])
                context.setLineWidth(width + 2); context.setStrokeColor(CGColor(gray: 0, alpha: 0.6)); context.addPath(path); context.strokePath()
                context.setLineWidth(width); context.setStrokeColor(color.cgColor); context.addPath(path); context.strokePath()
                if future, let end = mapped.last, let previous = mapped.dropLast().last, hypot(end.x - previous.x, end.y - previous.y) > 0.3 {
                    context.setLineDash(phase: 0, lengths: [])
                    let angle = atan2(end.y - previous.y, end.x - previous.x), head = max(6, width * 3)
                    context.move(to: CGPoint(x: end.x - cos(angle - 0.5) * head, y: end.y - sin(angle - 0.5) * head))
                    context.addLine(to: end)
                    context.addLine(to: CGPoint(x: end.x - cos(angle + 0.5) * head, y: end.y - sin(angle + 0.5) * head)); context.strokePath()
                }
            }
        }
    }
}
