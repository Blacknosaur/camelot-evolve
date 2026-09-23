import CoreGraphics
import CoreText
import UIKit

// MARK: - Shared painting

/// Gradient fills shared by the element renderer and the surface painter.
enum BoardGradient {
    static func linear(_ colors: [UIColor], from: CGPoint, to: CGPoint, in cg: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        cg.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// `extendsBeyondRadius` keeps painting the last colour outside `radius`; the surface painter fades
    /// its glows to clear instead and leaves what is already there untouched.
    static func radial(_ colors: [UIColor], center: CGPoint, radius: CGFloat, extendsBeyondRadius: Bool = true, in cg: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                              options: extendsBeyondRadius ? [.drawsAfterEndLocation] : [])
    }
}

/// The net mesh every goal on the board shares: the mini goal, the full goal, the pop-up, the
/// rebounder face and the goals baked into the pitch surface. One rule keeps them looking alike
/// whatever the goal type, instead of five hand-tuned spacings.
enum BoardNet {
    /// Mesh squares across the net box's longer side (the goal mouth).
    static let cells: CGFloat = 12

    /// Spacing for a net box. `minimum` is the finest mesh worth drawing in the caller's coordinate
    /// space (screen points for elements, metres for the baked surface), so small goals keep a net
    /// instead of a grey smudge.
    static func spacing(in box: CGRect, minimum: CGFloat) -> CGFloat {
        max(minimum, max(box.width, box.height) / cells)
    }

    /// Strokes the mesh over `box`. Clip to the net's shape first.
    static func mesh(in box: CGRect, minimum: CGFloat, color: UIColor, lineWidth: CGFloat, in cg: CGContext) {
        let step = spacing(in: box, minimum: minimum)
        guard step > 0 else { return }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        var x = box.minX
        while x <= box.maxX { cg.move(to: CGPoint(x: x, y: box.minY)); cg.addLine(to: CGPoint(x: x, y: box.maxY)); x += step }
        var y = box.minY
        while y <= box.maxY { cg.move(to: CGPoint(x: box.minX, y: y)); cg.addLine(to: CGPoint(x: box.maxX, y: y)); y += step }
        cg.strokePath()
    }
}

// MARK: - Projection

/// Maps normalised field coordinates to a top-down screen layout: an aspect fit of the field plus
/// its run-off, turned 90° when a portrait canvas suits the length axis. Tilted and broadcast views
/// are real 3D (`TacticalBoard3DView`); 2D drawing of those documents falls back to this top view.
struct BoardProjection {
    let field: BoardFieldType
    let size: CGSize
    /// True when the length axis runs down the screen (portrait views).
    let rotated: Bool
    /// Screen points per metre.
    let pixelsPerMeter: CGFloat
    /// Element unit (`BoardFieldType.elementUnitMeters`) in screen points; every element size is a multiple of it.
    let unit: CGFloat
    let apronMeters: CGFloat
    /// Field metres (origin top-left, x along the length) to screen.
    let metersTransform: CGAffineTransform

    /// `reserved` keeps a strip free on the trailing (width) and bottom (height) edges, e.g. for
    /// floating editor panels; the field is fitted and centred in the rest.
    init(field: BoardFieldType, size: CGSize, inset: CGFloat = 0, reserved: CGSize = .zero) {
        self.field = field
        self.size = size
        let meters = field.meters
        let usable = CGSize(width: max(1, size.width - reserved.width), height: max(1, size.height - reserved.height))
        rotated = usable.height > usable.width && field.rotatesInPortrait
        apronMeters = BoardSurfacePainter.apronMeters(field)
        let extent = CGSize(width: meters.width + 2 * apronMeters, height: meters.height + 2 * apronMeters)
        let oriented = rotated ? CGSize(width: extent.height, height: extent.width) : extent
        let available = CGSize(width: max(1, usable.width - 2 * inset), height: max(1, usable.height - 2 * inset))
        pixelsPerMeter = max(0.001, min(available.width / oriented.width, available.height / oriented.height))
        unit = CGFloat(field.elementUnitMeters) * pixelsPerMeter
        metersTransform = CGAffineTransform(translationX: usable.width / 2, y: usable.height / 2)
            .rotated(by: rotated ? .pi / 2 : 0)
            .scaledBy(x: pixelsPerMeter, y: pixelsPerMeter)
            .translatedBy(x: -meters.width / 2, y: -meters.height / 2)
    }

    func meters(_ p: BoardPoint) -> CGPoint {
        CGPoint(x: p.x * Double(field.meters.width), y: p.y * Double(field.meters.height))
    }

    func point(_ p: BoardPoint) -> CGPoint { meters(p).applying(metersTransform) }

    func points(_ list: [BoardPoint]) -> [CGPoint] { list.map(point) }

    /// Inverse mapping used for touch handling (not clamped).
    func unproject(_ screen: CGPoint) -> BoardPoint {
        let m = screen.applying(metersTransform.inverted())
        return BoardPoint(Double(m.x / field.meters.width), Double(m.y / field.meters.height))
    }

    /// Screen angle in radians of a field direction given in degrees (clockwise, 0 = +x).
    func screenAngle(_ degrees: Double) -> CGFloat {
        CGFloat(degrees * .pi / 180) + (rotated ? .pi / 2 : 0)
    }

    /// Screen rectangle of the field plus run-off.
    var surfaceFrame: CGRect {
        let meters = field.meters
        return CGRect(x: -apronMeters, y: -apronMeters, width: meters.width + 2 * apronMeters, height: meters.height + 2 * apronMeters).applying(metersTransform)
    }
}

// MARK: - Field markings

/// Line work of a field in metres. Goals, backboards and rims are drawn by `BoardSurfacePainter`.
enum FieldMarking: Sendable {
    case segment(CGPoint, CGPoint, faint: Bool = false)
    case arc(center: CGPoint, radius: Double, from: Double, to: Double)
    case spot(CGPoint)
}

extension BoardFieldType {
    var markings: [FieldMarking] {
        let w = Double(meters.width), h = Double(meters.height)
        var list: [FieldMarking] = rect(0, 0, w, h)
        switch self {
        case .footballFull:
            list += [.segment(CGPoint(x: w / 2, y: 0), CGPoint(x: w / 2, y: h)), .arc(center: CGPoint(x: w / 2, y: h / 2), radius: 9.15, from: 0, to: 360), .spot(CGPoint(x: w / 2, y: h / 2))]
            var end: [FieldMarking] = rect(0, h / 2 - 20.16, 16.5, h / 2 + 20.16) + rect(0, h / 2 - 9.16, 5.5, h / 2 + 9.16)
            end += [.spot(CGPoint(x: 11, y: h / 2)), .arc(center: CGPoint(x: 11, y: h / 2), radius: 9.15, from: -53, to: 53)]
            end += [.arc(center: .zero, radius: 1, from: 0, to: 90), .arc(center: CGPoint(x: 0, y: h), radius: 1, from: 270, to: 360)]
            list += end + end.map { mirrored($0, width: w) }
        case .footballHalf:
            list += rect(w / 2 - 20.16, 0, w / 2 + 20.16, 16.5) + rect(w / 2 - 9.16, 0, w / 2 + 9.16, 5.5)
            list += [.spot(CGPoint(x: w / 2, y: 11)), .arc(center: CGPoint(x: w / 2, y: 11), radius: 9.15, from: 37, to: 143)]
            list += [.arc(center: CGPoint(x: w / 2, y: h), radius: 9.15, from: 180, to: 360), .spot(CGPoint(x: w / 2, y: h))]
            list += [.arc(center: .zero, radius: 1, from: 0, to: 90), .arc(center: CGPoint(x: w, y: 0), radius: 1, from: 90, to: 180)]
        case .futsal:
            list += [.segment(CGPoint(x: w / 2, y: 0), CGPoint(x: w / 2, y: h)), .arc(center: CGPoint(x: w / 2, y: h / 2), radius: 3, from: 0, to: 360), .spot(CGPoint(x: w / 2, y: h / 2))]
            var end: [FieldMarking] = [.arc(center: CGPoint(x: 0, y: h / 2 - 1.5), radius: 6, from: -90, to: 0), .arc(center: CGPoint(x: 0, y: h / 2 + 1.5), radius: 6, from: 0, to: 90)]
            end += [.segment(CGPoint(x: 6, y: h / 2 - 1.5), CGPoint(x: 6, y: h / 2 + 1.5)), .spot(CGPoint(x: 6, y: h / 2)), .spot(CGPoint(x: 10, y: h / 2))]
            end += [.arc(center: .zero, radius: 0.25, from: 0, to: 90), .arc(center: CGPoint(x: 0, y: h), radius: 0.25, from: 270, to: 360)]
            list += end + end.map { mirrored($0, width: w) }
        case .basketball:
            list += [.segment(CGPoint(x: w / 2, y: 0), CGPoint(x: w / 2, y: h)), .arc(center: CGPoint(x: w / 2, y: h / 2), radius: 1.8, from: 0, to: 360)]
            var end: [FieldMarking] = [.segment(CGPoint(x: 0, y: 0.9), CGPoint(x: 2.99, y: 0.9)), .segment(CGPoint(x: 0, y: h - 0.9), CGPoint(x: 2.99, y: h - 0.9))]
            end += [.arc(center: CGPoint(x: 1.575, y: h / 2), radius: 6.75, from: -77.9, to: 77.9)]
            end += rect(0, h / 2 - 2.45, 5.8, h / 2 + 2.45) + [.arc(center: CGPoint(x: 5.8, y: h / 2), radius: 1.8, from: 0, to: 360)]
            end += [.arc(center: CGPoint(x: 1.575, y: h / 2), radius: 1.25, from: -90, to: 90)]
            list += end + end.map { mirrored($0, width: w) }
        case .blank:
            for x in stride(from: 2.5, to: w - 0.1, by: 2.5) { list.append(.segment(CGPoint(x: x, y: 0), CGPoint(x: x, y: h), faint: true)) }
            for y in stride(from: 2.5, to: h - 0.1, by: 2.5) { list.append(.segment(CGPoint(x: 0, y: y), CGPoint(x: w, y: y), faint: true)) }
        }
        return list
    }

