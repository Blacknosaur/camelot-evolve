import SceneKit
import UIKit
import simd

// MARK: - Mesh building

/// Small triangle-mesh builder for the ground-hugging shapes of the 3D board (line ribbons,
/// arrowheads, zone fills). Points are (x, z) in world metres; y is up.
struct Board3DMesh {
    private(set) var positions: [SCNVector3] = []
    private(set) var normals: [SCNVector3] = []
    private(set) var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    private mutating func vertex(_ p: SIMD3<Double>, _ n: SIMD3<Double>) -> UInt32 {
        positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
        let unit = simd_normalize(n)
        normals.append(SCNVector3(Float(unit.x), Float(unit.y), Float(unit.z)))
        return UInt32(positions.count - 1)
    }

    /// Adds a triangle whose front face points along `outward` (up by default).
    private mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, outward: SIMD3<Double> = SIMD3(0, 1, 0)) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let ab = SIMD3<Double>(Double(pb.x - pa.x), Double(pb.y - pa.y), Double(pb.z - pa.z))
        let ac = SIMD3<Double>(Double(pc.x - pa.x), Double(pc.y - pa.y), Double(pc.z - pa.z))
        if simd_dot(simd_cross(ab, ac), outward) >= 0 { indices += [a, b, c] } else { indices += [a, c, b] }
    }

    /// A ribbon along `centre` (points at ground level) with a softly raised crown.
    mutating func addStrip(_ centre: [SIMD2<Double>], halfWidth: Double, y: Double, closed: Bool = false) {
        addStrip(centre.map { SIMD3($0.x, y, $0.y) }, halfWidth: halfWidth, closed: closed, aerial: false)
    }

    /// A ribbon through 3D points. Ground ribbons get a crowned top; aerial ones are built as a
    /// cross of two ribbons so the line reads as a solid tube from any camera angle.
    mutating func addStrip(_ centre: [SIMD3<Double>], halfWidth: Double, closed: Bool = false, aerial: Bool) {
        guard centre.count >= 2 else { return }
        let count = centre.count
        var frames: [(point: SIMD3<Double>, side: SIMD3<Double>, up: SIMD3<Double>)] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let previous = index > 0 ? centre[index - 1] : (closed ? centre[count - 1] : centre[index])
            let next = index + 1 < count ? centre[index + 1] : (closed ? centre[0] : centre[index])
            var tangent = next - previous
            if simd_length(tangent) < 1e-9 { tangent = SIMD3(1, 0, 0) }
            tangent = simd_normalize(tangent)
            var side = simd_cross(tangent, SIMD3(0, 1, 0))
            if simd_length(side) < 1e-6 { side = SIMD3(1, 0, 0) } else { side = simd_normalize(side) }
            frames.append((centre[index], side, simd_normalize(simd_cross(side, tangent))))
        }
        let segments = closed ? count : count - 1
        if aerial {
            // Horizontal ribbon plus a vertical one through the same centreline.
            for axis in 0..<2 {
                var rows: [(UInt32, UInt32)] = []
                for frame in frames {
                    let offset = (axis == 0 ? frame.side : frame.up) * halfWidth
                    let normal = axis == 0 ? frame.up : frame.side
                    rows.append((vertex(frame.point + offset, normal), vertex(frame.point - offset, -normal)))
                }
                for index in 0..<segments {
                    let a = rows[index], b = rows[(index + 1) % count]
                    let outward = frames[index].up
                    triangle(a.0, a.1, b.0, outward: outward); triangle(b.0, a.1, b.1, outward: outward)
                }
            }
            return
        }
        let crown = halfWidth * 0.45
        var rows: [(UInt32, UInt32, UInt32)] = []
        for frame in frames {
            let left = frame.point + frame.side * halfWidth, right = frame.point - frame.side * halfWidth
            let l = vertex(left, SIMD3(frame.side.x * 0.7, 1, frame.side.z * 0.7))
            let m = vertex(frame.point + SIMD3(0, crown, 0), SIMD3(0, 1, 0))
            let r = vertex(right, SIMD3(-frame.side.x * 0.7, 1, -frame.side.z * 0.7))
            rows.append((l, m, r))
        }
        for index in 0..<segments {
            let a = rows[index], b = rows[(index + 1) % count]
            triangle(a.0, a.1, b.0); triangle(b.0, a.1, b.1)
            triangle(a.1, a.2, b.1); triangle(b.1, a.2, b.2)
        }
    }

    /// An arrowhead in 3D: flat in the plane across the flight direction, so it reads along an arc.
    mutating func addArrowHead(tip: SIMD3<Double>, direction: SIMD3<Double>, length: Double, halfWidth: Double) {
        let d = simd_normalize(direction)
        var side = simd_cross(d, SIMD3(0, 1, 0))
        side = simd_length(side) < 1e-6 ? SIMD3(1, 0, 0) : simd_normalize(side)
        let up = simd_normalize(simd_cross(side, d))
        let base = tip - d * length
        let notch = tip - d * length * 0.72
        let height = min(length * 0.22, halfWidth * 0.6)
        let ridge = tip - d * length * 0.55
        let points: [SIMD3<Double>] = [tip, base + side * halfWidth, notch, base - side * halfWidth]
        let apex = ridge + up * height
        // Four sloped facets from the outline up to the apex, flat-shaded.
        for index in 0..<4 {
            let a = points[index], b = points[(index + 1) % 4]
            let normal = simd_normalize(simd_cross(b - a, apex - a))
            let n = simd_dot(normal, up) < 0 ? -normal : normal
            let ia = vertex(a, n), ib = vertex(b, n), ic = vertex(apex, n)
            triangle(ia, ib, ic, outward: n)
        }
    }

    /// A short raised bar across the line end (block / stop).
    mutating func addBar(center: SIMD2<Double>, direction: SIMD2<Double>, halfLength: Double, halfWidth: Double, y: Double) {
        let d = simd_normalize(direction), side = SIMD2(-d.y, d.x)
        addStrip([center - side * halfLength, center + side * halfLength], halfWidth: halfWidth, y: y)
    }

    /// A small domed disc.
    mutating func addDisc(center: SIMD2<Double>, radius: Double, y: Double, segments: Int = 14) {
        let apex = vertex(SIMD3(center.x, y + radius * 0.35, center.y), SIMD3(0, 1, 0))
        var ring: [UInt32] = []
        for index in 0..<segments {
            let angle = Double(index) / Double(segments) * 2 * .pi
            let dir = SIMD2(cos(angle), sin(angle))
            ring.append(vertex(SIMD3(center.x + dir.x * radius, y, center.y + dir.y * radius), SIMD3(dir.x * 0.6, 1, dir.y * 0.6)))
        }
        for index in 0..<segments { triangle(apex, ring[index], ring[(index + 1) % segments]) }
    }

    /// Flat fill of a simple polygon (convex or concave) via ear clipping.
    mutating func addFill(_ polygon: [SIMD2<Double>], y: Double) {
        var points = polygon
        if points.count > 3, let first = points.first, let last = points.last, simd_distance(first, last) < 1e-9 { points.removeLast() }
        guard points.count >= 3 else { return }
        let ids = points.map { vertex(SIMD3($0.x, y, $0.y), SIMD3(0, 1, 0)) }
        for (a, b, c) in Board3DMesh.triangulate(points) { triangle(ids[a], ids[b], ids[c]) }
    }

    static func triangulate(_ points: [SIMD2<Double>]) -> [(Int, Int, Int)] {
        let n = points.count
        guard n >= 3 else { return [] }
        var area = 0.0
        for i in 0..<n { let a = points[i], b = points[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
        var remaining = Array(0..<n)
        if area < 0 { remaining.reverse() }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var result: [(Int, Int, Int)] = []
        var guardCount = 0
        while remaining.count > 3 && guardCount < n * n {
            guardCount += 1
            var clipped = false
            for i in 0..<remaining.count {
                let ia = remaining[(i + remaining.count - 1) % remaining.count], ib = remaining[i], ic = remaining[(i + 1) % remaining.count]
                let a = points[ia], b = points[ib], c = points[ic]
                guard cross(a, b, c) > 1e-12 else { continue }
                let containsOther = remaining.contains { index in
                    guard index != ia, index != ib, index != ic else { return false }
                    let p = points[index]
                    return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
                }
                if containsOther { continue }
                result.append((ia, ib, ic))
                remaining.remove(at: i)
                clipped = true
                break
            }
            // Degenerate or self-intersecting outline: fall back to a fan so something still shows.
            if !clipped { break }
        }
        if remaining.count > 3 {
            for i in 1..<(remaining.count - 1) { result.append((remaining[0], remaining[i], remaining[i + 1])) }
        } else if remaining.count == 3 {
            result.append((remaining[0], remaining[1], remaining[2]))
        }
        return result
    }

    func geometry() -> SCNGeometry {
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)], elements: [element])
    }
}

