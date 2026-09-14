import UIKit

/// Editor-only, screen-sized markers remain visible before a polygon or
/// connection has enough points to render. Never included in exported video.
enum AnalysisConstructionOverlay {
    static func draw(points: [CGPoint], frame: CGRect, in context: CGContext) {
        context.saveGState()
        for (index, point) in points.enumerated() {
            let centre = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
            let radius: CGFloat = index == 0 ? 13 : 10
            let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.setShadow(offset: .zero, blur: 4, color: UIColor.black.cgColor)
            context.setFillColor(index == 0 ? UIColor(Theme.signal).cgColor : UIColor.white.cgColor)
            context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(2.5)
            context.fillEllipse(in: dot); context.strokeEllipse(in: dot)
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: UIColor.black]
            let number = "\(index + 1)" as NSString, size = number.size(withAttributes: attributes)
            UIGraphicsPushContext(context)
            number.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), withAttributes: attributes)
            if index == 0 {
                let label = "START" as NSString
                let labelSize = label.size(withAttributes: attributes)
                let x = min(frame.maxX - labelSize.width - 8, max(frame.minX + 4, centre.x - labelSize.width / 2))
                let y = centre.y - 34 < frame.minY ? centre.y + 17 : centre.y - 34
                let box = CGRect(x: x - 3, y: y - 2, width: labelSize.width + 6, height: labelSize.height + 4)
                context.setFillColor(UIColor(Theme.signal).cgColor)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath()
                label.draw(at: .init(x: x, y: y), withAttributes: attributes)
            }
            UIGraphicsPopContext()
        }
        context.restoreGState()
    }
}
