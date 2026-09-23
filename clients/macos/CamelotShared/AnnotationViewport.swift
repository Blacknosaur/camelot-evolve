import CoreGraphics
import Foundation

/// The same source-space zoom drives the workspace, sequence preview and export.
/// Overlapping zoom layers use the topmost visible layer, never multiply together.
enum AnnotationViewport {
    static func sourcePoint(_ point: CGPoint, frame: CGRect, allowsOffscreen: Bool = false) -> CGPoint {
        let x = (point.x - frame.minX) / max(1, frame.width)
        let y = (point.y - frame.minY) / max(1, frame.height)
        return allowsOffscreen ? CGPoint(x: x, y: y) : CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
    /// Inspection is only a viewport change; it must never alter drawing geometry.
    static func inspectionCenter(_ center: CGPoint, zoom: CGFloat) -> CGPoint {
        let inset = 0.5 / max(1, zoom)
        return CGPoint(x: min(1 - inset, max(inset, center.x)), y: min(1 - inset, max(inset, center.y)))
    }

    /// Apply inspection outside authored effects, so their focus cannot cancel a pan.
    static func inspectionTransform(fitted: CGRect, zoom: CGFloat, center: CGPoint) -> CGAffineTransform {
        let viewport = FieldPlacementViewport(zoom: zoom, center: center).frame(fitted: fitted)
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                                 tx: viewport.minX - fitted.minX * zoom,
                                 ty: viewport.minY - fitted.minY * zoom)
    }

    static func transform(marks: [AnalysisAnnotation], time: Double, frame: CGRect, bounds: CGRect) -> CGAffineTransform {
        guard let mark = marks.last(where: { $0.tool == .zoom && $0.opacity(at: time) > 0 }),
              let focus = mark.points(at: time).first, focus.x.isFinite, focus.y.isFinite else { return .identity }
        let ramp = min(max(0, mark.zoomRamp ?? 0.35), (mark.end - mark.start) / 2)
        let fraction = ramp > 0 ? min(1, max(0, min(time - mark.start, mark.end - time) / ramp)) : 1
        let eased = fraction * fraction * (3 - 2 * fraction)
        let scale = 1 + (min(4, max(1, mark.zoomScale ?? 2)) - 1) * eased
        let visible = frame.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return .identity }
        let x = frame.minX + min(1, max(0, focus.x)) * frame.width
        let y = frame.minY + min(1, max(0, focus.y)) * frame.height
        // Interpolate the pan with the zoom so off-centre targets do not jump at In.
        let targetScale = min(4, max(1, mark.zoomScale ?? 2))
        let tx = min(visible.minX - frame.minX * targetScale, max(visible.maxX - frame.maxX * targetScale, visible.midX - x * targetScale))
        let ty = min(visible.minY - frame.minY * targetScale, max(visible.maxY - frame.maxY * targetScale, visible.midY - y * targetScale))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx * eased, ty: ty * eased)
    }
}
