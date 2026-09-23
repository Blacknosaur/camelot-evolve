@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// One asset, one image generator and one metadata load for a whole field
/// setup session. Stepping frames previously rebuilt all of these each time,
/// which made scrubbing feel sluggish on long recordings.
actor FieldFrameSource {
    struct Metadata: Sendable {
        let displaySize: CGSize
        let frameRate: Double
        let duration: Double
    }

    private let url: URL
    private var asset: AVURLAsset?
    private var generator: AVAssetImageGenerator?
    private var loadedMetadata: Metadata?

    init(url: URL) { self.url = url }

    func metadata() async throws -> Metadata {
        if let loadedMetadata { return loadedMetadata }
        let asset = self.asset ?? AVURLAsset(url: url)
        self.asset = asset
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let displaySize = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let metadata = Metadata(displaySize: displaySize, frameRate: fps.isFinite && fps > 0 ? fps : 30, duration: duration)
        loadedMetadata = metadata
        return metadata
    }

    func image(at time: Double, maximumSize: CGFloat = 1920) async throws -> CGImage {
        let asset = self.asset ?? AVURLAsset(url: url)
        self.asset = asset
        let generator: AVAssetImageGenerator
        if let existing = self.generator { generator = existing } else {
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumSize, height: maximumSize)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            self.generator = generator
        }
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}
