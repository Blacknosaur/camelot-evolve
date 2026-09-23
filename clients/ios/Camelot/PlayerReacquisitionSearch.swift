@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// One body the search thinks could be the lost player.
struct PlayerReacquisitionCandidate: Identifiable, Sendable {
    let id = UUID()
    let time: Double
    /// Display coordinates in the source frame.
    let box: CGRect
    /// How well this body matches the player's remembered appearance, 0–1.
    let score: Float
    /// A crop of the body, for the user to recognise at a glance.
    let thumbnail: UIImage
}

/// Finds bodies that might be a lost player, for a person to confirm.
///
/// Kit and image similarity rank suggestions; the user's confirmation decides
/// identity. Several plausible teammates from the same frame must remain
/// available, even when their appearance scores are nearly identical.
enum PlayerReacquisitionSearch {
    /// Seconds between searched frames. The player has to be found, not tracked,
    /// so this is coarse on purpose.
    static let interval = 0.4
    /// Candidates closer together than this are the same sighting; only the
    /// best is kept, so the list is a set of moments rather than a burst.
    static let separation = 1.2

    static func candidates(url: URL, from start: Double, to end: Double,
                           memory: PlayerIdentityMemory, limit: Int = 12,
                           progress: @escaping @Sendable (Double) -> Void = { _ in })
    async throws -> [PlayerReacquisitionCandidate] {
        guard end > start, limit > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let naturalSize = try await video.load(.naturalSize)
        let orientation = AnalysisEngine.orientation(for: try await video.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let scale = min(1, 1280 / max(naturalSize.width, naturalSize.height))
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int(naturalSize.width * scale / 2) * 2),
            kCVPixelBufferHeightKey as String: max(2, Int(naturalSize.height * scale / 2) * 2),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AnalysisError.reader(reader.error?.localizedDescription ?? "Cannot open video")
        }
        defer { reader.cancelReading() }

        let detector = try SportsPlayerDetector()
        let printer = PlayerAppearancePrinter()
        let context = CIContext(options: [.cacheIntermediates: false])
        var found: [PlayerReacquisitionCandidate] = []
        var lastSearched = -Double.infinity

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard seconds - lastSearched >= interval - 0.002 else { continue }
            lastSearched = seconds
            progress(min(1, (seconds - start) / max(0.01, end - start)))
            if ProcessInfo.processInfo.thermalState == .critical { throw AnalysisError.thermal }

            try autoreleasepool {
                let boxes = try detector.playerBoxes(in: buffer, orientation: orientation)
                var frameCandidates: [PlayerReacquisitionCandidate] = []
                for box in boxes {
                    var observation = PlayerObservation.observe(buffer, box: box, orientation: orientation, among: boxes)
                    observation.time = seconds
                    // The embedding is the most expensive cue, so it is only
                    // spent on bodies the cheap cues already like.
                    guard let rough = memory.similarity(to: observation), rough > 0.5 else { continue }
                    if memory.gallery?.isReady == true, !observation.crowded, box.height >= PlayerAppearanceGallery.minimumBodyHeight {
                        observation.print = printer.print(buffer, box: box, orientation: orientation)
                    }
                    let score = memory.similarity(to: observation) ?? rough
                    guard score > 0.5, let thumbnail = crop(buffer, box: box, orientation: orientation, context: context) else { continue }
                    frameCandidates.append(.init(time: seconds, box: box, score: score, thumbnail: thumbnail))
                }
                // Bound retained images during the pass, including long clips.
                found = diverseCandidates(found + frameCandidates, limit: limit)
            }
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Search decoding failed") }
        progress(1)
        return found.sorted { $0.time == $1.time ? $0.box.midX < $1.box.midX : $0.time < $1.time }
    }

    /// Suppress repeat views of the same body, not every other body in that
    /// moment. Leave room for later sightings when many teammates share a kit.
    static func diverseCandidates(_ candidates: [PlayerReacquisitionCandidate], limit: Int) -> [PlayerReacquisitionCandidate] {
        guard limit > 0 else { return [] }
        let ordered = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.box.minX < $1.box.minX
        }
        var selected: [PlayerReacquisitionCandidate] = []
        for candidate in ordered {
            let nearby = selected.filter { abs($0.time - candidate.time) < separation }
            guard nearby.count < min(6, limit),
                  !nearby.contains(where: { PlayerTracker.overlap($0.box, candidate.box) > 0.3 }) else { continue }
            selected.append(candidate)
            if selected.count >= limit { break }
        }
        return selected
    }

    /// A padded crop of the body, big enough to recognise a face, a number or
    /// the way someone stands.
    private static func crop(_ buffer: CVPixelBuffer, box: CGRect,
                             orientation: CGImagePropertyOrientation, context: CIContext) -> UIImage? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let padded = box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull, padded.width > 0.004, padded.height > 0.01 else { return nil }
        let region = CGRect(x: extent.minX + padded.minX * extent.width,
                            y: extent.minY + (1 - padded.maxY) * extent.height,
                            width: padded.width * extent.width,
                            height: padded.height * extent.height).intersection(extent).integral
        guard region.width >= 8, region.height >= 8 else { return nil }
        let magnify = min(4, max(1, 220 / region.height))
        let image = upright.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: magnify, y: magnify))
        guard let rendered = context.createCGImage(image, from: CGRect(
            x: 0, y: 0, width: region.width * magnify, height: region.height * magnify)) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