// MARK: - Line sampling

enum Board3DPath {
    static func quadratic(_ a: SIMD2<Double>, _ control: SIMD2<Double>, _ b: SIMD2<Double>, step: Double) -> [SIMD2<Double>] {
        let length = simd_distance(a, control) + simd_distance(control, b)
        let count = max(12, min(160, Int(length / max(0.01, step))))
        return (0...count).map { index in
            let t = Double(index) / Double(count), u = 1 - t
            return a * (u * u) + control * (2 * u * t) + b * (t * t)
        }
    }

    /// Lifts a ground path onto an arc: each point takes the height of its arc-length fraction.
    static func lifted(_ points: [SIMD2<Double>], height: (Double) -> Double) -> [SIMD3<Double>] {
        let total = zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        var travelled = 0.0
        return points.enumerated().map { index, point in
            if index > 0 { travelled += simd_distance(points[index - 1], point) }
            return SIMD3(point.x, height(total > 0 ? travelled / total : 0), point.y)
        }
    }

    /// Resamples so no segment is longer than `step` (needed before waving a line).
    static func densified(_ points: [SIMD2<Double>], step: Double) -> [SIMD2<Double>] {
        guard let first = points.first else { return [] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let count = max(1, Int(ceil(simd_distance(a, b) / max(0.01, step))))
            for index in 1...count { result.append(a + (b - a) * (Double(index) / Double(count))) }
        }
        return result
    }

