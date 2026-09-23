import CoreGraphics
import UIKit

/// Animation aids drawn by the editor only: onion-skin ghosts of the neighbouring keyframes,
/// follow-path previews, and highlights of lines and shapes that can be followed.
extension BoardRenderer {
    private static let coolTint = UIColor(red: 0.45, green: 0.72, blue: 1, alpha: 1)
    private static let warmTint = UIColor(red: 1, green: 0.66, blue: 0.36, alpha: 1)

    // MARK: Onion skin

    func drawOnionSkin(live: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        guard let frame = onionFrame, document.isAnimated else { return }
        let skin = document.onionSkin(aroundFrame: frame)
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        // Two halves. The trails run from each ghost to where its element is now, so they change with
        // every drag tick. The ghost bodies and their rings come from the neighbouring keyframes and do
        // not move while a stage is edited, so they are rasterised once and blitted after that — which
        // is what makes onion skin affordable on a phone, where drawing forty ghosts costs ~20 ms.
        var sides: [(all: [BoardElement], drawn: [BoardElement], tint: UIColor, isPrevious: Bool)] = []
        for (ghosts, tint, isPrevious) in [(skin.previous, Self.coolTint, true), (skin.next, Self.warmTint, false)] {
            let sorted = ghosts.sorted { $0.kind.zOrder < $1.kind.zOrder }
            let drawn = sorted.filter { ghost in liveByID[ghost.id].map { Self.poseDiffers(ghost, $0) } ?? false }
            sides.append((sorted, drawn, tint, isPrevious))
        }
        guard sides.contains(where: { !$0.drawn.isEmpty }) else { return }

        for side in sides {
            for ghost in side.drawn {
                let transitionFrame = side.isPrevious ? frame - 1 : frame
                var trail: [CGPoint]
                if ghost.kind.isPoint, let segment = pathSegment(of: ghost.id, from: transitionFrame, to: transitionFrame + 1, projection: projection) {
                    trail = segment
                } else {
                    let current = liveByID[ghost.id] ?? ghost
                    trail = [projection.point(ghost.kind.isPoint ? ghost.position : ghost.pivot), projection.point(current.kind.isPoint ? current.position : current.pivot)]
                }
                guard trail.count >= 2 else { continue }
                cg.saveGState()
                cg.setStrokeColor(side.tint.withAlphaComponent(0.55).cgColor)
                cg.setLineWidth(max(1, projection.unit * 0.3))
                cg.setLineCap(.round)
                cg.setLineDash(phase: 0, lengths: [0.01, max(5, projection.unit * 1.5)])
                cg.addPath(smoothPath(trail))
                cg.strokePath()
                cg.restoreGState()
            }
        }

        // Only the ghosts' own bounds are rasterised, not the whole canvas: a full-screen blit at 3x
        // costs about as much as drawing the ghosts, and the ghosts usually sit in a corner of the pitch.
        let bounds = onionBounds(sides, projection: projection)
        let key = OnionLayerCache.Key(sides: sides.map { OnionLayerCache.Side(all: $0.all, drawn: $0.drawn, isPrevious: $0.isPrevious) },
                                      rect: bounds, inset: inset, reserved: reserved,
                                      field: document.fieldType, style: document.fieldStyle)
        let device = cg.userSpaceToDeviceSpaceTransform
        let scale = max(1, hypot(device.a, device.b))
        if cachesOnionLayer, !bounds.isEmpty, let layer = Self.onionCache.layer(for: key, scale: scale, draw: { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            self.drawOnionBodies(sides, projection: projection, in: context)
        }) {
            cg.saveGState()
            // CGContext.draw puts image row 0 at the bottom; flip so the image top sits at rect.minY.
            cg.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .low
            cg.draw(layer, in: bounds)
            cg.restoreGState()
            return
        }
        // Zoomed too far in for a screen-sized bitmap: draw the ghosts straight into the canvas.
        drawOnionBodies(sides, projection: projection, in: cg)
    }

    /// Screen rectangle the ghost bodies and rings cover, clipped to the canvas. Generously padded:
    /// it only has to contain the drawing, and a few points too many cost nothing.
    private func onionBounds(_ sides: [(all: [BoardElement], drawn: [BoardElement], tint: UIColor, isPrevious: Bool)],
                             projection: BoardProjection) -> CGRect {
        var box = CGRect.null
        for side in sides {
            for ghost in side.drawn {
                let padding = projection.unit * 2 + 4
                if ghost.kind.isPoint {
                    let center = projection.point(ghost.position)
                    let radius = pointRadius(ghost, projection: projection) + projection.unit * 0.7 + padding
                    box = box.union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                } else {
                    box = box.union(screenPath(ghost, projection: projection).boundingBox.insetBy(dx: -padding, dy: -padding))
                }
            }
        }
        guard !box.isNull else { return .zero }
        return box.intersection(CGRect(origin: .zero, size: projection.size)).integral
    }

