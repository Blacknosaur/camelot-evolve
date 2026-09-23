import AppKit
import CoreGraphics

/// Editor-only, screen-sized markers remain visible before a polygon or
/// connection has enough points to render. Never included in exported video.
enum AnalysisConstructionOverlay {
    static func draw(points: [CGPoint], frame: CGRect, in context: CGContext) {
        context.saveGState()
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer {
            NSGraphicsContext.current = previousContext
            context.restoreGState()
        }
        for (index, point) in points.enumerated() {
            let centre = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
            let radius: CGFloat = index == 0 ? 13 : 10
            let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.setShadow(offset: .zero, blur: 4, color: NSColor.black.cgColor)
            context.setFillColor(index == 0 ? NSColor(Theme.signal).cgColor : NSColor.white.cgColor)
            context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(2.5)
            context.fillEllipse(in: dot); context.strokeEllipse(in: dot)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black]
            let number = "\(index + 1)" as NSString
            let size = NSAttributedString(string: number as String, attributes: attributes).size()
            number.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), withAttributes: attributes)
            if index == 0 {
                let label = "START" as NSString
                let labelSize = NSAttributedString(string: label as String, attributes: attributes).size()
                let x = min(frame.maxX - labelSize.width - 8, max(frame.minX + 4, centre.x - labelSize.width / 2))
                let y = centre.y - 34 < frame.minY ? centre.y + 17 : centre.y - 34
                let box = CGRect(x: x - 3, y: y - 2, width: labelSize.width + 6, height: labelSize.height + 4)
                context.setFillColor(NSColor(Theme.signal).cgColor)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath()
                label.draw(at: .init(x: x, y: y), withAttributes: attributes)
            }
        }
    }
}