    private func rect(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [FieldMarking] {
        let a = CGPoint(x: x1, y: y1), b = CGPoint(x: x2, y: y1), c = CGPoint(x: x2, y: y2), d = CGPoint(x: x1, y: y2)
        return [.segment(a, b), .segment(b, c), .segment(c, d), .segment(d, a)]
    }

    private func mirrored(_ marking: FieldMarking, width: Double) -> FieldMarking {
        switch marking {
        case .segment(let a, let b, let faint): .segment(CGPoint(x: width - a.x, y: a.y), CGPoint(x: width - b.x, y: b.y), faint: faint)
        case .arc(let center, let radius, let from, let to): .arc(center: CGPoint(x: width - center.x, y: center.y), radius: radius, from: 180 - to, to: 180 - from)
        case .spot(let p): .spot(CGPoint(x: width - p.x, y: p.y))
        }
    }
}

// MARK: - Handles

/// Interactive handles of the selected element.
enum BoardHandle: Equatable, Sendable {
    /// Index into `lineVertices` for lines, `allPoints` for zones and polygons.
    case vertex(Int)
    /// Midpoint of a 2-point line; dragging bends it.
    case bend
    /// Midpoint of polyline segment `index` → `index + 1`; tapping inserts a vertex.
    case insert(Int)
    case rotate
    case resize
}

// MARK: - Renderer

/// Draws a document into any CoreGraphics context (SwiftUI Canvas, image or video
/// frame). Pure function of document, time, size and selection.
struct BoardRenderer {
    var document: BoardDocument
    /// Playback time for animated boards; nil draws the editable layout.
    var time: Double? = nil
    var selectedID: UUID? = nil
    var showsHandles = false
    var inset: CGFloat = 0
    /// Element a line end would snap to; drawn with a highlight ring.
    var highlightedID: UUID? = nil
    /// Divides handle and hit sizes so they stay constant on screen while the canvas is zoomed.
    var chromeScale: CGFloat = 1
    /// Trailing (width) and bottom (height) strips kept clear of the field; see `BoardProjection`.
    var reserved: CGSize = .zero
    /// False when the view already shows the field behind the canvas, so a frame redraws only elements.
    var drawsSurface = true
    /// True while drawing a translucent onion-skin ghost: no blurred shadows (they only muddy a
    /// 30%-alpha body and cost milliseconds each) and no name pill (the live element beside it carries one).
    var isGhost = false
    /// Keyframe being edited: draws the selected element's follow path.
    var animationFrame: Int? = nil
    /// Keyframe whose neighbours are drawn as translucent onion-skin ghosts. Never set for exports.
    var onionFrame: Int? = nil
    /// Lines and shapes offered as follow paths while picking one.
    var highlightedPathIDs: Set<UUID> = []
    /// True for offscreen work (exports, thumbnails, galleries), which may block on disk to decode a squad
    /// photo. The live editor draws on the main thread, so it takes only already-decoded photos and lets
    /// `SquadPhotoStore` warm the rest in the background (see `SquadPhotoStore.didWarmPhoto`).
    var loadsPhotosSynchronously = false
    /// False draws the onion-skin ghosts straight into the canvas instead of blitting the cached layer.
    /// Only the perf probe turns it off, to time the two against each other in one thermal state.
    var cachesOnionLayer = true

    func projection(size: CGSize) -> BoardProjection {
        BoardProjection(field: document.fieldType, size: size, inset: inset, reserved: reserved)
    }

    var visibleElements: [BoardElement] {
        document.elements(at: time).sorted { $0.kind.zOrder < $1.kind.zOrder }
    }

    private var style: BoardFieldStyle { document.fieldStyle }

    func draw(in cg: CGContext, size: CGSize) {
        let projection = projection(size: size)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if drawsSurface { drawSurface(projection, in: cg) }
        let elements = visibleElements
        if onionFrame != nil { drawOnionSkin(live: elements, projection: projection, in: cg) }
        for element in elements {
            draw(element, all: elements, projection: projection, in: cg)
        }
        drawPathHighlights(elements, projection: projection, in: cg)
        drawFollowPreview(elements, projection: projection, in: cg)
        if let highlightedID, let target = elements.first(where: { $0.id == highlightedID }) {
            drawHighlight(target, projection: projection, in: cg)
        }
        if let selectedID, let selected = elements.first(where: { $0.id == selectedID }) {
            drawSelection(selected, all: elements, projection: projection, in: cg)
        }
    }

    // MARK: Field