    /// The static half of the onion skin: each ghost's translucent body and its dashed ring.
    private func drawOnionBodies(_ sides: [(all: [BoardElement], drawn: [BoardElement], tint: UIColor, isPrevious: Bool)],
                                 projection: BoardProjection, in cg: CGContext) {
        var ghostRenderer = self
        ghostRenderer.isGhost = true
        for side in sides {
            for ghost in side.drawn {
                cg.saveGState()
                cg.setAlpha(0.3)
                // No transparency layer: one costs milliseconds per ghost, and dropping the ghosts'
                // blurred shadows removes what the layer was there to hide (a shadow showing through
                // the translucent body). Everything else in a ghost draws over itself opaquely.
                ghostRenderer.draw(ghost, all: side.all, projection: projection, in: cg)
                cg.restoreGState()
                if ghost.kind.isPoint {
                    let center = projection.point(ghost.position)
                    let radius = pointRadius(ghost, projection: projection) + projection.unit * 0.7
                    cg.saveGState()
                    cg.setStrokeColor(side.tint.withAlphaComponent(0.85).cgColor)
                    cg.setLineWidth(max(1, projection.unit * 0.28))
                    cg.setLineDash(phase: 0, lengths: [max(3, projection.unit * 1.5), max(3, projection.unit * 1.1)])
                    cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    cg.restoreGState()
                }
            }
        }
    }

    static let onionCache = OnionLayerCache()

    /// One rasterised onion-skin layer. Editing a stage redraws the canvas on every touch move while the
    /// ghosts stay put, so the layer is rebuilt only when the ghosts themselves change.
    final class OnionLayerCache: @unchecked Sendable {
        struct Side: Equatable {
            var all: [BoardElement]
            var drawn: [BoardElement]
            var isPrevious: Bool
        }

        struct Key: Equatable {
            var sides: [Side]
            var rect: CGRect
            var inset: CGFloat
            var reserved: CGSize
            var field: BoardFieldType
            var style: BoardFieldStyle
            var scalePixels: Int = 0
        }

        private let lock = NSLock()
        private var key: Key?
        private var image: CGImage?
        private var observer: NSObjectProtocol?

        init() {
            // A screen-sized layer is worth a few megabytes; give it up rather than be the reason
            // something else is evicted. It costs one redraw to get back.
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                             object: nil, queue: nil) { [weak self] _ in
                self?.purge()
            }
        }

        func purge() {
            lock.withLock {
                key = nil
                image = nil
            }
        }

