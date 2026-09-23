@preconcurrency import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// One oriented source frame serves every lens, including edits while paused.
struct AnalysisLoupePreview: NSViewRepresentable {
    let marks: [AnalysisAnnotation]
    let time: Double
    let player: AVPlayer?
    let still: CGImage?
    let frame: CGRect
    var bounds: CGRect? = nil
    var ground: GroundCalibration? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Surface {
        let view = Surface(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ view: Surface, context: Context) { context.coordinator.update(self, view: view) }
    static func dismantleNSView(_ view: Surface, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        private weak var view: Surface?
        private weak var item: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        private var displayTimer: Timer?
        private var orientationTask: Task<Void, Never>?
        private let imageContext = CIContext(options: [.cacheIntermediates: false])
        private var transform: CGAffineTransform?
        private var image: CGImage?
        private var imageTime = -Double.infinity
        private var content: AnalysisLoupePreview?
        func update(_ content: AnalysisLoupePreview, view: Surface) {
            self.view = view; self.content = content
            if item !== content.player?.currentItem {
                detach(); item = content.player?.currentItem
                if let item {
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output); self.output = output
                    output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)
                    orientationTask = Task { [weak self, weak item] in
                        guard let item, let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                              let transform = try? await track.load(.preferredTransform), !Task.isCancelled,
                              let self, self.item === item else { return }
                        self.transform = transform; self.sample()
                    }
                    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.sample() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    displayTimer = timer
                }
            }
            sample(); view.needsDisplay = true
        }
        private func sample() {
            guard let item, let output, let transform else { return }
            let time = item.currentTime()
            guard time.seconds.isFinite else { return }
            if image != nil, !output.hasNewPixelBuffer(forItemTime: time) { return }
            var displayed = CMTime.invalid
            guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) else { return }
            autoreleasepool {
                let raw = CIImage(cvPixelBuffer: buffer)
                let display = raw.extent.applying(transform).standardized
                let oriented = CGAffineTransform(translationX: 0, y: raw.extent.height).scaledBy(x: 1, y: -1)
                    .concatenating(transform)
                    .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
                    .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height))
                let scale = min(1, 1280 / max(display.width, display.height))
                let source = raw.transformed(by: oriented).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cg = imageContext.createCGImage(source, from: source.extent) else { return }
                image = cg
                imageTime = displayed.seconds.isFinite ? displayed.seconds : time.seconds
                view?.needsDisplay = true
            }
        }
        private func detach() {
            orientationTask?.cancel(); orientationTask = nil
            displayTimer?.invalidate(); displayTimer = nil
            if let output, let item { item.remove(output) }
            output = nil; item = nil; image = nil; imageTime = -.infinity; transform = nil
        }
        func stop() { detach(); content = nil; view = nil }
        func draw(in context: CGContext, size: CGSize) {
            guard let content else { return }
            let bounds = content.bounds ?? CGRect(origin: .zero, size: size)
            let source = content.still ?? (abs(content.time - imageTime) <= 0.10 ? image : nil)
            context.saveGState(); context.clip(to: bounds)
            for mark in content.marks {
                guard mark.tool == .loupe else {
                    AnnotationRenderer.draw([mark], time: content.time, in: context, frame: content.frame, ground: content.ground)
                    continue
                }
                guard let source, let geometry = AnnotationLoupeGeometry.make(mark: mark, time: content.time, frame: content.frame, bounds: bounds) else { continue }
                context.saveGState(); context.setAlpha(mark.opacity(at: content.time))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.saveGState(); context.addEllipse(in: geometry.lensRect); context.clip()
                context.setFillColor(NSColor.black.cgColor); context.fill(geometry.lensRect)
                context.translateBy(x: geometry.center.x, y: geometry.center.y)
                let zoom = geometry.radius / geometry.sourceRadius
                context.scaleBy(x: zoom, y: zoom)
                context.translateBy(x: -geometry.focus.x, y: -geometry.focus.y)
                context.draw(source, in: content.frame)
                context.restoreGState()
                AnnotationLoupeRenderer.drawBorder(geometry, in: context)
                context.endTransparencyLayer()
                context.restoreGState()
            }
            context.restoreGState()
        }
    }
    final class Surface: NSView {
        weak var coordinator: Coordinator?
        override var isFlipped: Bool { true }
        override func draw(_ rect: CGRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            coordinator?.draw(in: context, size: bounds.size)
        }
    }
}