    private func drawSurface(_ projection: BoardProjection, in cg: CGContext) {
        let device = cg.userSpaceToDeviceSpaceTransform
        let deviceScale = max(1, hypot(device.a, device.b))
        // Fast path: the whole surface already laid out for this canvas, blitted 1:1 with no resampling.
        if let laidOut = BoardSurfaceCache.shared.canvas(field: document.fieldType, style: style, size: projection.size, inset: inset, reserved: reserved, scale: deviceScale) {
            let rect = CGRect(origin: .zero, size: projection.size)
            cg.saveGState()
            // CGContext.draw puts image row 0 at the bottom; flip so the image top sits at rect.minY.
            cg.translateBy(x: 0, y: rect.minY + rect.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .low
            cg.draw(laidOut, in: rect)
            cg.restoreGState()
            return
        }
        // Zoomed too far in for a screen-sized bitmap: compose the slab through the projection instead.
        guard let slab = BoardSurfaceCache.shared.slab(field: document.fieldType, style: style, pixelsPerMeter: projection.pixelsPerMeter * deviceScale) else { return }
        let meters = document.fieldType.meters
        let rect = CGRect(x: -slab.apron - slab.padding, y: -slab.apron - slab.padding,
                          width: meters.width + 2 * (slab.apron + slab.padding), height: meters.height + 2 * (slab.apron + slab.padding))
        cg.saveGState()
        cg.concatenate(projection.metersTransform)
        // CGContext.draw puts image row 0 at the bottom; flip so the image top sits at rect.minY.
        cg.translateBy(x: 0, y: rect.minY + rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .low
        cg.draw(slab.image, in: rect)
        cg.restoreGState()
    }

    // MARK: Colours

    /// Element colour adapted to the surface: white ink turns dark on the light classic style.
    func color(_ hex: String) -> UIColor {
        if style == .classic, hex == BoardPalette.white { return UIColor(red: 0.12, green: 0.14, blue: 0.16, alpha: 1) }
        let (r, g, b) = BoardPalette.rgb(hex)
        if style == .chalk || style == .night, 0.299 * r + 0.587 * g + 0.114 * b < 0.25 {
            // Near-black kit and equipment would vanish on dark surfaces; lift it to a readable graphite.
            return shaded(BoardPalette.uiColor(hex), by: 0.38)
        }
        return BoardPalette.uiColor(hex)
    }

    func shaded(_ color: UIColor, by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let target: CGFloat = amount > 0 ? 1 : 0, t = abs(amount)
        return UIColor(red: r + (target - r) * t, green: g + (target - g) * t, blue: b + (target - b) * t, alpha: a)
    }

    // MARK: Elements

    func draw(_ element: BoardElement, all: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        // An element following an aerial line lifts up the screen, grows a little and casts its shadow below.
        if let height = element.heightMeters, height > 0.01, element.kind.isPoint {
            let heading = projection.screenAngle(element.heightDirectionDegrees ?? 0)
            let offset = Self.liftOffset(height, tangent: CGVector(dx: cos(heading), dy: sin(heading)), projection: projection)
            let center = projection.point(element.position)
            let radius = pointRadius(element, projection: projection)
            cg.saveGState()
            cg.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
            cg.setShadow(offset: .zero, blur: projection.unit * 1.2, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - radius * 0.9, y: center.y - radius * 0.45, width: radius * 1.8, height: radius * 0.9))
            cg.restoreGState()
            var lifted = element
            lifted.heightMeters = nil
            lifted.size = min(BoardElement.sizeRange.upperBound, element.size * (1 + min(0.5, height * 0.04)))
            cg.saveGState()
            cg.translateBy(x: offset.width, y: offset.height)
            draw(lifted, all: all, projection: projection, in: cg)
            cg.restoreGState()
            return
        }
        switch element.kind {
        case .player, .goalkeeper, .opponent: drawPerson(element, projection: projection, in: cg)
        case .ball: drawBall(element, projection: projection, in: cg)
        case .cone: drawCone(element, projection: projection, in: cg)
        case .marker: drawMarker(element, projection: projection, in: cg)
        case .miniGoal: drawMiniGoal(element, projection: projection, in: cg)
        case .mannequin: drawMannequin(element, projection: projection, in: cg)
        case .text: drawTextElement(element, projection: projection, in: cg)
        case .arrow, .line, .polyline: drawLine(element, all: all, projection: projection, in: cg)
        case .zone, .polygon: drawArea(element, projection: projection, in: cg)
        case .tallCone, .domeCone, .pole, .hurdle, .ladder, .ring, .wall, .goal, .popUpGoal, .rebounder, .flag, .ballCart, .coach, .referee, .stepMarker:
            drawTraining(element, projection: projection, in: cg)
        }
    }

    /// Screen radius of a point element's body.
    func pointRadius(_ element: BoardElement, projection: BoardProjection) -> CGFloat {
        if element.kind == .text { return textPill(element, projection: projection).size.width / 2 }
        return CGFloat(element.visualRadiusMeters(field: document.fieldType)) * projection.pixelsPerMeter
    }

    func dropShadow(_ unit: CGFloat, lift: CGFloat = 1, in cg: CGContext) {
        guard !isGhost else { return }
        cg.setShadow(offset: CGSize(width: unit * 0.3 * lift, height: unit * 0.7 * lift), blur: unit * 1.6 * lift, color: UIColor.black.withAlphaComponent(0.42).cgColor)
    }

    private func drawPerson(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let base = color(element.colorHex)
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        let angle = projection.screenAngle(element.rotation)
        // Linked squad players with a photo show it inside the disc. On the main thread this never
        // touches the disk: a photo that is not decoded yet is warmed in the background and the canvas
        // redraws when it lands, rather than opening and decoding a JPEG per player inside a frame.
        let photo = element.kind == .opponent ? nil : element.playerID.flatMap { id in
            loadsPhotosSynchronously ? SquadPhotoStore.image(for: id) : SquadPhotoStore.cachedImage(for: id)?.image
        }

        // Facing notch sits under the disc so only its tip shows.
        if showsFacing(element) {
            let tip = CGPoint(x: center.x + cos(angle) * (r + unit * 1.8), y: center.y + sin(angle) * (r + unit * 1.8))
            let side = CGVector(dx: -sin(angle) * r * 0.5, dy: cos(angle) * r * 0.5)
            let back = CGPoint(x: center.x + cos(angle) * r * 0.55, y: center.y + sin(angle) * r * 0.55)
            // No blurred shadow: the notch sits under the disc and only its tip shows, where the
            // disc's own shadow already reads. One blurred shadow per player instead of three.
            cg.setFillColor((element.kind == .opponent ? base : UIColor.white).cgColor)
            cg.addLines(between: [tip, CGPoint(x: back.x + side.dx, y: back.y + side.dy), CGPoint(x: back.x - side.dx, y: back.y - side.dy)])
            cg.closePath()
            cg.fillPath()
        }

        // The disc never changes between frames, so each distinct look is drawn once into a small image
        // and blitted after that. Photo discs stay live: their look is unbounded and they are rare.
        if photo == nil, let sprite = Self.discCache.disc(for: element, renderer: self, center: center, r: r, unit: unit, in: cg) {
            cg.saveGState()
            // CGContext.draw puts image row 0 at the bottom; flip so the sprite top sits at rect.minY.
            cg.translateBy(x: 0, y: sprite.rect.minY + sprite.rect.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(sprite.image, in: sprite.rect)
            cg.restoreGState()
        } else {
            drawPersonDisc(element, base: base, center: center, r: r, unit: unit, photo: photo, in: cg)
        }
        if !element.label.isEmpty, !isGhost {
            let font = roundedFont(size: max(8, unit * 2.0), weight: .semibold)
            let measured = measure(element.label, font: font)
            // Clears the number tab of a photo disc.
            let pillTop = center.y + r + unit * 0.9 + (photo != nil && element.number != nil ? r * 0.3 : 0)
            let pill = CGRect(x: center.x - measured.width / 2 - unit * 1.1, y: pillTop, width: measured.width + unit * 2.2, height: measured.height + unit * 0.9)
            // The pill is near-black already, so it separates from the field without a blurred shadow.
            cg.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            cg.setFillColor(UIColor(white: 0.06, alpha: 0.78).cgColor)
            cg.fillPath()
            drawText(element.label, at: CGPoint(x: pill.midX, y: pill.midY), font: font, color: .white, in: cg)
        }
    }

    /// Body, gloss, rim and number of a person, centred on `center`. Split out so it can be drawn
    /// either straight into the canvas or once into a cached sprite.
    func drawPersonDisc(_ element: BoardElement, base: UIColor, center: CGPoint, r: CGFloat, unit: CGFloat, photo: CGImage?, in cg: CGContext) {
        func bodyPath(inset: CGFloat) -> CGPath {
            element.kind == .goalkeeper
                ? CGPath(roundedRect: CGRect(x: center.x - r * 0.93 + inset, y: center.y - r * 0.93 + inset, width: r * 1.86 - 2 * inset, height: r * 1.86 - 2 * inset), cornerWidth: max(0, r * 0.62 - inset), cornerHeight: max(0, r * 0.62 - inset), transform: nil)
                : CGPath(ellipseIn: CGRect(x: center.x - r + inset, y: center.y - r + inset, width: 2 * (r - inset), height: 2 * (r - inset)), transform: nil)
        }
        let body = bodyPath(inset: 0)
        cg.saveGState()
        dropShadow(unit, in: cg)
        cg.addPath(body)
        cg.setFillColor((element.kind == .opponent ? UIColor(white: 0.07, alpha: 0.82) : base).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // Gloss: a bright top-left highlight and a darker lower edge.
        cg.saveGState()
        cg.addPath(body)
        cg.clip()
        if let photo {
            let rect = body.boundingBox
            cg.saveGState()
            // CGContext.draw puts image row 0 at the bottom; flip so the photo is upright.
            cg.translateBy(x: 0, y: rect.minY + rect.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            cg.draw(photo, in: rect)
            cg.restoreGState()
            gradientFill(radial: [UIColor.white.withAlphaComponent(0.16), UIColor.white.withAlphaComponent(0)], center: CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.5), radius: r * 0.8, in: cg)
        } else if element.kind == .opponent {
            gradientFill(radial: [base.withAlphaComponent(0.34), base.withAlphaComponent(0.12)], center: CGPoint(x: center.x - r * 0.3, y: center.y - r * 0.4), radius: r * 1.4, in: cg)
        } else {
            gradientFill(linear: [UIColor.white.withAlphaComponent(0.0), UIColor.black.withAlphaComponent(0.22)], from: CGPoint(x: center.x, y: center.y - r * 0.1), to: CGPoint(x: center.x, y: center.y + r), in: cg)
            gradientFill(radial: [UIColor.white.withAlphaComponent(0.5), UIColor.white.withAlphaComponent(0)], center: CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.5), radius: r * 0.95, in: cg)
        }
        cg.restoreGState()

        let rim = max(1, unit * (element.kind == .opponent ? 0.75 : photo != nil ? 0.7 : 0.42) * CGFloat(element.size).squareRoot())
        cg.addPath(bodyPath(inset: rim / 2))
        cg.setStrokeColor((element.kind == .opponent || photo != nil ? base : UIColor.white.withAlphaComponent(0.96)).cgColor)
        cg.setLineWidth(rim)
        cg.strokePath()

        if photo != nil, let number = element.number {
            // Team-coloured number tab over the bottom edge, so the face stays visible and the number readable.
            let text = "\(number)"
            let font = roundedFont(size: max(6, r * 0.5), weight: .heavy)
            let measured = measure(text, font: font)
            let height = max(measured.height + r * 0.04, r * 0.56)
            let width = max(height * 1.25, measured.width + r * 0.4)
            let tab = CGRect(x: center.x - width / 2, y: center.y + r * 1.02 - height * 0.5, width: width, height: height)
            cg.saveGState()
            dropShadow(unit, lift: 0.4, in: cg)
            cg.addPath(CGPath(roundedRect: tab, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            cg.setFillColor(base.cgColor)
            cg.fillPath()
            cg.restoreGState()
            cg.addPath(CGPath(roundedRect: tab.insetBy(dx: rim * 0.25, dy: rim * 0.25), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(max(0.5, rim * 0.5))
            cg.strokePath()
            drawText(text, at: CGPoint(x: tab.midX, y: tab.midY), font: font, color: contrasting(base), in: cg)
        } else if let number = element.number {
            let text = "\(number)"
            let font = roundedFont(size: r * (text.count > 1 ? 0.92 : 1.08), weight: .heavy)
            let ink: UIColor = element.kind == .opponent ? shaded(base, by: 0.35) : contrasting(base)
            drawText(text, at: CGPoint(x: center.x, y: center.y + r * 0.02), font: font, color: ink, in: cg)
        }
    }

    private func showsFacing(_ element: BoardElement) -> Bool {
        let degrees = element.rotation.truncatingRemainder(dividingBy: 360)
        return abs(degrees) > 0.5 || element.id == selectedID
    }

    private func drawBall(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let basketball = document.fieldType.usesBasketball
        let base = basketball ? UIColor(red: 0.93, green: 0.47, blue: 0.16, alpha: 1) : UIColor.white
        cg.saveGState()
        dropShadow(unit, lift: 0.8, in: cg)
        cg.setFillColor(base.cgColor)
        cg.fillEllipse(in: rect)
        cg.restoreGState()
        cg.saveGState()
        cg.addEllipse(in: rect)
        cg.clip()
        let angle = projection.screenAngle(element.rotation)
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: angle)
        if basketball {
            cg.setStrokeColor(UIColor(white: 0.1, alpha: 0.75).cgColor)
            cg.setLineWidth(max(0.6, r * 0.09))
            cg.move(to: CGPoint(x: -r, y: 0)); cg.addLine(to: CGPoint(x: r, y: 0))
            cg.move(to: CGPoint(x: 0, y: -r)); cg.addLine(to: CGPoint(x: 0, y: r))
            cg.addArc(center: CGPoint(x: -r * 1.25, y: 0), radius: r * 0.95, startAngle: -0.8, endAngle: 0.8, clockwise: false)
            cg.move(to: CGPoint(x: r * 1.25 + r * 0.95 * cos(.pi - 0.8), y: r * 0.95 * sin(.pi - 0.8)))
            cg.addArc(center: CGPoint(x: r * 1.25, y: 0), radius: r * 0.95, startAngle: .pi - 0.8, endAngle: .pi + 0.8, clockwise: false)
            cg.strokePath()
        } else {
            cg.setFillColor(UIColor(white: 0.12, alpha: 0.9).cgColor)
            cg.addPath(regularPolygon(center: .zero, radius: r * 0.36, sides: 5, rotation: -.pi / 2))
            for index in 0..<5 {
                let a = CGFloat(index) * 2 * .pi / 5 + .pi / 2
                cg.addPath(regularPolygon(center: CGPoint(x: cos(a) * r * 1.02, y: sin(a) * r * 1.02), radius: r * 0.36, sides: 5, rotation: a))
            }
            cg.fillPath()
        }
        cg.restoreGState()
        cg.saveGState()
        cg.addEllipse(in: rect)
        cg.clip()
        gradientFill(radial: [UIColor.white.withAlphaComponent(0.55), UIColor.white.withAlphaComponent(0), UIColor.black.withAlphaComponent(0.28)], center: CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4), radius: r * 1.6, in: cg)
        cg.restoreGState()
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        cg.setLineWidth(max(0.5, r * 0.07))
        cg.strokeEllipse(in: rect)
    }

    private func drawCone(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let base = color(element.colorHex)
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        // Long soft shadow cast down-right, as if the cone stands up.
        cg.saveGState()
        cg.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
        cg.setShadow(offset: .zero, blur: unit * 1.2, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        cg.translateBy(x: center.x + r * 0.55, y: center.y + r * 0.8)
        cg.rotate(by: .pi / 5)
        cg.fillEllipse(in: CGRect(x: -r * 1.25, y: -r * 0.75, width: r * 2.5, height: r * 1.5))
        cg.restoreGState()
        // Flat base plate.
        cg.setFillColor(shaded(base, by: -0.28).cgColor)
        cg.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        // Body lit from the top left, with the apex slightly offset.
        let body = CGRect(x: center.x - r * 0.72, y: center.y - r * 0.72, width: r * 1.44, height: r * 1.44)
        cg.saveGState()
        cg.addEllipse(in: body)
        cg.clip()
        let apex = CGPoint(x: center.x - r * 0.12, y: center.y - r * 0.16)
        cg.setFillColor(base.cgColor)
        cg.fill(body)
        gradientFill(radial: [shaded(base, by: 0.45), base, shaded(base, by: -0.18)], center: apex, radius: r * 0.85, in: cg)
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        cg.setLineWidth(r * 0.13)
        cg.strokeEllipse(in: CGRect(x: apex.x - r * 0.42, y: apex.y - r * 0.42, width: r * 0.84, height: r * 0.84))
        cg.restoreGState()
        cg.setFillColor(shaded(base, by: -0.35).cgColor)
        cg.fillEllipse(in: CGRect(x: apex.x - r * 0.11, y: apex.y - r * 0.11, width: r * 0.22, height: r * 0.22))
    }

    private func drawMarker(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let base = color(element.colorHex)
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        let disc = CGMutablePath()
        disc.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        disc.addEllipse(in: CGRect(x: center.x - r * 0.36, y: center.y - r * 0.36, width: r * 0.72, height: r * 0.72))
        cg.saveGState()
        dropShadow(unit, lift: 0.4, in: cg)
        cg.addPath(disc)
        cg.setFillColor(base.cgColor)
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(disc)
        cg.clip(using: .evenOdd)
        gradientFill(radial: [shaded(base, by: 0.35), base, shaded(base, by: -0.2)], center: CGPoint(x: center.x - r * 0.3, y: center.y - r * 0.35), radius: r * 1.3, in: cg)
        cg.restoreGState()
        cg.setStrokeColor(shaded(base, by: -0.3).withAlphaComponent(0.6).cgColor)
        cg.setLineWidth(max(0.5, r * 0.06))
        cg.strokeEllipse(in: CGRect(x: center.x - r * 0.36, y: center.y - r * 0.36, width: r * 0.72, height: r * 0.72))
    }

    /// Mini goal in local coordinates: mouth along the local x axis facing local -y, net behind it (+y).
    private func drawMiniGoal(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let frameColor = color(element.colorHex)
        let center = projection.point(element.position)
        let halfWidth = pointRadius(element, projection: projection), depth = halfWidth * 0.8
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: projection.screenAngle(element.rotation))
        let box = CGRect(x: -halfWidth, y: -depth / 2, width: halfWidth * 2, height: depth)
        cg.saveGState()
        dropShadow(unit, lift: 0.7, in: cg)
        cg.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        cg.fill(box)
        cg.restoreGState()
        cg.saveGState()
        cg.clip(to: box)
        BoardNet.mesh(in: box, minimum: 2, color: UIColor.white.withAlphaComponent(0.38), lineWidth: max(0.4, unit * 0.1), in: cg)
        cg.restoreGState()
        cg.setStrokeColor(frameColor.withAlphaComponent(0.75).cgColor)
        cg.setLineWidth(max(0.8, unit * 0.32))
        cg.addLines(between: [CGPoint(x: -halfWidth, y: box.minY), CGPoint(x: -halfWidth, y: box.maxY), CGPoint(x: halfWidth, y: box.maxY), CGPoint(x: halfWidth, y: box.minY)])
        cg.strokePath()
        cg.saveGState()
        dropShadow(unit, lift: 0.5, in: cg)
        cg.setStrokeColor(frameColor.cgColor)
        cg.setLineWidth(max(1.2, unit * 0.62))
        cg.move(to: CGPoint(x: -halfWidth, y: box.minY)); cg.addLine(to: CGPoint(x: halfWidth, y: box.minY))
        cg.strokePath()
        cg.restoreGState()
        cg.setFillColor(frameColor.cgColor)
        for px in [-halfWidth, halfWidth] { cg.fillEllipse(in: CGRect(x: px - unit * 0.5, y: box.minY - unit * 0.5, width: unit, height: unit)) }
        cg.restoreGState()
    }

    /// Training mannequin seen from above: shoulders across the facing direction, head in front.
    private func drawMannequin(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let base = color(element.colorHex)
        let center = projection.point(element.position)
        let r = pointRadius(element, projection: projection)
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: projection.screenAngle(element.rotation))
        cg.setStrokeColor(base.withAlphaComponent(0.35).cgColor)
        cg.setLineWidth(max(0.6, unit * 0.2))
        cg.strokeEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        let shoulders = CGRect(x: -r * 0.42, y: -r * 1.0, width: r * 0.84, height: r * 2.0)
        let shoulderPath = CGPath(roundedRect: shoulders, cornerWidth: r * 0.34, cornerHeight: r * 0.34, transform: nil)
        cg.saveGState()
        dropShadow(unit, in: cg)
        cg.addPath(shoulderPath)
        cg.setFillColor(base.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(shoulderPath)
        cg.clip()
        gradientFill(linear: [shaded(base, by: 0.3), shaded(base, by: -0.25)], from: CGPoint(x: -r * 0.36, y: -r), to: CGPoint(x: r * 0.36, y: r), in: cg)
        cg.restoreGState()
        let head = CGRect(x: -r * 0.05, y: -r * 0.34, width: r * 0.68, height: r * 0.68)
        cg.setFillColor(shaded(base, by: 0.2).cgColor)
        cg.fillEllipse(in: head)
        cg.setStrokeColor(shaded(base, by: -0.35).cgColor)
        cg.setLineWidth(max(0.5, unit * 0.14))
        cg.strokeEllipse(in: head)
        cg.restoreGState()
    }

    private func textFont(_ element: BoardElement, projection: BoardProjection) -> UIFont {
        roundedFont(size: max(7, projection.unit * 2.7 * CGFloat(element.size)), weight: .semibold)
    }

    /// Local (unrotated) pill rectangle centred on the origin.
    private func textPill(_ element: BoardElement, projection: BoardProjection) -> CGRect {
        let measured = measure(element.label.isEmpty ? " " : element.label, font: textFont(element, projection: projection))
        let padX = projection.unit * 1.4 * CGFloat(element.size), padY = projection.unit * 0.65 * CGFloat(element.size)
        return CGRect(x: -measured.width / 2 - padX, y: -measured.height / 2 - padY, width: measured.width + padX * 2, height: measured.height + padY * 2)
    }

    private func drawTextElement(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let center = projection.point(element.position)
        let pill = textPill(element, projection: projection)
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: projection.screenAngle(element.rotation))
        cg.saveGState()
        dropShadow(projection.unit, lift: 0.6, in: cg)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        cg.setFillColor(UIColor(white: 0.05, alpha: 0.72).cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        cg.setStrokeColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        cg.setLineWidth(1)
        cg.strokePath()
        let ink = style == .classic && element.colorHex == BoardPalette.white ? UIColor.white : color(element.colorHex)
        drawText(element.label, at: .zero, font: textFont(element, projection: projection), color: ink, in: cg)
        cg.restoreGState()
    }

    // MARK: Lines

    private func strokeWidth(_ style: BoardLineStyle, projection: BoardProjection) -> CGFloat {
        max(1, projection.unit * 0.8 * CGFloat(style.width))
    }

    /// Centre line of a line-like element, trimmed at attached ends so caps stay outside the element.
    func lineSamples(_ element: BoardElement, all: [BoardElement], projection: BoardProjection) -> [CGPoint] {
        let vertices = projection.points(element.lineVertices)
        guard vertices.count >= 2 else { return vertices }
        var samples: [CGPoint]
        // Roughly one sample every few points: finer adds nothing at board sizes but costs per frame.
        let step = max(4, projection.unit * 1.2)
        if let control = element.curveControl.map(projection.point) {
            let length = hypot(control.x - vertices[0].x, control.y - vertices[0].y) + hypot(vertices[1].x - control.x, vertices[1].y - control.y)
            // A whole number of `BoardElement.curveSampleCount` steps, so the drawn stroke passes exactly
            // through the points the length label and follow-path geometry measure, only finer when zoomed.
            let canonical = BoardElement.curveSampleCount
            let count = canonical * max(1, Int((length / step / CGFloat(canonical)).rounded(.up)))
            samples = (0...count).map { index in
                let t = CGFloat(index) / CGFloat(count), u = 1 - t
                return CGPoint(x: u * u * vertices[0].x + 2 * u * t * control.x + t * t * vertices[1].x, y: u * u * vertices[0].y + 2 * u * t * control.y + t * t * vertices[1].y)
            }
        } else {
            samples = [vertices[0]]
            for (a, b) in zip(vertices, vertices.dropFirst()) {
                let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
                for index in 1...count { samples.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(index) / CGFloat(count), y: a.y + (b.y - a.y) * CGFloat(index) / CGFloat(count))) }
            }
        }
        let gap = projection.unit * 0.7
        func trim(_ id: UUID?) -> CGFloat {
            guard let id, let target = all.first(where: { $0.id == id }) else { return 0 }
            return pointRadius(target, projection: projection) + gap
        }
        samples = trimmed(samples, fromStart: trim(element.startAttachment))
        samples = Array(trimmed(Array(samples.reversed()), fromStart: trim(element.endAttachment)).reversed())
        return samples
    }

    private func trimmed(_ samples: [CGPoint], fromStart distance: CGFloat) -> [CGPoint] {
        guard distance > 0, samples.count >= 2 else { return samples }
        let total = zip(samples, samples.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // Never trim a short line away entirely.
        var remaining = min(distance, total * 0.45)
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            if length >= remaining {
                let t = length > 0 ? remaining / length : 0
                return [CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)] + samples[index...]
            }
            remaining -= length
        }
        return Array(samples.suffix(2))
    }

    private func drawLine(_ element: BoardElement, all: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        let lineStyle = element.resolvedLineStyle
        let ground = lineSamples(element, all: all, projection: projection)
        guard ground.count >= 2 else { return }
        let unit = projection.unit
        let width = strokeWidth(lineStyle, projection: projection)
        let color = self.color(element.colorHex)
        let headLength = unit * 2.2 + width * 1.9
        let groundLengths = cumulativeLengths(ground)
        let groundTotal = groundLengths.last ?? 0
        guard groundTotal > 0.5 else { return }
        // Aerial lines are drawn lifted up the screen, with their ground track and height ticks below.
        let samples: [CGPoint] = element.isAerial
            ? ground.enumerated().map { index, point in
                let ahead = ground[min(ground.count - 1, index + 1)], behind = ground[max(0, index - 1)]
                let offset = Self.liftOffset(element.lineHeightMeters(at: groundTotal > 0 ? groundLengths[index] / groundTotal : 0),
                                             tangent: CGVector(dx: ahead.x - behind.x, dy: ahead.y - behind.y), projection: projection)
                return CGPoint(x: point.x + offset.width, y: point.y + offset.height)
            }
            : ground
        if element.isAerial { drawGroundTrack(ground: ground, air: samples, color: color, projection: projection, in: cg) }
        let lengths = cumulativeLengths(samples)
        let total = lengths.last ?? 0
        guard total > 0.5 else { return }
        let startInset = capInset(lineStyle.startCap, head: headLength, width: width)
        let endInset = capInset(lineStyle.endCap, head: headLength, width: width)
        var shaft = samples
        if lineStyle.shape != .straight {
            shaft = squiggle(samples, lengths: lengths, shape: lineStyle.shape, width: width, unit: unit, clearStart: startInset * 1.4, clearEnd: endInset * 1.4)
        }
        shaft = trimmed(shaft, fromStart: startInset * 0.62)
        shaft = Array(trimmed(Array(shaft.reversed()), fromStart: endInset * 0.62).reversed())

        cg.saveGState()
        cg.setAlpha(CGFloat(lineStyle.strokeOpacity))
        let stroke = element.isAerial ? shaded(color, by: 0.18) : color
        let strokeWidth = element.isAerial ? width * 1.25 : width
        let shaftPath = smoothPath(shaft)
        let dashes: [CGFloat] = switch lineStyle.pattern {
        case .solid: []
        case .dashed: [width * 3.2 + unit * 0.8, width * 2.2 + unit * 0.9]
        case .dotted: [0.001, width * 2.1 + unit * 0.4]
        }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineDash(phase: 0, lengths: dashes)
        // Shadow: one offset dark stroke instead of a blurred shadow inside a transparency layer, which
        // costs milliseconds per line. It reads the same at board sizes and keeps dashes from stacking.
        let lift = unit * (element.isAerial ? 1.6 : 0.55)
        cg.saveGState()
        cg.translateBy(x: lift * 0.35, y: lift * 0.9)
        cg.setStrokeColor(UIColor.black.withAlphaComponent(element.isAerial ? 0.3 : 0.24).cgColor)
        cg.setLineWidth(strokeWidth * 1.15)
        cg.addPath(shaftPath)
        cg.strokePath()
        cg.restoreGState()
        cg.setStrokeColor(stroke.cgColor)
        cg.setFillColor(stroke.cgColor)
        cg.setLineWidth(strokeWidth)
        cg.addPath(shaftPath)
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        drawCap(lineStyle.endCap, tip: samples[samples.count - 1], direction: direction(samples.reversed(), lengthBack: headLength), head: headLength, width: width, in: cg)
        drawCap(lineStyle.startCap, tip: samples[0], direction: direction(samples, lengthBack: headLength), head: headLength, width: width, in: cg)
        cg.restoreGState()
        drawLengthLabel(element, samples: samples, projection: projection, in: cg)
    }

    /// Screen offset in points for a height in metres (the same factor the follower lift uses).
    static func liftPoints(_ heightMeters: Double, projection: BoardProjection) -> CGFloat {
        CGFloat(max(0, heightMeters)) * projection.pixelsPerMeter * 0.55
    }

    /// Height is drawn perpendicular to the path (towards the top of the screen), so a line bows however it
    /// runs on screen; lifting straight up would vanish on a line that already runs up the screen.
    static func liftOffset(_ heightMeters: Double, tangent: CGVector, projection: BoardProjection) -> CGSize {
        let length = hypot(tangent.dx, tangent.dy)
        var normal = length > 0.0001 ? CGVector(dx: -tangent.dy / length, dy: tangent.dx / length) : CGVector(dx: 0, dy: -1)
        if normal.dy > 0 { normal = CGVector(dx: -normal.dx, dy: -normal.dy) }
        let lift = liftPoints(heightMeters, projection: projection)
        return CGSize(width: normal.dx * lift, height: normal.dy * lift)
    }

    /// Dashed ground track under an aerial line, with ticks joining it to the line in the air.
    private func drawGroundTrack(ground: [CGPoint], air: [CGPoint], color: UIColor, projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        cg.saveGState()
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        cg.setLineWidth(max(1, unit * 0.4))
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: [unit * 1.1, unit * 1.1])
        cg.addPath(smoothPath(ground))
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
        cg.setLineWidth(max(0.6, unit * 0.2))
        let step = max(1, ground.count / 8)
        for index in stride(from: step, to: ground.count - 1, by: step) where hypot(air[index].x - ground[index].x, air[index].y - ground[index].y) > 2 {
            cg.move(to: ground[index]); cg.addLine(to: air[index])
        }
        cg.strokePath()
        cg.restoreGState()
    }