        /// The layer for `key`, drawing it when it is not the one already held. Nil when a screen-sized
        /// bitmap would be too large (zoomed far in), so the caller draws the ghosts directly instead.
        func layer(for requested: Key, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
            // Half-point steps, like the surface cache: an unzoomed canvas lands on the screen scale
            // exactly, so the blit is 1:1, and pinch zoom rebuilds only every ~17%.
            let quantised = max(1, floor(scale * 2) / 2)
            let pixels = CGSize(width: (requested.rect.width * quantised).rounded(), height: (requested.rect.height * quantised).rounded())
            guard pixels.width >= 1, pixels.height >= 1, pixels.width * pixels.height <= 6_000_000 else { return nil }
            var wanted = requested
            wanted.scalePixels = Int(quantised * 8)
            if let cached = lock.withLock({ key == wanted ? image : nil }) { return cached }
            guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Flip into the UIKit orientation the renderer draws in.
            context.translateBy(x: 0, y: pixels.height)
            context.scaleBy(x: quantised, y: -quantised)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            draw(context)
            guard let made = context.makeImage() else { return nil }
            lock.withLock {
                key = wanted
                image = made
            }
            return made
        }
    }

    static func poseDiffers(_ a: BoardElement, _ b: BoardElement) -> Bool {
        let close: (BoardPoint, BoardPoint) -> Bool = { abs($0.x - $1.x) < 1e-4 && abs($0.y - $1.y) < 1e-4 }
        if !close(a.position, b.position) || abs(normalizedDegrees(a.rotation - b.rotation)) > 0.5 || abs(a.size - b.size) > 1e-3 { return true }
        return a.points.count != b.points.count || zip(a.points, b.points).contains { !close($0, $1) }
    }

    // MARK: Follow paths

    /// Screen points along the stretch of path `id` travels between two keyframes on the same path.
    func pathSegment(of id: UUID, from start: Int, to end: Int, projection: BoardProjection) -> [CGPoint]? {
        guard document.keyframes.indices.contains(start), document.keyframes.indices.contains(end),
              let a = document.pathPose(of: id, atFrame: start), let b = document.pathPose(of: id, atFrame: end),
              let pathID = a.pathID, pathID == b.pathID, let p0 = a.pathProgress, let p1 = b.pathProgress else { return nil }
        let layout = document.layout(atFrame: start)
        let count = 40
        let points = (0...count).compactMap { BoardDocument.pathLocation(pathID: pathID, progress: p0 + (p1 - p0) * Double($0) / Double(count), in: layout, field: document.fieldType)?.point }
        return points.count >= 2 ? projection.points(points) : nil
    }

    /// Whole path with a dot per keyframe at that frame's progress; the edited frame's dot is highlighted.
    func drawFollowPreview(_ elements: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        guard let frame = animationFrame, let selectedID, elements.contains(where: { $0.id == selectedID }),
              let pose = document.pathPose(of: selectedID, atFrame: frame), let pathID = pose.pathID else { return }
        let samples = projection.points(document.pathSamples(pathID: pathID, frame: frame))
        guard samples.count >= 2 else { return }
        let chrome = chromeScale
        let tint = BoardPalette.uiColor(BoardPalette.lime)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 3 * chrome, color: UIColor.black.withAlphaComponent(0.6).cgColor)
        cg.setStrokeColor(tint.withAlphaComponent(0.8).cgColor)
        cg.setLineWidth(2.2 * chrome)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: [0.01, 6 * chrome])
        cg.addPath(smoothPath(samples))
        cg.strokePath()
        cg.restoreGState()
        // Travelled stretches between consecutive frames, a little brighter, with a chevron showing direction.
        let frames = document.pathFrames(of: selectedID, pathID: pathID)
        for (a, b) in zip(frames, frames.dropFirst()) where b == a + 1 {
            guard let segment = pathSegment(of: selectedID, from: a, to: b, projection: projection), segment.count >= 4 else { continue }
            cg.saveGState()
            cg.setStrokeColor(tint.withAlphaComponent(0.5).cgColor)
            cg.setLineWidth(4 * chrome)
            cg.setLineCap(.round)
            cg.addPath(smoothPath(segment))
            cg.strokePath()
            let mid = segment.count / 2
            let p = segment[mid], q = segment[min(segment.count - 1, mid + 1)]
            let angle = atan2(q.y - p.y, q.x - p.x)
            let size = 5 * chrome
            cg.translateBy(x: p.x, y: p.y)
            cg.rotate(by: angle)
            cg.setShadow(offset: .zero, blur: 2 * chrome, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.setStrokeColor(tint.cgColor)
            cg.setLineWidth(2.2 * chrome)
            cg.setLineJoin(.round)
            cg.move(to: CGPoint(x: -size * 0.6, y: -size)); cg.addLine(to: CGPoint(x: size * 0.5, y: 0)); cg.addLine(to: CGPoint(x: -size * 0.6, y: size))
            cg.strokePath()
            cg.restoreGState()
        }
        let layout = document.layout(atFrame: frame)
        for index in frames {
            guard let progress = document.pathPose(of: selectedID, atFrame: index)?.pathProgress,
                  let point = BoardDocument.pathLocation(pathID: pathID, progress: progress, in: layout, field: document.fieldType)?.point else { continue }
            let center = projection.point(point)
            let current = index == frame
            let radius = (current ? 5.5 : 4) * chrome
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: chrome), blur: 3 * chrome, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            cg.setFillColor((current ? tint : UIColor(white: 0.08, alpha: 0.9)).cgColor)
            cg.fillEllipse(in: rect)
            cg.restoreGState()
            cg.setStrokeColor((current ? UIColor(white: 0.08, alpha: 1) : tint).cgColor)
            cg.setLineWidth(1.6 * chrome)
            cg.strokeEllipse(in: rect.insetBy(dx: 1.4 * chrome, dy: 1.4 * chrome))
            if !current, projection.unit > 2 {
                let font = roundedFont(size: 8 * chrome, weight: .bold)
                drawText("\(index + 1)", at: CGPoint(x: center.x, y: center.y - radius - 6 * chrome), font: font, color: tint, in: cg)
            }
        }
    }

    func drawPathHighlights(_ elements: [BoardElement], projection: BoardProjection, in cg: CGContext) {
        guard !highlightedPathIDs.isEmpty else { return }
        let tint = BoardPalette.uiColor(BoardPalette.lime)
        for element in elements where highlightedPathIDs.contains(element.id) {
            let path: CGPath
            if element.isLineLike {
                path = smoothPath(lineSamples(element, all: elements, projection: projection))
            } else {
                let outline = CGMutablePath()
                outline.addLines(between: areaOutline(element, projection: projection))
                outline.closeSubpath()
                path = outline
            }
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 8 * chromeScale, color: tint.withAlphaComponent(0.9).cgColor)
            cg.setStrokeColor(tint.withAlphaComponent(0.75).cgColor)
            cg.setLineWidth(3 * chromeScale)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.strokePath()
            cg.restoreGState()
        }
    }
}
