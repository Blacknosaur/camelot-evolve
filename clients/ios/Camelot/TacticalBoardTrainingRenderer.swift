import CoreGraphics
import UIKit

/// Drawing of the training library (cones, poles, hurdles, ladders, goals, staff…) in the same
/// top-down style as players: light from the top left, soft shadows falling down-right, and every
/// shape drawn in local coordinates so rotation and size apply uniformly.
extension BoardRenderer {
    /// Elements whose footprint is a rotated rectangle rather than a circle (hit testing, selection).
    func isOblong(_ kind: BoardElementKind) -> Bool {
        [.text, .miniGoal, .hurdle, .ladder, .wall, .goal, .rebounder].contains(kind)
    }

    /// Half the footprint depth (local y) of an oblong element, in points.
    func oblongHalfDepth(_ element: BoardElement, projection: BoardProjection) -> CGFloat {
        let half = pointRadius(element, projection: projection)
        switch element.kind {
        case .miniGoal: return half * 0.4
        case .hurdle: return half * 0.28
        case .ladder: return projection.unit * 1.7 * CGFloat(element.size)
        case .wall: return projection.unit * 1.9 * CGFloat(element.size)
        case .goal: return half * 0.34
        case .rebounder: return half * 0.4
        default: return half
        }
    }

    /// Default colour when an element of this kind is placed.
    static func defaultColor(for kind: BoardElementKind, document: BoardDocument) -> String {
        switch kind {
        case .player: document.homeColorHex
        case .opponent: document.awayColorHex
        case .goalkeeper, .marker, .domeCone, .ladder, .pole: BoardPalette.keeper
        case .cone, .tallCone, .hurdle, .popUpGoal: BoardPalette.orange
        case .ring: BoardPalette.home
        case .wall: "3A3F4B"
        case .mannequin: "9A9AA0"
        case .rebounder: "2B2E36"
        case .flag: BoardPalette.away
        case .ballCart: "1E2A3A"
        case .coach: "2D3142"
        case .referee: BoardPalette.lime
        case .stepMarker: BoardPalette.purple
        default: BoardPalette.white
        }
    }

