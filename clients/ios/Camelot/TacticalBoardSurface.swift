import CoreGraphics
import UIKit

// MARK: - Contract

/// CONTRACT: the playing surface (style + markings + goals, no elements) as a top-down texture.
/// The 3D scene maps this onto its ground plane, so 2D and 3D share one look.
/// The image covers the field from normalised (0,0) at top-left to (1,1) at bottom-right,
/// with x along `BoardFieldType.meters.width`, plus exactly `apronMeters` of surround on every side.
extension BoardRenderer {
    static func surfaceImage(field: BoardFieldType, style: BoardFieldStyle, pixelsPerMeter: CGFloat, apronMeters: CGFloat = 0) -> CGImage? {
        BoardSurfacePainter.image(field: field, style: style, pixelsPerMeter: pixelsPerMeter, apron: max(0, apronMeters))
    }
}

extension BoardFieldStyle {
    /// Flat stand-in for the painted surface, close to its average colour. Small previews (library tiles,
    /// inspector thumbnails) use this instead of baking a whole pitch for a 58 pt icon and evicting the
    /// editor's canvas from the surface cache.
    var previewColor: UIColor {
        switch self {
        case .grass: UIColor(red: 0.30, green: 0.55, blue: 0.26, alpha: 1)
        case .night: UIColor(red: 0.11, green: 0.30, blue: 0.17, alpha: 1)
        case .classic: UIColor(red: 0.962, green: 0.958, blue: 0.94, alpha: 1)
        case .chalk: UIColor(red: 0.15, green: 0.185, blue: 0.18, alpha: 1)
        case .court: UIColor(red: 0.79, green: 0.60, blue: 0.40, alpha: 1)
        }
    }
}

// MARK: - Painter

/// Paints fields in metres: origin at the field's top-left corner, x along the length axis.
/// Pure and deterministic (seeded noise), so thumbnails, exports and the 3D texture match the editor.
enum BoardSurfacePainter {
    /// Run-off drawn around the lines in the 2D board; goals and nets sit inside it.
    static func apronMeters(_ field: BoardFieldType) -> CGFloat {
        switch field {
        case .footballFull: 5
        case .footballHalf: 4
        case .futsal: 2.6
        case .basketball: 2
        case .blank: 1.2
        }
    }

