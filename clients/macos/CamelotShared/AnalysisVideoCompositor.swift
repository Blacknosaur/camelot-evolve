@preconcurrency import AVFoundation
import CoreImage

final class AnalysisVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    var timeRange = CMTimeRange.zero
    var enablePostProcessing = false
    var containsTweening = true
    var sourceID: CMPersistentTrackID = 0
    var sourceTransform = CGAffineTransform.identity
    var displayFrame = CGRect.zero
    var annotations: [AnalysisAnnotation] = []
    var groundCalibration: GroundCalibration?
    var sourceStart = 0.0
    var annotationRate = 1.0
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: sourceID)] }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }
}

/// Render timed graphics into the frame for both AVPlayer and file export.
final class AnalysisVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.camelot.annotation-render")
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String]] }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? AnalysisVideoInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.sourceID),
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: CocoaError(.coderInvalidValue)); return
                }
                let size = request.renderContext.size
                let bounds = CGRect(origin: .zero, size: size)
                let time = instruction.sourceStart + (request.compositionTime.seconds - instruction.timeRange.start.seconds) * instruction.annotationRate
                let zoom = AnnotationViewport.transform(marks: instruction.annotations, time: time, frame: instruction.displayFrame, bounds: bounds)
                // AVFoundation transforms use top-left coordinates; Core Image uses bottom-left.
                let transform = CGAffineTransform(translationX: 0, y: CGFloat(CVPixelBufferGetHeight(source)))
                    .scaledBy(x: 1, y: -1)
                    .concatenating(instruction.sourceTransform)
                    .concatenating(zoom)
                    .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
                // Keep this image free of annotations: loupes sample it below so a
                // loupe can never magnify another loupe or a drawn mark.
                let unannotated = CIImage(cvPixelBuffer: source).transformed(by: transform)
                let cleanBase = unannotated.composited(over: CIImage(color: .black).cropped(to: bounds))
                var image = cleanBase
                let annotationFrame = instruction.displayFrame.applying(zoom)
                var pending: [AnalysisAnnotation] = []
                func flushDrawings() {
                    guard !pending.isEmpty else { return }
                    defer { pending.removeAll(keepingCapacity: true) }
                    guard let drawing = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                    drawing.translateBy(x: 0, y: size.height); drawing.scaleBy(x: 1, y: -1)
                    AnnotationRenderer.draw(pending, time: time, in: drawing, frame: annotationFrame, ground: instruction.groundCalibration)
                    if let overlay = drawing.makeImage() { image = CIImage(cgImage: overlay).composited(over: image) }
                }
                for mark in instruction.annotations where mark.tool != .zoom && mark.opacity(at: time) > 0 {
                    if mark.tool == .loupe, let geometry = AnnotationLoupeGeometry.make(mark: mark, time: time, frame: annotationFrame, bounds: bounds) {
                        flushDrawings()
                        image = AnnotationLoupeRenderer.image(cleanBase, geometry: geometry, bounds: bounds, over: image, opacity: mark.opacity(at: time))
                        if let drawing = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            drawing.translateBy(x: 0, y: size.height); drawing.scaleBy(x: 1, y: -1)
                            drawing.setAlpha(mark.opacity(at: time))
                            AnnotationLoupeRenderer.drawBorder(geometry, in: drawing)
                            if let overlay = drawing.makeImage() { image = CIImage(cgImage: overlay).composited(over: image) }
                        }
                    } else if mark.tool != .loupe { pending.append(mark) }
                }
                flushDrawings()
                context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
}
