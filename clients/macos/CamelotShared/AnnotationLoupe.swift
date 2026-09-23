import CoreGraphics
import CoreImage
import Foundation

/// A fixed-size circular detail view attached to an annotation's tracked point.
struct AnnotationLoupeStyle: Codable, Equatable, Sendable {
    var magnification: Double = 2
    /// Lens diameter as a fraction of the source display-frame width.
    var diameter: Double = 0.22
    /// Lens centre offset from the tracked point, in source-frame fractions.
    var offset: CGPoint = CGPoint(x: 0, y: -0.18)
}

struct AnnotationLoupeGeometry: Equatable, Sendable {
    let focus: CGPoint
    let center: CGPoint
    let radius: CGFloat
    let sourceRadius: CGFloat

    var lensRect: CGRect { CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2) }

    static func make(style: AnnotationLoupeStyle, focus: CGPoint, frame: CGRect, bounds: CGRect) -> Self? {
        guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0,
              focus.x.isFinite, focus.y.isFinite, style.diameter.isFinite, style.magnification.isFinite,
              style.offset.x.isFinite, style.offset.y.isFinite else { return nil }
        let diameter = CGFloat(min(1, max(0.02, style.diameter))) * frame.width
        let radius = min(diameter, min(bounds.width, bounds.height)) / 2
        let raw = CGPoint(x: focus.x + CGFloat(style.offset.x) * frame.width,
                          y: focus.y + CGFloat(style.offset.y) * frame.height)
        let center = CGPoint(x: min(bounds.maxX - radius, max(bounds.minX + radius, raw.x)),
                             y: min(bounds.maxY - radius, max(bounds.minY + radius, raw.y)))
        return .init(focus: focus, center: center, radius: radius,
                     sourceRadius: radius / CGFloat(min(20, max(1, style.magnification))))
    }

    static func make(mark: AnalysisAnnotation, time: Double, frame: CGRect, bounds: CGRect) -> Self? {
        guard mark.tool == .loupe, mark.opacity(at: time) > 0,
              mark.hasMotion(at: time), let focus = mark.points(at: time).first else { return nil }
        let style = mark.loupeStyle ?? .init()
        let point = CGPoint(x: frame.minX + focus.x * frame.width, y: frame.minY + focus.y * frame.height)
        return make(style: style, focus: point, frame: frame, bounds: bounds)
    }
}

enum AnnotationLoupeRenderer {
    /// Composites a lens from the already transformed, unannotated frame. This
    /// deliberately takes `base`, never an annotation-composited image, to avoid recursion.
    static func image(_ base: CIImage, geometry: AnnotationLoupeGeometry, bounds: CGRect, over background: CIImage? = nil, opacity: CGFloat = 1) -> CIImage {
        let h = bounds.minY + bounds.maxY
        let focus = CGPoint(x: geometry.focus.x, y: h - geometry.focus.y)
        let centre = CGPoint(x: geometry.center.x, y: h - geometry.center.y)
        let r = geometry.sourceRadius
        let crop = CGRect(x: focus.x - r, y: focus.y - r, width: r * 2, height: r * 2)
        let scale = geometry.radius / max(0.001, r)
        let lens = base.composited(over: CIImage(color: .black)).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: centre.x - geometry.radius, y: centre.y - geometry.radius))
            .cropped(to: CGRect(x: centre.x - geometry.radius, y: centre.y - geometry.radius,
                                width: geometry.radius * 2, height: geometry.radius * 2))
        let radial = CIFilter(name: "CIRadialGradient")!
        radial.setValue(CIVector(x: centre.x, y: centre.y), forKey: "inputCenter")
        radial.setValue(geometry.radius, forKey: "inputRadius0")
        radial.setValue(geometry.radius + 1, forKey: "inputRadius1")
        let alpha = min(1, max(0, opacity))
        radial.setValue(CIColor(red: alpha, green: alpha, blue: alpha), forKey: "inputColor0")
        radial.setValue(CIColor.black, forKey: "inputColor1")
        let mask = (radial.outputImage ?? CIImage(color: .black)).cropped(to: lens.extent)
        return lens.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background ?? base, kCIInputMaskImageKey: mask])
    }

    static func drawBorder(_ geometry: AnnotationLoupeGeometry, in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(max(2, geometry.radius * 0.035))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.strokeEllipse(in: geometry.lensRect)
        context.setLineWidth(max(1, geometry.radius * 0.012))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        let dx = geometry.center.x - geometry.focus.x, dy = geometry.center.y - geometry.focus.y
        let distance = max(0.001, hypot(dx, dy))
        if distance > geometry.radius {
        context.move(to: geometry.focus)
        context.addLine(to: CGPoint(x: geometry.center.x - dx / distance * geometry.radius,
                                    y: geometry.center.y - dy / distance * geometry.radius))
        context.strokePath()
        }
        context.restoreGState()
    }
}