    static func image(field: BoardFieldType, style: BoardFieldStyle, pixelsPerMeter: CGFloat, apron: CGFloat) -> CGImage? {
        let meters = field.meters
        let width = Int(((meters.width + 2 * apron) * pixelsPerMeter).rounded())
        let height = Int(((meters.height + 2 * apron) * pixelsPerMeter).rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip so row 0 of the image is y = -apron (top), matching UIKit orientation.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        cg.scaleBy(x: CGFloat(width) / (meters.width + 2 * apron), y: CGFloat(height) / (meters.height + 2 * apron))
        cg.translateBy(x: apron, y: apron)
        cg.interpolationQuality = .high
        draw(field: field, style: style, apron: apron, pixelsPerMeter: pixelsPerMeter, in: cg)
        return cg.makeImage()
    }

    /// Draws turf, markings and goals covering the field plus `apron` metres on every side.
    static func draw(field: BoardFieldType, style: BoardFieldStyle, apron: CGFloat, pixelsPerMeter ppm: CGFloat, in cg: CGContext) {
        let meters = field.meters
        let region = CGRect(x: -apron, y: -apron, width: meters.width + 2 * apron, height: meters.height + 2 * apron)
        let fieldRect = CGRect(origin: .zero, size: meters)
        cg.saveGState()
        cg.clip(to: region)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch style {
        case .grass: paintGrass(field: field, region: region, ppm: ppm, night: false, in: cg)
        case .night: paintGrass(field: field, region: region, ppm: ppm, night: true, in: cg)
        case .classic:
            cg.setFillColor(Palette.paper.cgColor)
            cg.fill(region)
            cg.setStrokeColor(Palette.ink.withAlphaComponent(0.1).cgColor)
            cg.setLineWidth(max(0.05, 1 / ppm))
            cg.stroke(fieldRect.insetBy(dx: -apron * 0.55, dy: -apron * 0.55))
        case .chalk: paintChalkboard(region: region, ppm: ppm, in: cg)
        case .court: paintCourt(field: field, region: region, fieldRect: fieldRect, ppm: ppm, in: cg)
        }
        drawMarkings(field: field, style: style, ppm: ppm, in: cg)
        drawGoals(field: field, style: style, ppm: ppm, in: cg)
        cg.restoreGState()
    }

    // MARK: Styles

    private enum Palette {
        static let paper = UIColor(red: 0.962, green: 0.958, blue: 0.94, alpha: 1)
        static let ink = UIColor(red: 0.11, green: 0.24, blue: 0.17, alpha: 1)
        static let slate = UIColor(red: 0.15, green: 0.185, blue: 0.18, alpha: 1)
        static let navy = UIColor(red: 0.11, green: 0.18, blue: 0.31, alpha: 1)
        static let wood = UIColor(red: 0.79, green: 0.60, blue: 0.40, alpha: 1)
        static let rim = UIColor(red: 0.95, green: 0.42, blue: 0.13, alpha: 1)
    }

    private static func stripeCount(_ field: BoardFieldType) -> (count: Int, alongY: Bool) {
        switch field {
        case .footballFull: (20, false)
        case .footballHalf: (10, true)
        case .futsal: (8, false)
        case .basketball: (7, false)
        case .blank: (6, false)
        }
    }

    private static func paintGrass(field: BoardFieldType, region: CGRect, ppm: CGFloat, night: Bool, in cg: CGContext) {
        let meters = field.meters
        let light = night ? UIColor(red: 0.12, green: 0.32, blue: 0.18, alpha: 1) : UIColor(red: 0.33, green: 0.585, blue: 0.285, alpha: 1)
        let dark = night ? UIColor(red: 0.095, green: 0.275, blue: 0.155, alpha: 1) : UIColor(red: 0.27, green: 0.51, blue: 0.235, alpha: 1)
        cg.setFillColor(dark.cgColor)
        cg.fill(region)
        // Mown stripes, continued into the run-off with the same period.
        let (count, alongY) = stripeCount(field)
        let period = (alongY ? meters.height : meters.width) / CGFloat(count)
        let low = alongY ? region.minY : region.minX, high = alongY ? region.maxY : region.maxX
        var index = Int(floor(low / period))
        while CGFloat(index) * period < high {
            let start = CGFloat(index) * period
            let band = alongY ? CGRect(x: region.minX, y: start, width: region.width, height: period) : CGRect(x: start, y: region.minY, width: period, height: region.height)
            if index % 2 == 0 {
                cg.setFillColor(light.cgColor)
                cg.fill(band)
            }
            // A soft sheen across each band reads as grass laid in the mowing direction.
            cg.saveGState()
            cg.clip(to: band)
            let from = alongY ? CGPoint(x: band.midX, y: band.minY) : CGPoint(x: band.minX, y: band.midY)
            let to = alongY ? CGPoint(x: band.midX, y: band.maxY) : CGPoint(x: band.maxX, y: band.midY)
            BoardGradient.linear([UIColor.white.withAlphaComponent(night ? 0.02 : 0.045), UIColor.white.withAlphaComponent(0)], from: from, to: to, in: cg)
            cg.restoreGState()
            index += 1
        }
        // Fine grain: speckle plus a directional streak along the stripes.
        tile(BoardNoise.speckle, alpha: night ? 0.45 : 0.6, pixelsPerMeter: ppm, stretch: CGSize(width: 1, height: 1), in: cg, region: region)
        tile(BoardNoise.speckle, alpha: 0.35, pixelsPerMeter: ppm, stretch: alongY ? CGSize(width: 1, height: 4) : CGSize(width: 4, height: 1), in: cg, region: region)
        if night {
            // Floodlights: warm pools from the four corners and a faint wash in the middle.
            let reach = max(meters.width, meters.height) * 0.62
            for corner in [CGPoint(x: -region.width * 0.02, y: -region.height * 0.04), CGPoint(x: meters.width + region.width * 0.02, y: -region.height * 0.04),
                           CGPoint(x: -region.width * 0.02, y: meters.height + region.height * 0.04), CGPoint(x: meters.width + region.width * 0.02, y: meters.height + region.height * 0.04)] {
                BoardGradient.radial([UIColor(red: 1, green: 0.97, blue: 0.86, alpha: 0.2), UIColor(red: 1, green: 0.97, blue: 0.86, alpha: 0)], center: corner, radius: reach, extendsBeyondRadius: false, in: cg)
            }
            BoardGradient.radial([UIColor.white.withAlphaComponent(0.06), UIColor.white.withAlphaComponent(0)], center: CGPoint(x: meters.width / 2, y: meters.height / 2), radius: reach * 0.8, extendsBeyondRadius: false, in: cg)
            vignette(region: region, strength: 0.55, in: cg)
        } else {
            BoardGradient.linear([UIColor.white.withAlphaComponent(0.07), UIColor.black.withAlphaComponent(0.06)], from: CGPoint(x: region.midX, y: region.minY), to: CGPoint(x: region.midX, y: region.maxY), in: cg)
            vignette(region: region, strength: 0.3, in: cg)
        }
    }

    private static func paintChalkboard(region: CGRect, ppm: CGFloat, in cg: CGContext) {
        cg.setFillColor(Palette.slate.cgColor)
        cg.fill(region)
        // Wiped chalk dust: a few large, faint smudges in fixed places.
        var random = SeededRandom(seed: 11)
        for _ in 0..<7 {
            let center = CGPoint(x: region.minX + region.width * random.unit(), y: region.minY + region.height * random.unit())
            BoardGradient.radial([UIColor.white.withAlphaComponent(0.035 + 0.03 * random.unit()), UIColor.white.withAlphaComponent(0)], center: center, radius: region.width * (0.12 + 0.18 * random.unit()), extendsBeyondRadius: false, in: cg)
        }
        tile(BoardNoise.speckle, alpha: 0.7, pixelsPerMeter: ppm, stretch: CGSize(width: 1, height: 1), in: cg, region: region)
        vignette(region: region, strength: 0.35, in: cg)
    }

    private static func paintCourt(field: BoardFieldType, region: CGRect, fieldRect: CGRect, ppm: CGFloat, in cg: CGContext) {
        let meters = field.meters
        cg.setFillColor(Palette.wood.cgColor)
        cg.fill(region)
        // Planks along the length with staggered joints and slight tone changes.
        let short = min(meters.width, meters.height)
        let plank = short / 40
        var random = SeededRandom(seed: 7)
        var y = floor(region.minY / plank) * plank
        cg.setLineWidth(max(0.012, 0.7 / ppm))
        while y < region.maxY {
            let tone = random.unit()
            cg.setFillColor((tone > 0.5 ? UIColor.white : UIColor.black).withAlphaComponent(abs(tone - 0.5) * 0.12).cgColor)
            cg.fill(CGRect(x: region.minX, y: y, width: region.width, height: plank))
            cg.setStrokeColor(UIColor(red: 0.35, green: 0.22, blue: 0.1, alpha: 0.16).cgColor)
            cg.move(to: CGPoint(x: region.minX, y: y)); cg.addLine(to: CGPoint(x: region.maxX, y: y))
            var x = region.minX - short * 0.3 * random.unit()
            while x < region.maxX {
                x += short * (0.18 + 0.2 * random.unit())
                cg.move(to: CGPoint(x: x, y: y)); cg.addLine(to: CGPoint(x: x, y: y + plank))
            }
            cg.strokePath()
            y += plank
        }
        tile(BoardNoise.speckle, alpha: 0.5, pixelsPerMeter: ppm, stretch: CGSize(width: 9, height: 1), in: cg, region: region)
        // Painted out-of-bounds band and keys.
        cg.saveGState()
        cg.setFillColor(Palette.navy.cgColor)
        cg.addRect(region); cg.addRect(fieldRect)
        cg.fillPath(using: .evenOdd)
        let h = meters.height
        let painted = Palette.navy.withAlphaComponent(0.9).cgColor
        cg.setFillColor(painted)
        switch field {
        case .basketball:
            for x in [0, meters.width - 5.8] { cg.fill(CGRect(x: x, y: h / 2 - 2.45, width: 5.8, height: 4.9)) }
            cg.fillEllipse(in: CGRect(x: meters.width / 2 - 1.8, y: h / 2 - 1.8, width: 3.6, height: 3.6))
        case .futsal:
            for mirrored in [false, true] {
                let area = CGMutablePath()
                area.move(to: CGPoint(x: 0, y: h / 2 - 7.5))
                area.addArc(center: CGPoint(x: 0, y: h / 2 - 1.5), radius: 6, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
                area.addLine(to: CGPoint(x: 6, y: h / 2 + 1.5))
                area.addArc(center: CGPoint(x: 0, y: h / 2 + 1.5), radius: 6, startAngle: 0, endAngle: .pi / 2, clockwise: false)
                area.closeSubpath()
                var flip = CGAffineTransform(translationX: meters.width, y: 0).scaledBy(x: -1, y: 1)
                cg.addPath(mirrored ? (area.copy(using: &flip) ?? area) : area)
                cg.fillPath()
            }
            cg.fillEllipse(in: CGRect(x: meters.width / 2 - 3, y: h / 2 - 3, width: 6, height: 6))
        default:
            break
        }
        cg.restoreGState()
        // Varnish: a soft reflection and gentle falloff.
        BoardGradient.radial([UIColor.white.withAlphaComponent(0.16), UIColor.white.withAlphaComponent(0)], center: CGPoint(x: meters.width * 0.38, y: meters.height * 0.3), radius: max(meters.width, meters.height) * 0.55, extendsBeyondRadius: false, in: cg)
        vignette(region: region, strength: 0.28, in: cg)
    }

    // MARK: Markings

    private static func lineWidth(_ field: BoardFieldType, style: BoardFieldStyle) -> CGFloat {
        let actual: CGFloat = switch field {
        case .footballFull, .footballHalf: 0.12
        case .futsal: 0.08
        case .basketball: 0.05
        case .blank: 0.05
        }
        let short = min(field.meters.width, field.meters.height)
        return max(actual, short * (style == .classic ? 0.0036 : 0.003))
    }

    private static func lineColor(_ style: BoardFieldStyle) -> UIColor {
        switch style {
        case .classic: Palette.ink
        case .chalk: UIColor(white: 0.96, alpha: 0.86)
        case .night: UIColor(red: 0.97, green: 0.98, blue: 1, alpha: 0.95)
        case .grass, .court: UIColor(white: 1, alpha: 0.93)
        }
    }

    private static func markingsPath(_ field: BoardFieldType) -> (lines: CGPath, faint: CGPath, spots: [CGPoint]) {
        let lines = CGMutablePath(), faint = CGMutablePath()
        var spots: [CGPoint] = []
        for marking in field.markings {
            switch marking {
            case .segment(let a, let b, let isFaint):
                let path = isFaint ? faint : lines
                path.move(to: a); path.addLine(to: b)
            case .arc(let center, let radius, let from, let to):
                let start = CGPoint(x: center.x + radius * cos(from * .pi / 180), y: center.y + radius * sin(from * .pi / 180))
                lines.move(to: start)
                lines.addArc(center: center, radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: false)
            case .spot(let p):
                spots.append(p)
            }
        }
        return (lines, faint, spots)
    }

    private static func drawMarkings(field: BoardFieldType, style: BoardFieldStyle, ppm: CGFloat, in cg: CGContext) {
        let width = lineWidth(field, style: style)
        let color = lineColor(style)
        let (lines, faint, spots) = markingsPath(field)
        let spotRadius = max(field == .basketball ? 0.08 : 0.11, width * 1.25)
        let paint = {
            cg.addPath(faint)
            cg.setStrokeColor(color.withAlphaComponent(style == .classic ? 0.14 : 0.13).cgColor)
            cg.setLineWidth(width * 0.8)
            cg.strokePath()
            if style != .classic {
                // A wide faint pass under the core line softens its edge (a glow under floodlights).
                cg.addPath(lines)
                cg.setStrokeColor(color.withAlphaComponent(style == .night ? 0.22 : 0.12).cgColor)
                cg.setLineWidth(width * (style == .night ? 3.2 : 2))
                cg.strokePath()
            }
            cg.addPath(lines)
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(width)
            cg.strokePath()
            cg.setFillColor(color.cgColor)
            for spot in spots { cg.fillEllipse(in: CGRect(x: spot.x - spotRadius, y: spot.y - spotRadius, width: spotRadius * 2, height: spotRadius * 2)) }
        }
        if style == .chalk {
            // Chalk: paint the lines, then rub dust out of them.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            paint()
            cg.setBlendMode(.destinationOut)
            tile(BoardNoise.chalk, alpha: 0.75, pixelsPerMeter: ppm, stretch: CGSize(width: 1.5, height: 1.5), in: cg, region: cg.boundingBoxOfClipPath)
            cg.endTransparencyLayer()
        } else {
            paint()
        }
    }

    // MARK: Goals

    private static func drawGoals(field: BoardFieldType, style: BoardFieldStyle, ppm: CGFloat, in cg: CGContext) {
        let meters = field.meters
        let frame = style == .classic ? Palette.ink : UIColor.white
        let hair = max(0.02, 0.9 / ppm)
        switch field {
        case .footballFull, .futsal:
            let (mouth, depth, post): (CGFloat, CGFloat, CGFloat) = field == .futsal ? (3, 1, 0.08) : (7.32, 2, 0.12)
            for right in [false, true] {
                let lineX: CGFloat = right ? meters.width : 0, back = right ? meters.width + depth : -depth
                goal(from: CGPoint(x: lineX, y: meters.height / 2 - mouth / 2), to: CGPoint(x: lineX, y: meters.height / 2 + mouth / 2),
                     back: CGVector(dx: back - lineX, dy: 0), post: max(post, lineWidth(field, style: style)), hair: hair, color: frame, in: cg)
            }
        case .footballHalf:
            goal(from: CGPoint(x: meters.width / 2 - 3.66, y: 0), to: CGPoint(x: meters.width / 2 + 3.66, y: 0), back: CGVector(dx: 0, dy: -2),
                 post: max(0.12, lineWidth(field, style: style)), hair: hair, color: frame, in: cg)
        case .basketball:
            for right in [false, true] {
                let board = right ? meters.width - 1.2 : 1.2, rim = right ? meters.width - 1.575 : 1.575
                let h = meters.height
                cg.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
                cg.fill(CGRect(x: board - 0.05 + 0.08, y: h / 2 - 0.9 + 0.1, width: 0.1, height: 1.8))
                cg.setFillColor(frame.withAlphaComponent(0.95).cgColor)
                cg.fill(CGRect(x: board - 0.05, y: h / 2 - 0.9, width: 0.1, height: 1.8))
                cg.setStrokeColor(frame.withAlphaComponent(0.55).cgColor)
                cg.setLineWidth(0.05)
                cg.move(to: CGPoint(x: board, y: h / 2)); cg.addLine(to: CGPoint(x: rim + (right ? 0.225 : -0.225), y: h / 2)); cg.strokePath()
                let ring = CGRect(x: rim - 0.225, y: h / 2 - 0.225, width: 0.45, height: 0.45)
                cg.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
                cg.fillEllipse(in: ring)
                cg.setStrokeColor(Palette.rim.cgColor)
                cg.setLineWidth(0.05)
                cg.strokeEllipse(in: ring)
            }
        case .blank:
            break
        }
    }

    /// Top view of a goal: posts on the goal line and a net box behind it.
    private static func goal(from a: CGPoint, to b: CGPoint, back: CGVector, post: CGFloat, hair: CGFloat, color: UIColor, in cg: CGContext) {
        let box = [a, b, CGPoint(x: b.x + back.dx, y: b.y + back.dy), CGPoint(x: a.x + back.dx, y: a.y + back.dy)]
        let outline = CGMutablePath()
        outline.addLines(between: box)
        outline.closeSubpath()
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0.12, height: 0.18), blur: 0.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        cg.addPath(outline)
        cg.setFillColor(color.withAlphaComponent(0.1).cgColor)
        cg.fillPath()
        cg.restoreGState()
        // Net mesh.
        cg.saveGState()
        cg.addPath(outline); cg.clip()
        // Metres here, so the floor is a net-sized 0.22 m rather than the renderer's screen points.
        BoardNet.mesh(in: outline.boundingBox, minimum: 0.22, color: color.withAlphaComponent(0.32), lineWidth: hair, in: cg)
        cg.restoreGState()
        // Frame: net edges, crossbar on the line and round posts.
        cg.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(max(hair, post * 0.45))
        cg.addLines(between: [a, box[3], box[2], b])
        cg.strokePath()
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(post)
        cg.move(to: a); cg.addLine(to: b); cg.strokePath()
        cg.setFillColor(color.cgColor)
        for p in [a, b] { cg.fillEllipse(in: CGRect(x: p.x - post, y: p.y - post, width: post * 2, height: post * 2)) }
    }

    // MARK: Helpers

    private static func tile(_ image: CGImage?, alpha: CGFloat, pixelsPerMeter ppm: CGFloat, stretch: CGSize, in cg: CGContext, region: CGRect) {
        guard let image, ppm > 0 else { return }
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.clip(to: region)
        let tile = CGRect(x: 0, y: 0, width: CGFloat(image.width) / ppm * stretch.width, height: CGFloat(image.height) / ppm * stretch.height)
        cg.draw(image, in: tile, byTiling: true)
        cg.restoreGState()
    }

    /// Darkens towards the corners of `region`.
    private static func vignette(region: CGRect, strength: CGFloat, in cg: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(strength * 0.35).cgColor, UIColor.black.withAlphaComponent(strength).cgColor] as CFArray, locations: [0.45, 0.8, 1]) else { return }
        cg.saveGState()
        let center = CGPoint(x: region.midX, y: region.midY)
        // Draw a circular gradient stretched to the region's aspect ratio.
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: region.width / max(region.width, region.height), y: region.height / max(region.width, region.height))
        let radius = max(region.width, region.height) * 0.72
        cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
        cg.restoreGState()
    }
}