    private func capInset(_ cap: BoardLineCap, head: CGFloat, width: CGFloat) -> CGFloat {
        switch cap {
        case .arrow: head
        case .dot: width * 1.2
        case .bar, .none: 0
        }
    }

    /// Unit vector pointing out of the line at its first sample, measured over `lengthBack`.
    private func direction(_ samples: some Collection<CGPoint>, lengthBack: CGFloat) -> CGVector {
        let list = Array(samples)
        guard let tip = list.first else { return CGVector(dx: 1, dy: 0) }
        var reference = list.last ?? tip
        for point in list.dropFirst() where hypot(point.x - tip.x, point.y - tip.y) >= lengthBack {
            reference = point
            break
        }
        let length = max(0.0001, hypot(tip.x - reference.x, tip.y - reference.y))
        return CGVector(dx: (tip.x - reference.x) / length, dy: (tip.y - reference.y) / length)
    }

    private func drawCap(_ cap: BoardLineCap, tip: CGPoint, direction d: CGVector, head: CGFloat, width: CGFloat, in cg: CGContext) {
        let normal = CGVector(dx: -d.dy, dy: d.dx)
        switch cap {
        case .none:
            break
        case .arrow:
            // Swept head with a shallow notch, softened by a thin round-joined stroke.
            let base = CGPoint(x: tip.x - d.dx * head, y: tip.y - d.dy * head)
            let half = head * 0.52
            let notch = CGPoint(x: tip.x - d.dx * head * 0.7, y: tip.y - d.dy * head * 0.7)
            let path = CGMutablePath()
            path.addLines(between: [tip, CGPoint(x: base.x + normal.dx * half, y: base.y + normal.dy * half), notch, CGPoint(x: base.x - normal.dx * half, y: base.y - normal.dy * half)])
            path.closeSubpath()
            cg.addPath(path)
            cg.fillPath()
            cg.addPath(path)
            cg.setLineWidth(max(0.8, width * 0.35))
            cg.strokePath()
        case .bar:
            let half = head * 0.55
            cg.setLineWidth(width * 1.25)
            cg.move(to: CGPoint(x: tip.x + normal.dx * half, y: tip.y + normal.dy * half))
            cg.addLine(to: CGPoint(x: tip.x - normal.dx * half, y: tip.y - normal.dy * half))
            cg.strokePath()
        case .dot:
            let r = width * 1.3 + head * 0.12
            cg.fillEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
        }
    }