    /// Removes `start` metres from the beginning and `end` metres from the end.
    static func trimmed(_ points: [SIMD2<Double>], start: Double, end: Double) -> [SIMD2<Double>] {
        let total = length(points)
        guard total > start + end + 1e-6 else { return [] }
        return slice(points, from: start, to: total - end)
    }

    // MARK: Arc length (shared by the 2D ground paths and their lifted 3D versions)

    static func distance<V: SIMD>(_ a: V, _ b: V) -> Double where V.Scalar == Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    static func length<V: SIMD>(_ points: [V]) -> Double where V.Scalar == Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Portion of a polyline between two arc lengths.
    static func slice<V: SIMD>(_ points: [V], from: Double, to: Double) -> [V] where V.Scalar == Double {
        var result: [V] = []
        var travelled = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            let segmentEnd = travelled + segment
            if segmentEnd >= from && travelled <= to && segment > 0 {
                let t0 = max(0, (from - travelled) / segment), t1 = min(1, (to - travelled) / segment)
                let p0 = a + (b - a) * t0, p1 = a + (b - a) * t1
                if result.isEmpty { result.append(p0) } else if distance(result[result.count - 1], p0) > 1e-9 { result.append(p0) }
                result.append(p1)
            }
            travelled = segmentEnd
            if travelled > to { break }
        }
        return result
    }

    /// Offsets a densified path sideways with a sine (wavy) or triangle (zigzag) wave that
    /// eases in and out, so the ends stay on the true endpoints.
    static func waved(_ points: [SIMD2<Double>], amplitude: Double, wavelength: Double, zigzag: Bool) -> [SIMD2<Double>] {
        let total = length(points)
        guard points.count >= 2, total > 0 else { return points }
        var travelled = 0.0
        return points.enumerated().map { index, point in
            if index > 0 { travelled += simd_distance(points[index - 1], point) }
            let previous = points[max(0, index - 1)], next = points[min(points.count - 1, index + 1)]
            var tangent = next - previous
            if simd_length(tangent) < 1e-9 { tangent = SIMD2(1, 0) }
            tangent = simd_normalize(tangent)
            let fade = min(1, travelled / (wavelength * 0.6), (total - travelled) / (wavelength * 0.6))
            let phase = travelled / wavelength
            let wave = zigzag ? (4 * abs(phase - floor(phase + 0.5)) - 1) : sin(phase * 2 * .pi)
            return point + SIMD2(-tangent.y, tangent.x) * (amplitude * max(0, fade) * wave)
        }
    }
}

// MARK: - Textures