// MARK: - Noise

/// Small deterministic noise tiles so textures are identical on every render.
enum BoardNoise {
    /// Light and dark speckles with low alpha (turf grain, wood grain, slate).
    nonisolated(unsafe) static let speckle: CGImage? = make(size: 192, seed: 3) { random in
        let value = random.unit()
        let bright = random.unit() > 0.5
        let alpha = pow(value, 2.2) * 0.2
        return bright ? (1, alpha) : (0, alpha * 1.3)
    }

    /// Clumpy alpha mask used to rub chalk out of lines.
    nonisolated(unsafe) static let chalk: CGImage? = make(size: 128, seed: 5) { random in
        let value = random.unit()
        return (0, value > 0.72 ? 0.9 : value * 0.28)
    }

    private static func make(size: Int, seed: UInt64, pixel: (inout SeededRandom) -> (white: Double, alpha: Double)) -> CGImage? {
        var random = SeededRandom(seed: seed)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<(size * size) {
            let (white, alpha) = pixel(&random)
            let a = UInt8(max(0, min(255, alpha * 255)))
            let premultiplied = UInt8(Double(a) * white)
            bytes[index * 4] = premultiplied; bytes[index * 4 + 1] = premultiplied; bytes[index * 4 + 2] = premultiplied; bytes[index * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// SplitMix64: tiny, fast and reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

// MARK: - Cache

/// Rendered surfaces keyed by field, style and pixel density. Dragging elements redraws only
/// elements; the textured field is one image draw. Thread-safe for off-main exports.
final class BoardSurfaceCache: @unchecked Sendable {
    static let shared = BoardSurfaceCache()
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private let limit = 8
    /// Laid-out canvases are screen sized, so only a few are kept (editor, thumbnails, export).
    private var canvases: [String: CGImage] = [:]
    private var canvasOrder: [String] = []
    private let canvasLimit = 3

    /// The whole 2D surface ready to blit: rounded slab, its drop shadow and the painted field, in one image.
    /// Drawing this is a single image blit per frame instead of a shadowed fill, a clip and a texture draw.
    /// Returns the image and the metres of padding it carries around the field's apron (for the shadow).
    func slab(field: BoardFieldType, style: BoardFieldStyle, pixelsPerMeter requested: CGFloat) -> (image: CGImage, apron: CGFloat, padding: CGFloat)? {
        let apron = BoardSurfacePainter.apronMeters(field)
        let unit = CGFloat(field.elementUnitMeters)
        let padding = unit * 10
        let meters = field.meters
        let extent = CGSize(width: meters.width + 2 * apron + 2 * padding, height: meters.height + 2 * apron + 2 * padding)
        let bucket = pow(2, ceil(log2(max(1, requested)) * 2) / 2)
        let ppm = min(bucket, 4096 / max(extent.width, extent.height))
        let key = "slab-\(field.rawValue)-\(style.rawValue)-\(Int((ppm * 100).rounded()))"
        if let cached = lock.withLock({ images[key] }) { return (cached, apron, padding) }
        guard let painted = BoardSurfacePainter.image(field: field, style: style, pixelsPerMeter: ppm, apron: apron) else { return nil }
        let width = Int((extent.width * ppm).rounded()), height = Int((extent.height * ppm).rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        cg.scaleBy(x: ppm, y: ppm)
        cg.translateBy(x: padding, y: padding)
        let region = CGRect(x: -apron, y: -apron, width: meters.width + 2 * apron, height: meters.height + 2 * apron)
        let corner = min(region.width, region.height) * 0.018
        let slabPath = CGPath(roundedRect: region, cornerWidth: corner, cornerHeight: corner, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: unit * 1.2), blur: unit * 7, color: UIColor.black.withAlphaComponent(0.55).cgColor)
        cg.addPath(slabPath)
        cg.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(slabPath)
        cg.clip()
        cg.translateBy(x: 0, y: region.minY + region.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(painted, in: region)
        cg.restoreGState()
        cg.addPath(slabPath)
        cg.setStrokeColor((style == .classic ? UIColor.black.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.09)).cgColor)
        cg.setLineWidth(max(0.02, unit * 0.12))
        cg.strokePath()
        guard let composed = cg.makeImage() else { return nil }
        lock.withLock {
            images[key] = composed
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit { images[order.removeFirst()] = nil }
        }
        return (composed, apron, padding)
    }

    /// The slab already laid out for one canvas, ready to blit 1:1 over `CGRect(origin: .zero, size: size)`.
    /// The slab blit itself resamples a few megapixels through a rotated transform every frame (~12 ms on a
    /// heavy board); doing it once per canvas geometry turns playback frames into a straight copy.
    /// Returns nil when the canvas is zoomed far enough in that a screen-sized bitmap would be either
    /// soft or huge; the caller then falls back to drawing the slab directly.
    func canvas(field: BoardFieldType, style: BoardFieldStyle, size: CGSize, inset: CGFloat, reserved: CGSize, scale requested: CGFloat) -> CGImage? {
        // Half-point steps: an unzoomed canvas lands exactly on the screen scale, so the blit is 1:1
        // with no resampling at all, and pinch zoom rebuilds only every ~17%.
        let scale = max(1, floor(requested * 2) / 2)
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixels.width >= 1, pixels.height >= 1, pixels.width * pixels.height <= 6_000_000 else { return nil }
        // Geometry is keyed in eighths of a point, not whole points: a 392.66 pt canvas must not be served
        // the bitmap baked for 392 pt, which would shift the markings against the elements drawn over them.
        let eighths: (CGFloat) -> Int = { Int(($0 * 8).rounded()) }
        let key = "canvas-\(field.rawValue)-\(style.rawValue)-\(eighths(size.width))x\(eighths(size.height))-\(eighths(inset))-\(eighths(reserved.width))x\(eighths(reserved.height))-\(eighths(scale))"
        if let cached = lock.withLock({ canvases[key] }) { return cached }
        let projection = BoardProjection(field: field, size: size, inset: inset, reserved: reserved)
        guard let slab = slab(field: field, style: style, pixelsPerMeter: projection.pixelsPerMeter * scale),
              let cg = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip into UIKit orientation, then lay the slab out exactly as `BoardRenderer.drawSurface` would.
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: scale, y: -scale)
        cg.concatenate(projection.metersTransform)
        let meters = field.meters
        let rect = CGRect(x: -slab.apron - slab.padding, y: -slab.apron - slab.padding,
                          width: meters.width + 2 * (slab.apron + slab.padding), height: meters.height + 2 * (slab.apron + slab.padding))
        cg.translateBy(x: 0, y: rect.minY + rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(slab.image, in: rect)
        guard let composed = cg.makeImage() else { return nil }
        lock.withLock {
            canvases[key] = composed
            canvasOrder.removeAll { $0 == key }
            canvasOrder.append(key)
            while canvasOrder.count > canvasLimit { canvases[canvasOrder.removeFirst()] = nil }
        }
        return composed
    }

    /// Surface image in field orientation covering the field plus the 2D apron.
    func image(field: BoardFieldType, style: BoardFieldStyle, pixelsPerMeter requested: CGFloat) -> (image: CGImage, apron: CGFloat)? {
        let apron = BoardSurfacePainter.apronMeters(field)
        let longest = max(field.meters.width, field.meters.height) + 2 * apron
        // Half-octave buckets so pinch zoom re-renders only occasionally; cap the bitmap size.
        let bucket = pow(2, ceil(log2(max(1, requested)) * 2) / 2)
        let ppm = min(bucket, 4096 / longest)
        let key = "\(field.rawValue)-\(style.rawValue)-\(Int((ppm * 100).rounded()))"
        if let cached = lock.withLock({ images[key] }) { return (cached, apron) }
        guard let image = BoardSurfacePainter.image(field: field, style: style, pixelsPerMeter: ppm, apron: apron) else { return nil }
        lock.withLock {
            images[key] = image
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit { images[order.removeFirst()] = nil }
        }
        return (image, apron)
    }
}