    private func cumulativeLengths(_ samples: [CGPoint]) -> [CGFloat] {
        var result: [CGFloat] = [0]
        for (a, b) in zip(samples, samples.dropFirst()) { result.append((result.last ?? 0) + hypot(b.x - a.x, b.y - a.y)) }
        return result
    }

    /// Offsets the line sideways in a sine or triangle wave, easing to straight near both ends.
    private func squiggle(_ samples: [CGPoint], lengths: [CGFloat], shape: BoardLineShape, width: CGFloat, unit: CGFloat, clearStart: CGFloat, clearEnd: CGFloat) -> [CGPoint] {
        let total = lengths.last ?? 0
        let wavelength = unit * 2.6 + width * 1.8
        let amplitude = unit * 0.75 + width * 0.55
        // Resample evenly so zigzag corners land exactly.
        let step = max(1, wavelength / (shape == .zigzag ? 4 : 10))
        var result: [CGPoint] = []
        var index = 1
        var distance: CGFloat = 0
        while distance <= total {
            while index < lengths.count - 1 && lengths[index] < distance { index += 1 }
            let a = samples[index - 1], b = samples[index]
            let segment = max(0.0001, lengths[index] - lengths[index - 1])
            let t = min(1, max(0, (distance - lengths[index - 1]) / segment))
            let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let tangent = CGVector(dx: (b.x - a.x) / segment, dy: (b.y - a.y) / segment)
            let fadeIn = min(1, max(0, (distance - clearStart) / wavelength))
            let fadeOut = min(1, max(0, (total - clearEnd - distance) / wavelength))
            let phase = distance / wavelength
            let wave: CGFloat = shape == .wavy ? sin(phase * 2 * .pi) : (abs((phase + 0.25).truncatingRemainder(dividingBy: 1) * 4 - 2) - 1)
            let offset = amplitude * min(fadeIn, fadeOut) * wave
            result.append(CGPoint(x: point.x - tangent.dy * offset, y: point.y + tangent.dx * offset))
            distance += step
        }
        if let last = samples.last { result.append(last) }
        return result
    }