/// Generated textures shared by every 3D scene. Thread-safe; images are cached with a byte budget
/// (a badge with a photo is far bigger than a line pattern, so a count limit alone says little) and
/// dropped on a memory warning, as `VideoThumbnailService` does.
final class Board3DTextures: @unchecked Sendable {
    static let shared = Board3DTextures()

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let images = NSCache<NSString, Entry>()
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        images.countLimit = 400
        images.totalCostLimit = 24 * 1_024 * 1_024
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.images.removeAllObjects()
        }
    }

    private func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let entry = images.object(forKey: key as NSString) { return entry.image }
        guard let image = make() else { return nil }
        images.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Draws into an 8-bit RGBA bitmap with a y-down UIKit coordinate system. Always RGBA: a
    /// grayscale image would map to a Metal pixel format the simulator rejects.
    static func draw(_ size: CGSize, scale: CGFloat = 1, opaque: Bool = false, _ body: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(cg)
        body(cg)
        UIGraphicsPopContext()
        return cg.makeImage()
    }

    static func roundedFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    static func contrasting(_ hex: String) -> UIColor {
        let (r, g, b) = BoardPalette.rgb(hex)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.68 ? UIColor(white: 0.08, alpha: 1) : .white
    }

    /// Ground field texture: the shared 2D surface composited over the surround tone so the
    /// plane is opaque and blends into the surround plane at its edges.
    /// `featherMeters` of surround colour is added around the surface, and the outer part of the
    /// apron fades into it, so the ground has no hard edge against the surround plane.
    func ground(field: BoardFieldType, style: BoardFieldStyle, pixelsPerMeter: CGFloat, apronMeters: CGFloat, featherMeters: CGFloat, surround: UIColor) -> CGImage? {
        cached("ground-\(field.rawValue)-\(style.rawValue)-\(pixelsPerMeter)-\(apronMeters)-\(featherMeters)-\(surround.hashKey)") {
            guard let surface = BoardRenderer.surfaceImage(field: field, style: style, pixelsPerMeter: pixelsPerMeter, apronMeters: apronMeters) else { return nil }
            let margin = Int((featherMeters * pixelsPerMeter).rounded())
            let width = surface.width + 2 * margin, height = surface.height + 2 * margin
            guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            cg.setFillColor(surround.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            cg.interpolationQuality = .high
            cg.draw(surface, in: CGRect(x: margin, y: margin, width: surface.width, height: surface.height))
            // Feather: from opaque surround at the outer edge to clear halfway into the apron.
            let fade = CGFloat(margin) + apronMeters * pixelsPerMeter * 0.55
            let colors = [surround.cgColor, surround.withAlphaComponent(0.55).cgColor, surround.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { return cg.makeImage() }
            let w = CGFloat(width), h = CGFloat(height)
            let edges: [(CGRect, CGPoint, CGPoint)] = [
                (CGRect(x: 0, y: 0, width: fade, height: h), CGPoint(x: 0, y: 0), CGPoint(x: fade, y: 0)),
                (CGRect(x: w - fade, y: 0, width: fade, height: h), CGPoint(x: w, y: 0), CGPoint(x: w - fade, y: 0)),
                (CGRect(x: 0, y: 0, width: w, height: fade), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: fade)),
                (CGRect(x: 0, y: h - fade, width: w, height: fade), CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - fade)),
            ]
            for (rect, start, end) in edges {
                cg.saveGState()
                cg.clip(to: rect)
                cg.drawLinearGradient(gradient, start: start, end: end, options: [])
                cg.restoreGState()
            }
            return cg.makeImage()
        }
    }

    /// Soft light patch on the front of the chest (u around 0, upper body), added as emission so
    /// one mask serves every team colour and shows which way a figure faces.
    func chestMask(tint: String = BoardPalette.white) -> CGImage? {
        cached("chest-\(tint)") {
            Board3DTextures.draw(CGSize(width: 128, height: 128), opaque: true) { cg in
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                cg.setFillColor(BoardPalette.uiColor(tint).cgColor)
                // Body v runs 0…0.7 (bottom → shoulders); the patch sits just below the shoulders.
                for x in [-10.0, 118.0] {
                    cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: 58, width: 20, height: 22), cornerRadius: 8).cgPath)
                }
                cg.fillPath()
            }
        }
    }

    /// Average colour of the style's playing surface, used to tint the surround and ambience.
    func surfaceTone(field: BoardFieldType, style: BoardFieldStyle) -> UIColor {
        let key = "tone-\(field.rawValue)-\(style.rawValue)"
        if let entry = images.object(forKey: key as NSString) { return Board3DTextures.pixelColor(entry.image) }
        guard let surface = BoardRenderer.surfaceImage(field: field, style: style, pixelsPerMeter: 2, apronMeters: 0),
              let cg = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return UIColor(red: 0.2, green: 0.4, blue: 0.25, alpha: 1)
        }
        cg.interpolationQuality = .high
        cg.draw(surface, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if let image = cg.makeImage() {
            images.setObject(Entry(image), forKey: key as NSString, cost: 4)
            return Board3DTextures.pixelColor(image)
        }
        return UIColor(red: 0.2, green: 0.4, blue: 0.25, alpha: 1)
    }

    private static func pixelColor(_ image: CGImage) -> UIColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cg = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .darkGray }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = max(1, CGFloat(pixel[3]))
        return UIColor(red: CGFloat(pixel[0]) / alpha, green: CGFloat(pixel[1]) / alpha, blue: CGFloat(pixel[2]) / alpha, alpha: 1)
    }

    /// Radial fade from the surround tone to the backdrop colour for the large floor plane.
    func surround(inner: UIColor, outer: UIColor) -> CGImage? {
        cached("surround-\(inner.hashKey)-\(outer.hashKey)") {
            Board3DTextures.draw(CGSize(width: 256, height: 256), opaque: true) { cg in
                cg.setFillColor(outer.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                let colors = [inner.cgColor, inner.blended(with: outer, 0.55).cgColor, outer.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.12, 0.3, 0.5]) {
                    cg.drawRadialGradient(gradient, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 256, options: [.drawsAfterEndLocation])
                }
            }
        }
    }

    /// Spherical backdrop (2:1): dark zenith easing to a soft haze at the horizon, which matches the
    /// fog colour below it, so low free and point-of-view cameras see a sky instead of a black void.
    func sky(zenith: UIColor, horizon: UIColor, ground: UIColor) -> CGImage? {
        cached("sky-\(zenith.hashKey)-\(horizon.hashKey)-\(ground.hashKey)") {
            Board3DTextures.draw(CGSize(width: 64, height: 256), opaque: true) { cg in
                let colors = [zenith.cgColor, zenith.blended(with: horizon, 0.35).cgColor, horizon.cgColor, ground.cgColor, ground.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 0.495, 0.52, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
                }
            }
        }
    }

    /// Soft sky-like environment for physically based reflections.
    func environment(top: UIColor, horizon: UIColor, bottom: UIColor) -> CGImage? {
        cached("env-\(top.hashKey)-\(horizon.hashKey)-\(bottom.hashKey)") {
            Board3DTextures.draw(CGSize(width: 128, height: 64), opaque: true) { cg in
                let colors = [top.cgColor, horizon.cgColor, bottom.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 0.62]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 64), options: [.drawsAfterEndLocation])
                }
            }
        }
    }

    /// Contact shadow plus a thin team-coloured base ring with a small chevron at +x
    /// (the facing direction), like a tabletop piece.
    func baseRing(colorHex: String, dashed: Bool) -> CGImage? {
        cached("base-\(colorHex)-\(dashed)") {
            Board3DTextures.draw(CGSize(width: 256, height: 256)) { cg in
                let center = CGPoint(x: 128, y: 128)
                let shadow = [UIColor.black.withAlphaComponent(0.55).cgColor, UIColor.black.withAlphaComponent(0.22).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shadow, locations: [0, 0.35, 0.62]) {
                    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 128, options: [])
                }
                let color = BoardPalette.uiColor(colorHex)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(9)
                if dashed { cg.setLineDash(phase: 0, lengths: [22, 13]) }
                cg.strokeEllipse(in: CGRect(x: 30, y: 30, width: 196, height: 196))
                cg.setLineDash(phase: 0, lengths: [])
                cg.setFillColor(color.cgColor)
                cg.move(to: CGPoint(x: 250, y: 128))
                cg.addLine(to: CGPoint(x: 222, y: 108))
                cg.addLine(to: CGPoint(x: 222, y: 148))
                cg.closePath()
                cg.fillPath()
            }
        }
    }

    /// Soft lime halo for the selected element.
    func selectionRing() -> CGImage? {
        cached("selection") {
            Board3DTextures.draw(CGSize(width: 256, height: 256)) { cg in
                let lime = BoardPalette.uiColor(BoardPalette.lime)
                let rect = CGRect(x: 36, y: 36, width: 184, height: 184)
                for (width, alpha) in [(34.0, 0.08), (22.0, 0.16), (12.0, 0.35), (5.0, 1.0)] {
                    cg.setStrokeColor(lime.withAlphaComponent(alpha).cgColor)
                    cg.setLineWidth(width)
                    cg.strokeEllipse(in: rect)
                }
            }
        }
    }

    /// Floating number badge (and optional name) above a figure. Returns the image and its
    /// aspect ratio so the billboard plane matches.
    func badge(number: Int?, label: String, colorHex: String, kind: BoardElementKind) -> CGImage? {
        cached("badge-\(number.map(String.init) ?? "-")-\(label)-\(colorHex)-\(kind.rawValue)") {
            let scale: CGFloat = 3
            let numberFont = Board3DTextures.roundedFont(30, .bold)
            let nameFont = Board3DTextures.roundedFont(19, .semibold)
            let numberText = number.map(String.init) ?? ""
            let numberWidth = (numberText as NSString).size(withAttributes: [.font: numberFont]).width
            let nameWidth = label.isEmpty ? 0 : (label as NSString).size(withAttributes: [.font: nameFont]).width
            let pillHeight: CGFloat = number == nil ? 0 : 40
            let pillWidth = number == nil ? 0 : max(pillHeight, numberWidth + 22)
            let nameHeight: CGFloat = label.isEmpty ? 0 : 28
            let width = max(pillWidth, nameWidth + 20) + 8
            let height = pillHeight + nameHeight + (number != nil && !label.isEmpty ? 4 : 0) + 8
            return Board3DTextures.draw(CGSize(width: width, height: height), scale: scale) { cg in
                let color = BoardPalette.uiColor(colorHex)
                var y: CGFloat = 4
                if number != nil {
                    let pill = CGRect(x: (width - pillWidth) / 2, y: y, width: pillWidth, height: pillHeight)
                    let path = UIBezierPath(roundedRect: pill, cornerRadius: pillHeight / 2)
                    cg.saveGState()
                    cg.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                    let fill: UIColor = kind == .opponent ? UIColor(white: 0.09, alpha: 0.92) : color
                    cg.setFillColor(fill.cgColor)
                    cg.addPath(path.cgPath)
                    cg.fillPath()
                    cg.restoreGState()
                    let stroke: UIColor = kind == .opponent ? color : UIColor.white.withAlphaComponent(kind == .goalkeeper ? 1 : 0.9)
                    cg.setStrokeColor(stroke.cgColor)
                    cg.setLineWidth(kind == .player ? 2 : 3)
                    cg.addPath(UIBezierPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerRadius: pillHeight / 2 - 1.5).cgPath)
                    cg.strokePath()
                    let textColor = kind == .opponent ? color : Board3DTextures.contrasting(colorHex)
                    let size = (numberText as NSString).size(withAttributes: [.font: numberFont])
                    (numberText as NSString).draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: [.font: numberFont, .foregroundColor: textColor])
                    y += pillHeight + 4
                }
                if !label.isEmpty {
                    let capsule = CGRect(x: (width - nameWidth - 20) / 2, y: y, width: nameWidth + 20, height: nameHeight)
                    cg.setFillColor(UIColor(white: 0.06, alpha: 0.72).cgColor)
                    cg.addPath(UIBezierPath(roundedRect: capsule, cornerRadius: nameHeight / 2).cgPath)
                    cg.fillPath()
                    let size = (label as NSString).size(withAttributes: [.font: nameFont])
                    (label as NSString).draw(at: CGPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2), withAttributes: [.font: nameFont, .foregroundColor: UIColor.white])
                }
            }
        }
    }

    /// Photo badge for a squad player: the photo in a circle with a team-colour rim, a small number
    /// tab and an optional name. `version` identifies the photo so a new photo gets a new texture.
    func photoBadge(photo: CGImage, version: String, number: Int?, label: String, colorHex: String, kind: BoardElementKind) -> CGImage? {
        cached("photo-\(version)-\(number.map(String.init) ?? "-")-\(label)-\(colorHex)-\(kind.rawValue)") {
            let diameter: CGFloat = 64, rim: CGFloat = 4
            let nameFont = Board3DTextures.roundedFont(19, .semibold)
            let tabFont = Board3DTextures.roundedFont(22, .bold)
            let nameWidth = label.isEmpty ? 0 : (label as NSString).size(withAttributes: [.font: nameFont]).width
            let nameHeight: CGFloat = label.isEmpty ? 0 : 28
            let width = max(diameter + 24, nameWidth + 28)
            let height = diameter + 10 + (label.isEmpty ? 0 : nameHeight + 4)
            return Board3DTextures.draw(CGSize(width: width, height: height), scale: 3) { cg in
                let color = BoardPalette.uiColor(colorHex)
                let circle = CGRect(x: (width - diameter) / 2, y: 3, width: diameter, height: diameter)
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                cg.setFillColor(color.cgColor)
                cg.fillEllipse(in: circle)
                cg.restoreGState()
                // Photo, clipped to the circle inside the rim. CGContext draws images bottom-up, so flip locally.
                let inner = circle.insetBy(dx: rim, dy: rim)
                cg.saveGState()
                cg.addEllipse(in: inner)
                cg.clip()
                cg.translateBy(x: 0, y: inner.maxY + inner.minY)
                cg.scaleBy(x: 1, y: -1)
                cg.interpolationQuality = .high
                cg.draw(photo, in: inner)
                cg.restoreGState()
                if kind == .opponent {
                    cg.setStrokeColor(UIColor(white: 0.09, alpha: 0.9).cgColor)
                    cg.setLineWidth(1.5)
                    cg.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
                }
                if let number {
                    let text = "\(number)"
                    let size = (text as NSString).size(withAttributes: [.font: tabFont])
                    let tab = CGRect(x: circle.maxX - max(28, size.width + 12) + 8, y: circle.maxY - 24, width: max(28, size.width + 12), height: 28)
                    cg.setFillColor(color.cgColor)
                    cg.addPath(UIBezierPath(roundedRect: tab, cornerRadius: 14).cgPath)
                    cg.fillPath()
                    cg.setStrokeColor(UIColor.white.cgColor)
                    cg.setLineWidth(2)
                    cg.addPath(UIBezierPath(roundedRect: tab.insetBy(dx: 1, dy: 1), cornerRadius: 13).cgPath)
                    cg.strokePath()
                    (text as NSString).draw(at: CGPoint(x: tab.midX - size.width / 2, y: tab.midY - size.height / 2), withAttributes: [.font: tabFont, .foregroundColor: Board3DTextures.contrasting(colorHex)])
                }
                if !label.isEmpty {
                    let capsule = CGRect(x: (width - nameWidth - 20) / 2, y: circle.maxY + 7, width: nameWidth + 20, height: nameHeight)
                    cg.setFillColor(UIColor(white: 0.06, alpha: 0.72).cgColor)
                    cg.addPath(UIBezierPath(roundedRect: capsule, cornerRadius: nameHeight / 2).cgPath)
                    cg.fillPath()
                    let size = (label as NSString).size(withAttributes: [.font: nameFont])
                    (label as NSString).draw(at: CGPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2), withAttributes: [.font: nameFont, .foregroundColor: UIColor.white])
                }
            }
        }
    }

    /// Text element: a dark translucent pill with coloured text.
    func textLabel(_ text: String, colorHex: String) -> CGImage? {
        cached("text-\(text)-\(colorHex)") {
            let font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            let shown = text.isEmpty ? " " : text
            let measured = (shown as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: measured.width + 36, height: measured.height + 18)
            return Board3DTextures.draw(size, scale: 3) { cg in
                let pill = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                cg.setFillColor(UIColor(white: 0.05, alpha: 0.7).cgColor)
                cg.addPath(UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).cgPath)
                cg.fillPath()
                (shown as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2), withAttributes: [.font: font, .foregroundColor: BoardPalette.uiColor(colorHex)])
            }
        }
    }

    /// Equirectangular ball skin: white with dark pentagon patches, or a basketball.
    func ball(basketball: Bool) -> CGImage? {
        cached("ball-\(basketball)") {
            let width = 256, height = 128
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let phi = (1 + sqrt(5.0)) / 2
            let icosahedron: [SIMD3<Double>] = [
                SIMD3(-1, phi, 0), SIMD3(1, phi, 0), SIMD3(-1, -phi, 0), SIMD3(1, -phi, 0),
                SIMD3(0, -1, phi), SIMD3(0, 1, phi), SIMD3(0, -1, -phi), SIMD3(0, 1, -phi),
                SIMD3(phi, 0, -1), SIMD3(phi, 0, 1), SIMD3(-phi, 0, -1), SIMD3(-phi, 0, 1),
            ].map(simd_normalize)
            for row in 0..<height {
                let latitude = (0.5 - (Double(row) + 0.5) / Double(height)) * .pi
                for column in 0..<width {
                    let longitude = ((Double(column) + 0.5) / Double(width)) * 2 * .pi
                    let dir = SIMD3(cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude))
                    var rgb = (255.0, 255.0, 255.0)
                    if basketball {
                        rgb = (232, 118, 40)
                        let seams = [abs(dir.x), abs(dir.y), abs(dir.z) * 0.9 + abs(dir.x) * 0.1 - 0.0]
                        if seams.contains(where: { $0 < 0.03 }) { rgb = (35, 22, 16) }
                    } else {
                        let closest = icosahedron.map { simd_dot($0, dir) }.max() ?? 0
                        if closest > 0.93 { rgb = (28, 30, 34) } else if closest > 0.915 { rgb = (150, 150, 155) }
                    }
                    let offset = (row * width + column) * 4
                    pixels[offset] = UInt8(rgb.0); pixels[offset + 1] = UInt8(rgb.1); pixels[offset + 2] = UInt8(rgb.2)
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Transparent net mesh for mini goals.
    func net() -> CGImage? {
        cached("net") {
            Board3DTextures.draw(CGSize(width: 64, height: 64)) { cg in
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                cg.setLineWidth(3)
                for index in stride(from: 0, through: 64, by: 16) {
                    cg.move(to: CGPoint(x: CGFloat(index), y: 0)); cg.addLine(to: CGPoint(x: CGFloat(index), y: 64))
                    cg.move(to: CGPoint(x: 0, y: CGFloat(index))); cg.addLine(to: CGPoint(x: 64, y: CGFloat(index)))
                }
                cg.strokePath()
            }
        }
    }
}

extension UIColor {
    fileprivate var hashKey: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f", r, g, b)
    }

    func blended(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }

    func scaled(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: min(1, r * factor), green: min(1, g * factor), blue: min(1, b * factor), alpha: a)
    }
}