    func drawTraining(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let base = color(element.colorHex)
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: projection.screenAngle(element.rotation))
        // Light and shadow are fixed on screen, so shadows use offsets rotated back into local space.
        let lightAngle = -projection.screenAngle(element.rotation)
        func shadowOffset(_ distance: CGFloat) -> CGSize {
            let dx = distance * 0.45, dy = distance
            return CGSize(width: dx * cos(lightAngle) - dy * sin(lightAngle), height: dx * sin(lightAngle) + dy * cos(lightAngle))
        }
        func softShadow(_ lift: CGFloat) {
            // CoreGraphics shadow offsets ignore the CTM, so these stay screen-aligned.
            dropShadow(unit, lift: lift, in: cg)
        }
        switch element.kind {
        case .tallCone: tallCone(r: r, base: base, unit: unit, offset: shadowOffset(r * 1.3), in: cg)
        case .domeCone: domeCone(r: r, base: base, unit: unit, in: cg)
        case .pole: pole(r: r, base: base, unit: unit, offset: shadowOffset(r * 3.2), in: cg)
        case .hurdle: hurdle(half: r, depth: oblongHalfDepth(element, projection: projection), base: base, unit: unit, in: cg)
        case .ladder: ladder(half: r, depth: oblongHalfDepth(element, projection: projection), base: base, unit: unit, in: cg)
        case .ring: ring(r: r, base: base, unit: unit, in: cg)
        case .wall: wall(element, half: r, depth: oblongHalfDepth(element, projection: projection), base: base, unit: unit, in: cg)
        case .goal: goal(half: r, depth: oblongHalfDepth(element, projection: projection), frame: base, unit: unit, in: cg)
        case .popUpGoal: popUpGoal(r: r, base: base, unit: unit, in: cg)
        case .rebounder: rebounder(half: r, depth: oblongHalfDepth(element, projection: projection), base: base, unit: unit, in: cg)
        case .flag: flag(r: r, base: base, unit: unit, offset: shadowOffset(r * 1.2), in: cg)
        case .ballCart: ballCart(r: r, base: base, unit: unit, in: cg)
        case .coach, .referee: staff(element, r: r, base: base, unit: unit, angle: projection.screenAngle(element.rotation), in: cg)
        case .stepMarker: stepMarker(element, r: r, base: base, unit: unit, angle: projection.screenAngle(element.rotation), in: cg)
        default: softShadow(1)
        }
        cg.restoreGState()
    }

    // MARK: Equipment

    private func tallCone(r: CGFloat, base: UIColor, unit: CGFloat, offset: CGSize, in cg: CGContext) {
        // A long cast shadow sells the height.
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: unit * 1.2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.3).cgColor)
        let tip = CGPoint(x: offset.width * 1.05, y: offset.height * 1.05)
        cg.move(to: CGPoint(x: -r * 0.8, y: 0)); cg.addLine(to: tip); cg.addLine(to: CGPoint(x: r * 0.8, y: 0))
        cg.addArc(center: .zero, radius: r * 0.8, startAngle: 0, endAngle: .pi, clockwise: false)
        cg.fillPath()
        cg.restoreGState()
        cg.setFillColor(shaded(base, by: -0.3).cgColor)
        cg.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        let body = CGRect(x: -r * 0.7, y: -r * 0.7, width: r * 1.4, height: r * 1.4)
        cg.saveGState()
        cg.addEllipse(in: body)
        cg.clip()
        let apex = CGPoint(x: -r * 0.1, y: -r * 0.14)
        gradientFill(radial: [shaded(base, by: 0.5), base, shaded(base, by: -0.22)], center: apex, radius: r * 0.8, in: cg)
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        cg.setLineWidth(r * 0.09)
        for band in [0.28, 0.5] as [CGFloat] {
            cg.strokeEllipse(in: CGRect(x: apex.x - r * band, y: apex.y - r * band, width: r * band * 2, height: r * band * 2))
        }
        cg.restoreGState()
        cg.setFillColor(shaded(base, by: -0.4).cgColor)
        cg.fillEllipse(in: CGRect(x: apex.x - r * 0.08, y: apex.y - r * 0.08, width: r * 0.16, height: r * 0.16))
    }

    private func domeCone(r: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let disc = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        cg.saveGState()
        dropShadow(unit, lift: 0.45, in: cg)
        cg.setFillColor(base.cgColor)
        cg.fillEllipse(in: disc)
        cg.restoreGState()
        cg.saveGState()
        cg.addEllipse(in: disc)
        cg.clip()
        gradientFill(radial: [shaded(base, by: 0.55), base, shaded(base, by: -0.25)], center: CGPoint(x: -r * 0.25, y: -r * 0.3), radius: r * 1.15, in: cg)
        cg.restoreGState()
        // Flat rim and the small hole on top.
        cg.setStrokeColor(shaded(base, by: -0.25).withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(max(0.6, r * 0.08))
        cg.strokeEllipse(in: disc.insetBy(dx: r * 0.12, dy: r * 0.12))
        cg.setFillColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        cg.fillEllipse(in: CGRect(x: -r * 0.2, y: -r * 0.2, width: r * 0.4, height: r * 0.4))
    }

    private func pole(r: CGFloat, base: UIColor, unit: CGFloat, offset: CGSize, in cg: CGContext) {
        // Rubber base, a long pole shadow, then the pole top with a stripe.
        cg.saveGState()
        dropShadow(unit, lift: 0.4, in: cg)
        cg.setFillColor(UIColor(white: 0.14, alpha: 1).cgColor)
        cg.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        cg.restoreGState()
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
        cg.setLineWidth(max(0.5, r * 0.08))
        cg.strokeEllipse(in: CGRect(x: -r * 0.8, y: -r * 0.8, width: r * 1.6, height: r * 1.6))
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: unit * 0.8, color: UIColor.black.withAlphaComponent(0.4).cgColor)
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.32).cgColor)
        cg.setLineCap(.round)
        cg.setLineWidth(r * 0.5)
        cg.move(to: .zero); cg.addLine(to: CGPoint(x: offset.width, y: offset.height))
        cg.strokePath()
        cg.restoreGState()
        let top = CGRect(x: -r * 0.42, y: -r * 0.42, width: r * 0.84, height: r * 0.84)
        cg.saveGState()
        cg.addEllipse(in: top)
        cg.clip()
        gradientFill(radial: [shaded(base, by: 0.5), base, shaded(base, by: -0.3)], center: CGPoint(x: -r * 0.15, y: -r * 0.18), radius: r * 0.55, in: cg)
        cg.restoreGState()
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        cg.setLineWidth(max(0.5, r * 0.07))
        cg.strokeEllipse(in: top.insetBy(dx: r * 0.12, dy: r * 0.12))
    }

    private func hurdle(half: CGFloat, depth: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let bar = max(1.4, unit * 0.75)
        // Feet at both ends.
        cg.setStrokeColor(shaded(base, by: -0.35).cgColor)
        cg.setLineCap(.round)
        cg.setLineWidth(bar * 0.9)
        for x in [-half + bar / 2, half - bar / 2] {
            cg.move(to: CGPoint(x: x, y: -depth)); cg.addLine(to: CGPoint(x: x, y: depth))
        }
        cg.strokePath()
        // Raised crossbar: offset shadow and a glossy tube.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: unit * 0.9, height: unit * 1.9), blur: unit * 1.2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.setStrokeColor(base.cgColor)
        cg.setLineWidth(bar)
        cg.move(to: CGPoint(x: -half + bar / 2, y: 0)); cg.addLine(to: CGPoint(x: half - bar / 2, y: 0))
        cg.strokePath()
        cg.restoreGState()
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
        cg.setLineWidth(bar * 0.3)
        cg.move(to: CGPoint(x: -half + bar, y: -bar * 0.2)); cg.addLine(to: CGPoint(x: half - bar, y: -bar * 0.2))
        cg.strokePath()
    }

    private func ladder(half: CGFloat, depth: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let rail = max(1, unit * 0.34)
        cg.saveGState()
        dropShadow(unit, lift: 0.3, in: cg)
        // One shadow for the whole ladder, but bounded to it: an unbounded layer allocates and
        // composites a buffer the size of the whole canvas.
        cg.beginTransparencyLayer(in: CGRect(x: -half, y: -depth, width: half * 2, height: depth * 2).insetBy(dx: -unit * 4, dy: -unit * 4), auxiliaryInfo: nil)
        cg.setStrokeColor(UIColor(white: 0.08, alpha: 0.9).cgColor)
        cg.setLineWidth(rail * 0.8)
        for y in [-depth, depth] {
            cg.move(to: CGPoint(x: -half, y: y)); cg.addLine(to: CGPoint(x: half, y: y))
        }
        cg.strokePath()
        let rungs = 8
        cg.setStrokeColor(base.cgColor)
        cg.setLineCap(.round)
        cg.setLineWidth(rail * 1.5)
        for index in 0...rungs {
            let x = -half + CGFloat(index) * half * 2 / CGFloat(rungs)
            cg.move(to: CGPoint(x: x, y: -depth)); cg.addLine(to: CGPoint(x: x, y: depth))
        }
        cg.strokePath()
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    private func ring(r: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let width = r * 0.2
        let rect = CGRect(x: -r + width / 2, y: -r + width / 2, width: r * 2 - width, height: r * 2 - width)
        cg.saveGState()
        dropShadow(unit, lift: 0.35, in: cg)
        cg.setStrokeColor(base.cgColor)
        cg.setLineWidth(width)
        cg.strokeEllipse(in: rect)
        cg.restoreGState()
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.4).cgColor)
        cg.setLineWidth(width * 0.28)
        cg.addArc(center: .zero, radius: r - width * 0.62, startAngle: .pi * 1.05, endAngle: .pi * 1.65, clockwise: false)
        cg.strokePath()
    }

    private func wall(_ element: BoardElement, half: CGFloat, depth: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let count = element.wallCount
        let slot = (half * 2 - unit * 0.8 * CGFloat(element.size)) / CGFloat(count)
        // Linking base rail.
        cg.saveGState()
        dropShadow(unit, lift: 0.4, in: cg)
        cg.setFillColor(UIColor(white: 0.12, alpha: 0.9).cgColor)
        cg.addPath(CGPath(roundedRect: CGRect(x: -half, y: depth * 0.45, width: half * 2, height: depth * 0.4), cornerWidth: depth * 0.2, cornerHeight: depth * 0.2, transform: nil))
        cg.fillPath()
        cg.restoreGState()
        for index in 0..<count {
            let x = -half + unit * 0.4 * CGFloat(element.size) + slot * (CGFloat(index) + 0.5)
            let body = CGRect(x: x - slot * 0.4, y: -depth * 0.55, width: slot * 0.8, height: depth * 0.9)
            let path = CGPath(roundedRect: body, cornerWidth: slot * 0.3, cornerHeight: depth * 0.4, transform: nil)
            cg.saveGState()
            dropShadow(unit, lift: 0.8, in: cg)
            cg.addPath(path)
            cg.setFillColor(base.cgColor)
            cg.fillPath()
            cg.restoreGState()
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            gradientFill(linear: [shaded(base, by: 0.35), shaded(base, by: -0.2)], from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY), in: cg)
            cg.restoreGState()
            let head = slot * 0.34
            cg.setFillColor(shaded(base, by: 0.25).cgColor)
            cg.fillEllipse(in: CGRect(x: x - head / 2, y: -depth * 0.1 - head / 2, width: head, height: head))
            cg.setStrokeColor(shaded(base, by: -0.35).cgColor)
            cg.setLineWidth(max(0.5, unit * 0.12))
            cg.strokeEllipse(in: CGRect(x: x - head / 2, y: -depth * 0.1 - head / 2, width: head, height: head))
        }
    }

    /// Full-size goal: mouth along local x on the -y side, net box behind.
    private func goal(half: CGFloat, depth: CGFloat, frame: UIColor, unit: CGFloat, in cg: CGContext) {
        let box = CGRect(x: -half, y: -depth, width: half * 2, height: depth * 2)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: unit * 0.8, height: unit * 1.6), blur: unit * 2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
        cg.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
        cg.fill(box)
        cg.restoreGState()
        cg.saveGState()
        cg.clip(to: box)
        BoardNet.mesh(in: box, minimum: 2.2, color: UIColor.white.withAlphaComponent(0.42), lineWidth: max(0.4, unit * 0.1), in: cg)
        cg.restoreGState()
        cg.setStrokeColor(frame.withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(max(0.8, unit * 0.35))
        cg.addLines(between: [CGPoint(x: -half, y: box.minY), CGPoint(x: -half, y: box.maxY), CGPoint(x: half, y: box.maxY), CGPoint(x: half, y: box.minY)])
        cg.strokePath()
        cg.saveGState()
        dropShadow(unit, lift: 0.8, in: cg)
        cg.setStrokeColor(frame.cgColor)
        cg.setLineCap(.round)
        cg.setLineWidth(max(1.6, unit * 0.9))
        cg.move(to: CGPoint(x: -half, y: box.minY)); cg.addLine(to: CGPoint(x: half, y: box.minY))
        cg.strokePath()
        cg.restoreGState()
        cg.setFillColor(frame.cgColor)
        for px in [-half, half] { cg.fillEllipse(in: CGRect(x: px - unit * 0.75, y: box.minY - unit * 0.75, width: unit * 1.5, height: unit * 1.5)) }
    }

    /// Pop-up goal: a sprung arch seen from above with its net filling the dome.
    private func popUpGoal(r: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let dome = CGMutablePath()
        dome.move(to: CGPoint(x: -r, y: -r * 0.35))
        dome.addCurve(to: CGPoint(x: r, y: -r * 0.35), control1: CGPoint(x: -r, y: r * 1.05), control2: CGPoint(x: r, y: r * 1.05))
        dome.closeSubpath()
        cg.saveGState()
        dropShadow(unit, lift: 0.9, in: cg)
        cg.addPath(dome)
        cg.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(dome)
        cg.clip()
        BoardNet.mesh(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), minimum: 2,
                      color: UIColor.white.withAlphaComponent(0.4), lineWidth: max(0.4, unit * 0.1), in: cg)
        cg.restoreGState()
        cg.addPath(dome)
        cg.setStrokeColor(base.cgColor)
        cg.setLineWidth(max(1.2, unit * 0.6))
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.setStrokeColor(UIColor(white: 0.1, alpha: 0.85).cgColor)
        cg.setLineWidth(max(1, unit * 0.45))
        cg.move(to: CGPoint(x: -r, y: -r * 0.35)); cg.addLine(to: CGPoint(x: r, y: -r * 0.35))
        cg.strokePath()
    }

    private func rebounder(half: CGFloat, depth: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let face = CGRect(x: -half, y: -depth, width: half * 2, height: depth * 0.9)
        // Support legs behind the angled frame.
        cg.setStrokeColor(UIColor(white: 0.15, alpha: 0.9).cgColor)
        cg.setLineWidth(max(1, unit * 0.4))
        cg.setLineCap(.round)
        for x in [-half * 0.8, half * 0.8] {
            cg.move(to: CGPoint(x: x, y: face.midY)); cg.addLine(to: CGPoint(x: x, y: depth))
        }
        cg.strokePath()
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: unit * 0.9, height: unit * 1.8), blur: unit * 1.6, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        cg.fill(face)
        cg.restoreGState()
        cg.saveGState()
        cg.clip(to: face)
        BoardNet.mesh(in: face, minimum: 1.8, color: UIColor.white.withAlphaComponent(0.55), lineWidth: max(0.4, unit * 0.1), in: cg)
        cg.restoreGState()
        cg.setStrokeColor(base.cgColor)
        cg.setLineWidth(max(1.2, unit * 0.6))
        cg.stroke(face)
    }

    private func flag(r: CGFloat, base: UIColor, unit: CGFloat, offset: CGSize, in cg: CGContext) {
        // Pole shadow, pennant, then the pole top.
        cg.saveGState()
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.3).cgColor)
        cg.setLineWidth(max(1, unit * 0.35))
        cg.setLineCap(.round)
        cg.setShadow(offset: .zero, blur: unit * 0.6, color: UIColor.black.withAlphaComponent(0.4).cgColor)
        cg.move(to: .zero); cg.addLine(to: CGPoint(x: offset.width * 1.8, y: offset.height * 1.8))
        cg.strokePath()
        cg.restoreGState()
        let pennant = CGMutablePath()
        pennant.move(to: CGPoint(x: 0, y: -r * 0.35))
        pennant.addCurve(to: CGPoint(x: r * 1.9, y: -r * 0.05), control1: CGPoint(x: r * 0.7, y: -r * 0.55), control2: CGPoint(x: r * 1.3, y: -r * 0.05))
        pennant.addCurve(to: CGPoint(x: 0, y: r * 0.45), control1: CGPoint(x: r * 1.2, y: r * 0.1), control2: CGPoint(x: r * 0.6, y: r * 0.55))
        pennant.closeSubpath()
        cg.saveGState()
        dropShadow(unit, lift: 0.7, in: cg)
        cg.addPath(pennant)
        cg.setFillColor(base.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(pennant)
        cg.clip()
        gradientFill(linear: [shaded(base, by: 0.3), shaded(base, by: -0.15), shaded(base, by: 0.2)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: r * 1.9, y: 0), in: cg)
        cg.restoreGState()
        cg.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
        cg.fillEllipse(in: CGRect(x: -r * 0.28, y: -r * 0.28, width: r * 0.56, height: r * 0.56))
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        cg.setLineWidth(max(0.5, r * 0.08))
        cg.strokeEllipse(in: CGRect(x: -r * 0.28, y: -r * 0.28, width: r * 0.56, height: r * 0.56))
    }

    private func ballCart(r: CGFloat, base: UIColor, unit: CGFloat, in cg: CGContext) {
        let bag = CGRect(x: -r, y: -r * 0.85, width: r * 2, height: r * 1.7)
        let bagPath = CGPath(roundedRect: bag, cornerWidth: r * 0.45, cornerHeight: r * 0.45, transform: nil)
        cg.saveGState()
        dropShadow(unit, lift: 0.8, in: cg)
        cg.addPath(bagPath)
        cg.setFillColor(base.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(bagPath)
        cg.clip()
        let ball = r * 0.42
        for (bx, by) in [(-0.48, -0.36), (0.18, -0.4), (-0.1, 0.3), (0.55, 0.28)] as [(CGFloat, CGFloat)] {
            let c = CGPoint(x: bx * r, y: by * r)
            let rect = CGRect(x: c.x - ball, y: c.y - ball, width: ball * 2, height: ball * 2)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: ball * 0.2), blur: ball * 0.4, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            cg.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            cg.fillEllipse(in: rect)
            cg.restoreGState()
            cg.setFillColor(UIColor(white: 0.15, alpha: 0.85).cgColor)
            cg.addPath(regularPolygon(center: c, radius: ball * 0.34, sides: 5, rotation: -.pi / 2))
            cg.fillPath()
        }
        cg.restoreGState()
        cg.addPath(bagPath)
        cg.setStrokeColor(shaded(base, by: 0.3).cgColor)
        cg.setLineWidth(max(1, unit * 0.4))
        cg.strokePath()
    }

    // MARK: People and markers

    /// Coach and referee: a disc like a player with a symbol instead of a number. Local drawing is unrotated
    /// so the letter stays upright; `angle` places the facing notch.
    private func staff(_ element: BoardElement, r: CGFloat, base: UIColor, unit: CGFloat, angle: CGFloat, in cg: CGContext) {
        cg.rotate(by: -angle)
        if abs(element.rotation.truncatingRemainder(dividingBy: 360)) > 0.5 || element.id == selectedID {
            let tip = CGPoint(x: cos(angle) * (r + unit * 1.8), y: sin(angle) * (r + unit * 1.8))
            let side = CGVector(dx: -sin(angle) * r * 0.5, dy: cos(angle) * r * 0.5)
            let back = CGPoint(x: cos(angle) * r * 0.55, y: sin(angle) * r * 0.55)
            cg.setFillColor(UIColor.white.cgColor)
            cg.addLines(between: [tip, CGPoint(x: back.x + side.dx, y: back.y + side.dy), CGPoint(x: back.x - side.dx, y: back.y - side.dy)])
            cg.closePath()
            cg.fillPath()
        }
        let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        cg.saveGState()
        dropShadow(unit, in: cg)
        cg.setFillColor(base.cgColor)
        cg.fillEllipse(in: rect)
        cg.restoreGState()
        cg.saveGState()
        cg.addEllipse(in: rect)
        cg.clip()
        if element.kind == .referee {
            // Referee stripes.
            cg.setFillColor(UIColor(white: 0.07, alpha: 0.85).cgColor)
            var x = -r * 1.6
            while x < r * 1.6 {
                cg.move(to: CGPoint(x: x, y: -r)); cg.addLine(to: CGPoint(x: x + r * 0.28, y: -r)); cg.addLine(to: CGPoint(x: x + r * 0.28 + r, y: r)); cg.addLine(to: CGPoint(x: x + r, y: r))
                cg.closePath()
                x += r * 0.56
            }
            cg.fillPath()
        }
        gradientFill(linear: [UIColor.white.withAlphaComponent(0), UIColor.black.withAlphaComponent(0.22)], from: CGPoint(x: 0, y: -r * 0.1), to: CGPoint(x: 0, y: r), in: cg)
        gradientFill(radial: [UIColor.white.withAlphaComponent(0.45), UIColor.white.withAlphaComponent(0)], center: CGPoint(x: -r * 0.38, y: -r * 0.5), radius: r * 0.95, in: cg)
        cg.restoreGState()
        let rim = max(1, unit * 0.42)
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.96).cgColor)
        cg.setLineWidth(rim)
        cg.strokeEllipse(in: rect.insetBy(dx: rim / 2, dy: rim / 2))
        let letter = element.kind == .coach ? "C" : "R"
        let badge = r * 0.62
        if element.kind == .referee {
            cg.setFillColor(UIColor(white: 0.05, alpha: 0.85).cgColor)
            cg.fillEllipse(in: CGRect(x: -badge, y: -badge, width: badge * 2, height: badge * 2))
        }
        drawText(element.label.isEmpty ? letter : String(element.label.prefix(2)), at: CGPoint(x: 0, y: r * 0.02), font: roundedFont(size: r * 1.0, weight: .heavy),
                 color: element.kind == .referee ? .white : contrasting(base), in: cg)
    }

    private func stepMarker(_ element: BoardElement, r: CGFloat, base: UIColor, unit: CGFloat, angle: CGFloat, in cg: CGContext) {
        cg.rotate(by: -angle) // numbers stay upright
        let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        cg.saveGState()
        dropShadow(unit, lift: 0.35, in: cg)
        cg.setFillColor(base.cgColor)
        cg.fillEllipse(in: rect)
        cg.restoreGState()
        cg.saveGState()
        cg.addEllipse(in: rect)
        cg.clip()
        gradientFill(radial: [shaded(base, by: 0.3), base, shaded(base, by: -0.15)], center: CGPoint(x: -r * 0.3, y: -r * 0.35), radius: r * 1.4, in: cg)
        cg.restoreGState()
        let rim = max(1, r * 0.13)
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(rim)
        cg.strokeEllipse(in: rect.insetBy(dx: rim * 1.2, dy: rim * 1.2))
        let text = "\(element.number ?? 1)"
        drawText(text, at: CGPoint(x: 0, y: r * 0.02), font: roundedFont(size: r * (text.count > 1 ? 0.9 : 1.1), weight: .heavy), color: contrasting(base), in: cg)
    }

    // MARK: Line length labels

    /// Length of a line-like element in metres (curves sampled).
    func lengthMeters(of element: BoardElement) -> Double {
        let w = Double(document.fieldType.meters.width), h = Double(document.fieldType.meters.height)
        // The same polyline the stroke is drawn from and a follower travels along, so the pill agrees with both.
        let points = element.lineGeometry()
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + hypot(($1.1.x - $1.0.x) * w, ($1.1.y - $1.0.y) * h) }
    }

    /// Distance pill at the middle of a line.
    func drawLengthLabel(_ element: BoardElement, samples: [CGPoint], projection: BoardProjection, in cg: CGContext) {
        guard element.showsLength == true, samples.count >= 2 else { return }
        let meters = lengthMeters(of: element)
        var text = meters >= 10 ? "\(Int(meters.rounded())) m" : String(format: "%.1f m", meters)
        if element.isAerial {
            let peak = element.lineHeightMeters(at: 0.5)
            text += peak >= 10 ? " · ↑\(Int(peak.rounded())) m" : String(format: " · ↑%.1f m", peak)
        }
        let mid = samples[samples.count / 2]
        let font = roundedFont(size: max(9, projection.unit * 2.1), weight: .bold)
        let size = measure(text, font: font)
        let pill = CGRect(x: mid.x - size.width / 2 - projection.unit, y: mid.y - size.height / 2 - projection.unit * 0.5, width: size.width + projection.unit * 2, height: size.height + projection.unit)
        cg.saveGState()
        dropShadow(projection.unit, lift: 0.5, in: cg)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        cg.setFillColor(UIColor(white: 0.06, alpha: 0.82).cgColor)
        cg.fillPath()
        cg.restoreGState()
        drawText(text, at: CGPoint(x: pill.midX, y: pill.midY), font: font, color: .white, in: cg)
    }
}