    func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.addLines(between: points)
        if points.count == 1 { path.move(to: first) }
        return path
    }

    // MARK: Areas

    /// Zone outline in screen points: a rectangle or ellipse turned by `rotation` around its centre.
    func areaOutline(_ element: BoardElement, projection: BoardProjection) -> [CGPoint] {
        if element.kind == .polygon { return projection.points(element.allPoints) }
        let a = projection.meters(element.position), b = projection.meters(element.opposite)
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let halfW = abs(b.x - a.x) / 2, halfH = abs(b.y - a.y) / 2
        let angle = CGFloat(element.rotation * .pi / 180)
        let local: [CGPoint] = element.zoneShape == .ellipse
            ? (0..<64).map { CGPoint(x: halfW * cos(CGFloat($0) / 64 * 2 * .pi), y: halfH * sin(CGFloat($0) / 64 * 2 * .pi)) }
            : [CGPoint(x: -halfW, y: -halfH), CGPoint(x: halfW, y: -halfH), CGPoint(x: halfW, y: halfH), CGPoint(x: -halfW, y: halfH)]
        return local.map { p in
            CGPoint(x: center.x + p.x * cos(angle) - p.y * sin(angle), y: center.y + p.x * sin(angle) + p.y * cos(angle)).applying(projection.metersTransform)
        }
    }

    /// Screen positions of a zone's stored corners (`position`, `opposite`) after rotation.
    private func zoneCorners(_ element: BoardElement, projection: BoardProjection) -> [CGPoint] {
        let outline = areaOutline(BoardElement(kind: .zone, position: element.position, points: element.points, rotation: element.rotation), projection: projection)
        let a = element.position, b = element.opposite
        // Rectangle corner order is (-,-), (+,-), (+,+), (-,+) in local space.
        let startIndex = (a.x <= b.x ? 0 : 1) + (a.y <= b.y ? 0 : 1) * 2
        let map = [0, 1, 3, 2]
        let first = outline[map[startIndex]], second = outline[map[3 - startIndex]]
        return [first, second]
    }

    private func drawArea(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let outline = areaOutline(element, projection: projection)
        guard outline.count >= 3 else { return }
        let unit = projection.unit
        let color = self.color(element.colorHex)
        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        cg.addPath(path)
        cg.setFillColor(color.withAlphaComponent(CGFloat(min(1, max(0, element.opacity)))).cgColor)
        cg.fillPath()
        guard let pattern = element.resolvedBorderPattern else { return }
        let width = max(1, unit * 0.42)
        cg.saveGState()
        switch pattern {
        case .solid: break
        case .dashed: cg.setLineDash(phase: 0, lengths: [unit * 1.8, unit * 1.2])
        case .dotted: cg.setLineDash(phase: 0, lengths: [0.001, unit * 1.1])
        }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.addPath(path)
        cg.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
        cg.setLineWidth(pattern == .dotted ? width * 1.5 : width)
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: Selection

    private var lime: UIColor { BoardPalette.uiColor(BoardPalette.lime) }

    private func drawHighlight(_ element: BoardElement, projection: BoardProjection, in cg: CGContext) {
        let center = projection.point(element.position)
        let radius = pointRadius(element, projection: projection) + projection.unit * 1.4
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 8 * chromeScale, color: lime.withAlphaComponent(0.9).cgColor)
        cg.setStrokeColor(lime.cgColor)
        cg.setLineWidth(2.5 * chromeScale)
        cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        cg.setFillColor(lime.withAlphaComponent(0.16).cgColor)
        cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        cg.restoreGState()
    }