// MARK: - Figure geometry

enum Board3DShapes {
    /// Smooth stylised player: a softly tapered capsule body and a separate round head,
    /// lathed into one mesh so each figure is a single draw call. About 1.8 m tall; +x is front.
    static func figure() -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [UInt32] = []
        let segments = 28

        func lathe(_ profile: [(r: Double, y: Double)], v range: ClosedRange<Double>) {
            let start = UInt32(positions.count)
            for (index, point) in profile.enumerated() {
                let previous = profile[max(0, index - 1)], next = profile[min(profile.count - 1, index + 1)]
                let dr = next.r - previous.r, dy = next.y - previous.y
                let length = max(1e-9, hypot(dr, dy))
                let nr = dy / length, ny = -dr / length
                for segment in 0...segments {
                    let angle = Double(segment) / Double(segments) * 2 * .pi
                    positions.append(SCNVector3(Float(point.r * cos(angle)), Float(point.y), Float(point.r * sin(angle))))
                    normals.append(SCNVector3(Float(nr * cos(angle)), Float(ny), Float(nr * sin(angle))))
                    uvs.append(CGPoint(x: Double(segment) / Double(segments), y: range.lowerBound + (range.upperBound - range.lowerBound) * Double(index) / Double(profile.count - 1)))
                }
            }
            let columns = UInt32(segments + 1)
            for row in 0..<UInt32(profile.count - 1) {
                for column in 0..<UInt32(segments) {
                    let a = start + row * columns + column, b = a + 1, c = a + columns, d = c + 1
                    indices += [a, c, b, b, c, d]
                }
            }
        }

