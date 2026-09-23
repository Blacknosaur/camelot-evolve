import CoreGraphics
import CoreText
import Foundation

struct AnnotationTextStyle: Codable, Equatable, Sendable {
    enum Alignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case left, center, right
        var id: Self { self }
    }
    enum Weight: String, Codable, CaseIterable, Identifiable, Sendable {
        case regular, bold
        var id: Self { self }
    }
    var alignment: Alignment = .left
    /// Font size as a fraction of source display width; identical at export scale.
    var size: Double = 0.036
    var weight: Weight = .bold
    var background = false
}

extension AnalysisAnnotation {
    var resolvedTextStyle: AnnotationTextStyle { textStyle ?? .init(size: width * 6) }
}

/// Shared metrics for rendering and hit testing, including multiline alignment.
struct AnnotationTextLayout {
    struct Line { let text: CTLine; let origin: CGPoint }
    let lines: [Line]
    let bounds: CGRect

    init(mark: AnalysisAnnotation, frameWidth: CGFloat) {
        let style = mark.resolvedTextStyle
        let size = mark.textStyle == nil ? max(12, frameWidth * mark.width * 6) : max(1, frameWidth * min(0.24, max(0.005, style.size)))
        let font = CTFontCreateWithName((style.weight == .bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): mark.color.cgColor
        ]
        var result: [Line] = [], extent = CGRect.null
        for (index, text) in mark.text.components(separatedBy: .newlines).enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let x: CGFloat = style.alignment == .left ? 0 : style.alignment == .center ? -width / 2 : -width
            let y = CGFloat(index) * size * 1.2
            result.append(.init(text: line, origin: .init(x: x, y: y)))
            extent = extent.union(CGRect(x: x, y: y - ascent, width: max(1, width), height: max(size, ascent + descent)))
        }
        lines = result
        bounds = extent.insetBy(dx: -size * 0.15, dy: -size * 0.1)
    }

    func draw(at anchor: CGPoint, background: Bool, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: anchor.x, y: anchor.y)
        if background {
            context.setShadow(offset: .zero, blur: 0)
            context.setFillColor(CGColor(gray: 0.04, alpha: 0.8))
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: bounds.height * 0.12, cornerHeight: bounds.height * 0.12, transform: nil))
            context.fillPath()
        }
        context.scaleBy(x: 1, y: -1)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.95))
        for line in lines {
            context.textPosition = .init(x: line.origin.x, y: -line.origin.y)
            CTLineDraw(line.text, context)
        }
        context.restoreGState()
    }
}
