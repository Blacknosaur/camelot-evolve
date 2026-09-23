@preconcurrency import AVFoundation
import SwiftUI

/// Decoded frames from one remote camera, displayed through `AVSampleBufferDisplayLayer`.
/// The decoder pushes into `MultiCamFeed`; the view only owns the layer.
final class MultiCamFeed: @unchecked Sendable {
    let id: UUID
    private let decoder: MultiCamVideoDecoder
    private let displays: DisplayLayerStore
    /// Latest decoded frame, for whoever needs pixels (the program writer).
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { frameHandler.value }
        set { frameHandler.value = newValue }
    }
    private let frameHandler = LockedValue<(@Sendable (CVPixelBuffer) -> Void)?>(nil)
    /// The newest decoded frame from this camera, for the alignment preview.
    let latestFrame = LockedValue<CVPixelBuffer?>(nil)

    @MainActor init(id: UUID) {
        self.id = id
        let displays = DisplayLayerStore()
        self.displays = displays
        let handler = frameHandler
        let latest = latestFrame
        decoder = MultiCamVideoDecoder { pixelBuffer, _ in
            handler.value?(pixelBuffer)
            latest.value = pixelBuffer
            guard let decoded = Self.sample(from: pixelBuffer) else { return }
            nonisolated(unsafe) let sample = decoded
            DispatchQueue.main.async {
                displays.enqueue(sample)
            }
        }
    }

    func receive(_ packet: MultiCamVideoPacket) { decoder.decode(packet) }
    @MainActor func addDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect
        displays.add(layer)
    }
    @MainActor func removeDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        displays.remove(layer)
    }
    @MainActor func invalidate() {
        decoder.invalidate()
        displays.invalidate()
    }

    fileprivate static func sample(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first else { return nil }
        CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }
}

/// A lightweight second view of the local camera. AVCapture's preview connection remains owned by
/// the program monitor; the switcher thumbnail renders the most recent captured frame instead.
struct MultiCamFramePreview: UIViewRepresentable {
    let pixelBuffer: () -> CVPixelBuffer?

    func makeUIView(context: Context) -> MultiCamFeedView.FeedView {
        let view = MultiCamFeedView.FeedView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateUIView(_ view: MultiCamFeedView.FeedView, context: Context) {
        context.coordinator.pixelBuffer = pixelBuffer
    }
    func makeCoordinator() -> Coordinator { Coordinator(pixelBuffer: pixelBuffer) }
    static func dismantleUIView(_ view: MultiCamFeedView.FeedView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        var pixelBuffer: () -> CVPixelBuffer?
        weak var view: MultiCamFeedView.FeedView?
        private var displayLink: CADisplayLink?
        private var lastBuffer: ObjectIdentifier?

        init(pixelBuffer: @escaping () -> CVPixelBuffer?) { self.pixelBuffer = pixelBuffer }
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(drawFrame))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 8, preferred: 8)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }

        @objc private func drawFrame() {
            guard let buffer = pixelBuffer(), let view else { return }
            let identifier = ObjectIdentifier(buffer)
            guard identifier != lastBuffer, let sample = MultiCamFeed.sample(from: buffer) else { return }
            lastBuffer = identifier
            if view.feedLayer.status == .failed { view.feedLayer.flush() }
            view.feedLayer.enqueue(sample)
        }
    }
}

private final class WeakDisplayLayer {
    weak var layer: AVSampleBufferDisplayLayer?
    init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
}

@MainActor private final class DisplayLayerStore {
    private var layers: [ObjectIdentifier: WeakDisplayLayer] = [:]

    func add(_ layer: AVSampleBufferDisplayLayer) { layers[ObjectIdentifier(layer)] = WeakDisplayLayer(layer) }
    func remove(_ layer: AVSampleBufferDisplayLayer) { layers.removeValue(forKey: ObjectIdentifier(layer)) }
    func enqueue(_ sample: CMSampleBuffer) {
        layers = layers.filter { _, box in
            guard let layer = box.layer else { return false }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
            return true
        }
    }
    func invalidate() {
        layers.values.forEach { $0.layer?.flushAndRemoveImage() }
        layers.removeAll()
    }
}

struct MultiCamFeedView: UIViewRepresentable {
    let feed: MultiCamFeed

    func makeUIView(context: Context) -> FeedView {
        let view = FeedView()
        feed.addDisplayLayer(view.feedLayer)
        return view
    }
    func updateUIView(_ view: FeedView, context: Context) {
        guard context.coordinator.feed !== feed else { return }
        context.coordinator.feed?.removeDisplayLayer(view.feedLayer)
        feed.addDisplayLayer(view.feedLayer)
        context.coordinator.feed = feed
    }
    func makeCoordinator() -> Coordinator { Coordinator(feed: feed) }
    static func dismantleUIView(_ view: FeedView, coordinator: Coordinator) {
        coordinator.feed?.removeDisplayLayer(view.feedLayer)
    }

    @MainActor final class Coordinator {
        var feed: MultiCamFeed?
        init(feed: MultiCamFeed) { self.feed = feed }
    }

    final class FeedView: UIView {
        let feedLayer = AVSampleBufferDisplayLayer()
        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(feedLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            feedLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// The preview of this phone's own camera for multi-cam screens.
struct MultiCamPreview: UIViewRepresentable {
    let engine: MultiCamCaptureEngine

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = engine.session
        view.previewLayer.videoGravity = .resizeAspect
        engine.attachPreviewLayer(view.previewLayer)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { context.coordinator.engine = engine }
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor final class Coordinator: NSObject {
        var engine: MultiCamCaptureEngine
        private var startFactor: CGFloat = 1
        init(engine: MultiCamCaptureEngine) { self.engine = engine }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startFactor = engine.zoomFactor }
            engine.setZoom(startFactor * gesture.scale)
        }
    }
}