        // Body: rounded foot, slim waist, broad soft shoulders (Catmull-Rom through control points).
        let control: [(r: Double, y: Double)] = [
            (0, 0.02), (0.11, 0.024), (0.165, 0.06), (0.18, 0.18), (0.19, 0.42), (0.225, 0.7),
            (0.275, 0.94), (0.29, 1.04), (0.275, 1.12), (0.22, 1.18), (0.13, 1.212), (0, 1.222),
        ]
        var body: [(r: Double, y: Double)] = []
        for index in 0..<(control.count - 1) {
            let p0 = control[max(0, index - 1)], p1 = control[index], p2 = control[index + 1], p3 = control[min(control.count - 1, index + 2)]
            for step in 0..<6 {
                let t = Double(step) / 6, t2 = t * t, t3 = t2 * t
                func spline(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                body.append((r: max(0, spline(p0.r, p1.r, p2.r, p3.r)), y: spline(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        body.append(control[control.count - 1])
        lathe(body, v: 0...0.7)
        // Head.
        var head: [(r: Double, y: Double)] = []
        let headCenter = 1.44, headRadius = 0.2
        for index in 0...16 {
            let theta = -Double.pi / 2 + Double.pi * Double(index) / 16
            head.append((r: headRadius * cos(theta), y: headCenter + headRadius * sin(theta)))
        }
        lathe(head, v: 0.75...1)

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uvs)], elements: [element])
    }
}
