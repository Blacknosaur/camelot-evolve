@preconcurrency import AVFoundation
import CoreGraphics

/// Content equality is stable across rendering and playback updates. JSON serialization
/// is deliberately excluded: its key ordering is not a stable task identity.
struct EditorSequenceRequest: Equatable {
    let clips: [CompositionClip]
    let aspectRatio: String
    let isActive: Bool
    let retry: Int
}

/// A sequence uses one player item, so playback and scrubbing continue across every cut.
/// Per-clip transforms also handle a portrait clip next to a landscape clip.
@MainActor enum EditorSequencePreview {
    static func makeVideoComposition(asset: AVAsset, clips: [CompositionClip], recordings: [Recording], aspectRatio: String, maximumDimension: CGFloat? = 1920) async throws -> AVMutableVideoComposition {
        guard let outputTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var sourceFrameRates: [Float] = []
        var sources: [UUID: (CGSize, CGAffineTransform)] = [:]
        for id in Set(clips.map(\.recordingID)) {
            guard let recording = recordings.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
            let sourceAsset = AVURLAsset(url: recording.fileURL)
            guard let track = try await sourceAsset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            sourceFrameRates.append(try await track.load(.nominalFrameRate))
            sources[id] = (size, transform)
            withExtendedLifetime(sourceAsset) {}
        }
        guard let first = clips.first.flatMap({ sources[$0.recordingID] }) else { throw CocoaError(.fileReadCorruptFile) }
        let firstDisplay = CGRect(origin: .zero, size: first.0).applying(first.1).standardized.size
        let ratio: CGFloat
        switch aspectRatio {
        case "portrait": ratio = 9 / 16
        case "square": ratio = 1
        case "landscape": ratio = 16 / 9
        default: ratio = firstDisplay.width / max(1, firstDisplay.height)
        }
        let width = max(2, min(firstDisplay.width, (maximumDimension ?? max(firstDisplay.width, firstDisplay.height)) * min(1, ratio)))
        let renderSize = CGSize(width: floor(width / 2) * 2, height: max(2, floor(width / ratio / 2) * 2))
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let frameRate = maximumDimension == nil ? max(1, min(60, Int((sourceFrameRates.max() ?? 30).rounded()))) : 30
        composition.frameDuration = CMTime(value: 1, timescale: Int32(frameRate))
        let hasAnnotations = clips.contains { !$0.annotations.isEmpty }
        if hasAnnotations { composition.customVideoCompositorClass = AnalysisVideoCompositor.self }
        var cursor = 0.0
        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        for clip in clips {
            guard let source = sources[clip.recordingID] else { continue }
            let display = CGRect(origin: .zero, size: source.0).applying(source.1).standardized
            let scaleX = renderSize.width / max(1, display.width)
            let scaleY = renderSize.height / max(1, display.height)
            let scale = aspectRatio == "original" ? min(scaleX, scaleY) : max(scaleX, scaleY)
            let transform = source.1
                .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - display.width * scale) / 2, y: (renderSize.height - display.height * scale) / 2))
            let duration = clip.playbackDuration
            let timeRange = CMTimeRange(start: CMTime(seconds: cursor, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
            if hasAnnotations {
                let annotated = AnalysisVideoInstruction()
                annotated.sourceID = outputTrack.trackID
                annotated.sourceTransform = transform
                annotated.displayFrame = CGRect(x: (renderSize.width - display.width * scale) / 2, y: (renderSize.height - display.height * scale) / 2, width: display.width * scale, height: display.height * scale)
                annotated.annotations = clip.annotations
                annotated.groundCalibration = clip.groundCalibration
                annotated.sourceStart = clip.startSeconds
                annotated.annotationRate = clip.annotationRate
                annotated.timeRange = timeRange
                instructions.append(annotated)
            } else {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = timeRange
                instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: outputTrack)
                layer.setTransform(transform, at: timeRange.start)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            cursor += duration
        }
        composition.instructions = instructions
        return composition
    }
}