    private func drawSelection(_ element: BoardElement, all: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        let unit = projection.unit
        let chrome = chromeScale
        cg.saveGState()
        cg.setStrokeColor(lime.cgColor)
        cg.setLineWidth(1.6 * chrome)
        cg.setShadow(offset: .zero, blur: 4 * chrome, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        if element.kind.isPoint {
            let center = projection.point(element.position)
            if isOblong(element.kind) {
                cg.addPath(pointOutline(element, projection: projection, padding: unit * 0.9))
            } else {
                let radius = pointRadius(element, projection: projection) + unit * 1.1
                cg.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            cg.strokePath()
        } else if element.isLineLike {
            // A glow along the line itself. Outlining the stroked shape of a sampled curve folds
            // over on its inner side and shows spikes at every joint; a wide round stroke cannot.
            let samples = lineSamples(element, all: all, projection: projection)
            let path = smoothPath(samples)
            let width = strokeWidth(element.resolvedLineStyle, projection: projection)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setLineCap(.round); cg.setLineJoin(.round)
            cg.addPath(path)
            cg.setStrokeColor(lime.withAlphaComponent(0.32).cgColor)
            cg.setLineWidth(width + 12 * chrome)
            cg.strokePath()
        } else {
            let outline = areaOutline(element, projection: projection)
            cg.setLineDash(phase: 0, lengths: [5 * chrome, 4 * chrome])
            cg.addLines(between: outline)
            cg.closePath()
            cg.strokePath()
        }
        cg.restoreGState()
        guard showsHandles else { return }

        let handles = self.handles(for: element, all: all, projection: projection)
        if let rotate = handles.first(where: { $0.0 == .rotate })?.1 {
            let anchor = rotationStemBase(element, all: all, projection: projection)
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(1.5 * chrome)
            cg.move(to: anchor); cg.addLine(to: rotate); cg.strokePath()
        }
        if let control = element.curveControl {
            // Faint guide from both ends to the control point while editing a curve.
            cg.saveGState()
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            cg.setLineWidth(1 * chrome)
            cg.setLineDash(phase: 0, lengths: [3 * chrome, 3 * chrome])
            let v = projection.points(element.lineVertices)
            cg.addLines(between: [v[0], projection.point(control), v[1]])
            cg.strokePath()
            cg.restoreGState()
        }
        for (handle, point) in handles {
            drawKnob(handle, at: point, in: cg)
        }
    }

    func drawKnob(_ handle: BoardHandle, at point: CGPoint, in cg: CGContext) {
        let chrome = chromeScale
        let radius: CGFloat = switch handle {
        case .insert: 5.5 * chrome
        case .bend: 6.5 * chrome
        case .rotate, .resize: 9 * chrome
        case .vertex: 7.5 * chrome
        }
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 1 * chrome), blur: 3 * chrome, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        switch handle {
        case .insert:
            cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            cg.fillEllipse(in: rect)
            cg.setStrokeColor(UIColor.white.cgColor)
        case .bend:
            cg.setFillColor(lime.cgColor)
            cg.fillEllipse(in: rect)
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        default:
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: rect)
            cg.setStrokeColor(lime.cgColor)
        }
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        cg.setLineWidth(1.6 * chrome)
        cg.strokeEllipse(in: rect.insetBy(dx: 0.8 * chrome, dy: 0.8 * chrome))
        cg.restoreGState()
        // Glyphs.
        cg.saveGState()
        cg.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
        cg.setLineWidth(1.4 * chrome)
        cg.setLineCap(.round)
        let g = radius * 0.5
        switch handle {
        case .rotate:
            cg.addArc(center: point, radius: g, startAngle: -.pi * 0.95, endAngle: .pi * 0.35, clockwise: false)
            cg.strokePath()
            let end = CGPoint(x: point.x + g * cos(.pi * 0.35), y: point.y + g * sin(.pi * 0.35))
            cg.move(to: CGPoint(x: end.x + g * 0.55, y: end.y - g * 0.1)); cg.addLine(to: end); cg.addLine(to: CGPoint(x: end.x - g * 0.05, y: end.y - g * 0.6))
            cg.strokePath()
        case .resize:
            cg.move(to: CGPoint(x: point.x - g, y: point.y - g)); cg.addLine(to: CGPoint(x: point.x + g, y: point.y + g))
            cg.move(to: CGPoint(x: point.x + g * 0.1, y: point.y + g)); cg.addLine(to: CGPoint(x: point.x + g, y: point.y + g)); cg.addLine(to: CGPoint(x: point.x + g, y: point.y + g * 0.1))
            cg.move(to: CGPoint(x: point.x - g * 0.1, y: point.y - g)); cg.addLine(to: CGPoint(x: point.x - g, y: point.y - g)); cg.addLine(to: CGPoint(x: point.x - g, y: point.y - g * 0.1))
            cg.strokePath()
        case .insert:
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.move(to: CGPoint(x: point.x - g, y: point.y)); cg.addLine(to: CGPoint(x: point.x + g, y: point.y))
            cg.move(to: CGPoint(x: point.x, y: point.y - g)); cg.addLine(to: CGPoint(x: point.x, y: point.y + g))
            cg.strokePath()
        default:
            break
        }
        cg.restoreGState()
    }

    // MARK: Geometry shared with hit testing

    /// Local outline of a rotated text pill or mini goal, in screen points.
    private func pointOutline(_ element: BoardElement, projection: BoardProjection, padding: CGFloat = 0) -> CGPath {
        let center = projection.point(element.position)
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: projection.screenAngle(element.rotation))
        let rect: CGRect
        if element.kind == .text {
            rect = textPill(element, projection: projection).insetBy(dx: -padding, dy: -padding)
            return CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: &transform)
        }
        let half = pointRadius(element, projection: projection)
        let depth = oblongHalfDepth(element, projection: projection)
        rect = CGRect(x: -half, y: -depth, width: half * 2, height: depth * 2).insetBy(dx: -padding, dy: -padding)
        return CGPath(rect: rect, transform: &transform)
    }

    /// Screen path of an element (for lines, the untrimmed centre line).
    func screenPath(_ element: BoardElement, projection: BoardProjection) -> CGPath {
        if element.isLineLike { return smoothPath(lineSamples(element, all: [], projection: projection)) }
        if element.kind.isArea {
            let path = CGMutablePath()
            path.addLines(between: areaOutline(element, projection: projection))
            path.closeSubpath()
            return path
        }
        if isOblong(element.kind) { return pointOutline(element, projection: projection) }
        let center = projection.point(element.position), radius = pointRadius(element, projection: projection)
        return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    /// Distance of the rotation knob from the element edge, in points.
    private var stemLength: CGFloat { 26 * chromeScale }

    private func rotationStemBase(_ element: BoardElement, all: [BoardElement], projection: BoardProjection) -> CGPoint {
        let (center, radius, _) = transformFrame(element, projection: projection)
        let angle = handleAngles(element, all: all, projection: projection).rotate
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    /// Directions for the rotate and resize knobs of a point element: the preferred angles when free,
    /// otherwise the nearest direction clear of lines (such as connected passes) and other elements.
    /// `all` is the resolved layout; deriving it costs a whole document pass, so callers pass the one
    /// they already have (a draw or a hit test resolves it once).
    private func handleAngles(_ element: BoardElement, all: [BoardElement], projection: BoardProjection) -> (rotate: CGFloat, resize: CGFloat) {
        let (center, radius, preferred) = transformFrame(element, projection: projection)
        let preferredResize: CGFloat = .pi / 4
        guard element.kind.isPoint, !isOblong(element.kind) else { return (preferred, preferredResize) }
        var obstacles: [(CGPoint, CGFloat)] = []
        for other in all where other.id != element.id {
            if other.isLineLike {
                let half = strokeWidth(other.resolvedLineStyle, projection: projection) / 2 + 3 * chromeScale
                let samples = lineSamples(other, all: all, projection: projection)
                let stride = max(1, samples.count / 160)
                for index in Swift.stride(from: 0, to: samples.count, by: stride) { obstacles.append((samples[index], half)) }
            } else if other.kind.isPoint {
                obstacles.append((projection.point(other.position), pointRadius(other, projection: projection)))
            }
        }
        let bounds = CGRect(origin: .zero, size: projection.size).insetBy(dx: 12 * chromeScale, dy: 12 * chromeScale)
        func clearance(_ angle: CGFloat, distance: CGFloat) -> CGFloat {
            var worst = CGFloat.greatestFiniteMagnitude
            for fraction in [0.55, 1.0] as [CGFloat] {
                let d = radius + (distance - radius) * fraction
                let point = CGPoint(x: center.x + cos(angle) * d, y: center.y + sin(angle) * d)
                if !bounds.contains(point) { return -1 }
                for (obstacle, size) in obstacles { worst = min(worst, hypot(point.x - obstacle.x, point.y - obstacle.y) - size) }
            }
            return worst
        }
        func pick(from base: CGFloat, distance: CGFloat, avoiding: CGFloat?) -> CGFloat {
            let needed = 24 * chromeScale
            var best = base, bestScore = -CGFloat.greatestFiniteMagnitude
            for step in [0, 1, -1, 2, -2, 3, -3, 4] {
                let angle = base + CGFloat(step) * .pi / 4
                if let avoiding, abs(remainder(Double(angle - avoiding), 2 * .pi)) < .pi / 3 { continue }
                let score = clearance(angle, distance: distance)
                if score >= needed { return angle }
                if score > bestScore { best = angle; bestScore = score }
            }
            return best
        }
        let rotate = pick(from: preferred, distance: radius + stemLength, avoiding: nil)
        let resize = pick(from: preferredResize, distance: resizeDistance(element, projection: projection), avoiding: rotate)
        return (rotate, resize)
    }

    private func resizeDistance(_ element: BoardElement, projection: BoardProjection) -> CGFloat {
        let base = element.kind == .text ? textPill(element, projection: projection).width / 2 + projection.unit : pointRadius(element, projection: projection) + projection.unit * 1.1
        return max(base, 22 * chromeScale) + 8 * chromeScale
    }

    /// Centre, edge radius and rotation-knob direction for transform handles.
    private func transformFrame(_ element: BoardElement, projection: BoardProjection) -> (CGPoint, CGFloat, CGFloat) {
        if element.kind.isArea {
            let outline = areaOutline(element, projection: projection)
            let box = CGRect(x: outline.map(\.x).min() ?? 0, y: outline.map(\.y).min() ?? 0, width: 0, height: 0)
                .union(CGRect(x: outline.map(\.x).max() ?? 0, y: outline.map(\.y).max() ?? 0, width: 0, height: 0))
            return (CGPoint(x: box.midX, y: box.midY), box.height / 2, -.pi / 2)
        }
        let center = projection.point(element.position)
        let angle = element.kind.isPerson ? projection.screenAngle(element.rotation) : projection.screenAngle(element.rotation) - .pi / 2
        let radius: CGFloat
        if element.kind == .text { radius = textPill(element, projection: projection).height / 2 + projection.unit * 0.9 }
        else if isOblong(element.kind) { radius = oblongHalfDepth(element, projection: projection) + projection.unit * 0.9 }
        else { radius = pointRadius(element, projection: projection) + projection.unit * 1.1 + (element.kind.isPerson ? projection.unit * 1.4 : 0) }
        return (center, radius, angle)
    }

    /// Centre used by rotate and resize handle drags.
    func transformCenter(_ element: BoardElement, projection: BoardProjection) -> CGPoint {
        element.kind.isPoint ? projection.point(element.position) : projection.point(element.pivot)
    }

    /// Handle positions for the selected element. `all` is the resolved layout when the caller already
    /// has one; without it the layout is derived here.
    func handles(for element: BoardElement, all: [BoardElement]? = nil, projection: BoardProjection) -> [(BoardHandle, CGPoint)] {
        baseHandles(for: element, all: all ?? visibleElements, projection: projection)
    }

    private func baseHandles(for element: BoardElement, all: [BoardElement], projection: BoardProjection) -> [(BoardHandle, CGPoint)] {
        var result: [(BoardHandle, CGPoint)] = []
        if element.isLineLike {
            let vertices = projection.points(element.lineVertices)
            if element.kind != .polyline && vertices.count == 2 {
                let mid: CGPoint
                if let control = element.curveControl.map(projection.point) {
                    mid = CGPoint(x: 0.25 * vertices[0].x + 0.5 * control.x + 0.25 * vertices[1].x, y: 0.25 * vertices[0].y + 0.5 * control.y + 0.25 * vertices[1].y)
                } else {
                    mid = CGPoint(x: (vertices[0].x + vertices[1].x) / 2, y: (vertices[0].y + vertices[1].y) / 2)
                }
                result.append((.bend, mid))
            } else {
                for (index, pair) in zip(vertices, vertices.dropFirst()).enumerated() {
                    result.append((.insert(index), CGPoint(x: (pair.0.x + pair.1.x) / 2, y: (pair.0.y + pair.1.y) / 2)))
                }
            }
            result += vertices.enumerated().map { (.vertex($0.offset), $0.element) }
            return result
        }
        let (center, radius, _) = transformFrame(element, projection: projection)
        let angles = handleAngles(element, all: all, projection: projection)
        let angle = angles.rotate
        if element.kind == .zone {
            result += zoneCorners(element, projection: projection).enumerated().map { (.vertex($0.offset), $0.element) }
        } else if element.kind == .polygon {
            result += projection.points(element.allPoints).enumerated().map { (.vertex($0.offset), $0.element) }
        }
        let knob = radius + stemLength
        result.append((.rotate, CGPoint(x: center.x + cos(angle) * knob, y: center.y + sin(angle) * knob)))
        if element.kind.isArea {
            let outline = areaOutline(element, projection: projection)
            let maxX = outline.map(\.x).max() ?? center.x, maxY = outline.map(\.y).max() ?? center.y
            result.append((.resize, CGPoint(x: maxX + 12 * chromeScale, y: maxY + 12 * chromeScale)))
            return result
        }
        let diagonal = resizeDistance(element, projection: projection)
        result.append((.resize, CGPoint(x: center.x + cos(angles.resize) * diagonal, y: center.y + sin(angles.resize) * diagonal)))
        return result
    }

    /// Topmost element under a screen point. Respects rotation and size.
    func hitTest(_ point: CGPoint, size: CGSize) -> UUID? {
        let projection = projection(size: size)
        let slop = 22 * chromeScale
        for element in visibleElements.reversed() {
            if isOblong(element.kind) {
                if pointOutline(element, projection: projection, padding: max(4 * chromeScale, projection.unit)).contains(point) { return element.id }
            } else if element.kind.isPoint {
                let center = projection.point(element.position)
                if hypot(point.x - center.x, point.y - center.y) <= max(pointRadius(element, projection: projection) + projection.unit, slop) { return element.id }
            } else {
                let path = screenPath(element, projection: projection)
                if element.kind.isArea && path.contains(point) { return element.id }
                if path.copy(strokingWithWidth: slop * 1.6, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point) { return element.id }
            }
        }
        return nil
    }

    /// Handle of `element` under a screen point: 44 pt targets, nearest wins, vertices before others.
    func handle(at point: CGPoint, of element: BoardElement, size: CGSize) -> BoardHandle? {
        let projection = projection(size: size)
        // One layout pass for the whole hit test: this runs on every touch-move.
        let all = visibleElements
        let resolved = all.first { $0.id == element.id } ?? element
        let slop = 22 * chromeScale
        // Touches on a point element's body move it: its rotate/resize knobs never steal them, even for tiny
        // elements like the ball whose knobs sit within a finger's width of the centre.
        let onBody: Bool = {
            guard resolved.kind.isPoint else { return false }
            let center = projection.point(resolved.position)
            return hypot(point.x - center.x, point.y - center.y) <= max(pointRadius(resolved, projection: projection), 14 * chromeScale)
        }()
        let candidates = handles(for: resolved, all: all, projection: projection)
            .filter { !(onBody && ($0.0 == .rotate || $0.0 == .resize)) }
            .map { ($0.0, hypot($0.1.x - point.x, $0.1.y - point.y)) }
            .filter { $0.1 <= slop }
        return candidates.min { lhs, rhs in
            let bias: (BoardHandle) -> CGFloat = { if case .insert = $0 { return 8 } else { return 0 } }
            return lhs.1 + bias(lhs.0) < rhs.1 + bias(rhs.0)
        }?.0
    }

    // MARK: Drawing helpers

    func regularPolygon(center: CGPoint, radius: CGFloat, sides: Int, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: (0..<sides).map { index in
            let a = rotation + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        })
        path.closeSubpath()
        return path
    }

    func gradientFill(radial colors: [UIColor], center: CGPoint, radius: CGFloat, in cg: CGContext) {
        BoardGradient.radial(colors, center: center, radius: radius, in: cg)
    }

    func gradientFill(linear colors: [UIColor], from: CGPoint, to: CGPoint, in cg: CGContext) {
        BoardGradient.linear(colors, from: from, to: to, in: cg)
    }

    /// Player discs, cached: a 22-player board redraws the same handful of discs every frame, and each
    /// one costs a blurred shadow, two gradients through a clip, a rim and a glyph run.
    static let discCache = DiscCache()

    final class DiscCache: @unchecked Sendable {
        private let lock = NSLock()
        private var discs: [String: CGImage] = [:]
        private var order: [String] = []
        private let limit = 48

        /// The disc image and the rect to blit it into, or nil when it cannot be rendered.
        func disc(for element: BoardElement, renderer: BoardRenderer, center: CGPoint, r: CGFloat, unit: CGFloat, in cg: CGContext) -> (image: CGImage, rect: CGRect)? {
            guard r > 0.5, unit > 0.2 else { return nil }
            let device = cg.userSpaceToDeviceSpaceTransform
            // Round the scale up in half steps: the sprite is then only ever downscaled, never blurred,
            // and pinch zoom rebuilds it a handful of times instead of on every frame.
            let scale = min(8, max(1, ceil(max(1, hypot(device.a, device.b)) * 2) / 2))
            let pad = unit * 3
            let pixels = max(1, Int(((r + pad) * 2 * scale).rounded()))
            let side = CGFloat(pixels) / scale
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let key = "\(element.kind.rawValue)-\(element.colorHex)-\(element.number ?? -1)-\(renderer.style.rawValue)-\(renderer.isGhost)-\(Int(r * 8))-\(Int(unit * 8))-\(pixels)"
            if let cached = lock.withLock({ discs[key] }) { return (cached, rect) }
            guard let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.translateBy(x: 0, y: CGFloat(pixels))
            bitmap.scaleBy(x: scale, y: -scale)
            bitmap.setLineCap(.round)
            bitmap.setLineJoin(.round)
            renderer.drawPersonDisc(element, base: renderer.color(element.colorHex), center: CGPoint(x: side / 2, y: side / 2), r: r, unit: unit, photo: nil, in: bitmap)
            guard let image = bitmap.makeImage() else { return nil }
            lock.withLock {
                discs[key] = image
                order.removeAll { $0 == key }
                order.append(key)
                while order.count > limit { discs[order.removeFirst()] = nil }
            }
            return (image, rect)
        }
    }

    /// Rounded fonts, cached: resolving the rounded design costs more than drawing the glyphs, and a
    /// heavy board asks for a few dozen fonts per frame at sizes that barely change between frames.
    private static let fontCache = FontCache()

    final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [String: UIFont] = [:]

        func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let quantized = max(1, (size * 4).rounded() / 4)
            let key = "\(quantized)-\(weight.rawValue)"
            if let cached = lock.withLock({ fonts[key] }) { return cached }
            let base = UIFont.systemFont(ofSize: quantized, weight: weight)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: quantized) } ?? base
            // Sizes track zoom, so the set stays small; drop it wholesale rather than tracking an order.
            lock.withLock {
                if fonts.count > 64 { fonts.removeAll(keepingCapacity: true) }
                fonts[key] = font
            }
            return font
        }
    }

    func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        Self.fontCache.font(size: size, weight: weight)
    }

    func contrasting(_ color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.68 ? UIColor(white: 0.08, alpha: 0.9) : .white
    }

    private func attributed(_ text: String, font: UIFont, color: UIColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func measure(_ text: String, font: UIFont) -> CGSize {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(attributed(text, font: font, color: .white), &ascent, &descent, nil)
        return CGSize(width: width, height: ascent + descent)
    }

    func drawText(_ text: String, at center: CGPoint, font: UIFont, color: UIColor, in cg: CGContext) {
        let line = attributed(text, font: font, color: color)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        cg.saveGState()
        cg.textMatrix = .identity
        cg.translateBy(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        cg.scaleBy(x: 1, y: -1)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
