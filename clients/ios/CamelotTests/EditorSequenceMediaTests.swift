@preconcurrency import AVFoundation
import XCTest
@testable import Camelot

final class EditorSequenceMediaTests: XCTestCase {
    @MainActor
    func testPreviewRendersReorderedTrimmedClipsAtDifferentSpeeds() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let recording = Recording(projectID: UUID(), localPath: "editor-test-\(UUID()).mp4", duration: 2)
        try FileManager.default.createDirectory(at: recording.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: recording.fileURL)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        // Source is red then blue. Output must be blue (0.5s), then red (2s).
        let clips = [
            CompositionClip(recordingID: recording.id, startSeconds: 1, endSeconds: 2, rate: 2),
            CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 1, rate: 0.5)
        ]
        let asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: clips, recordings: [recording], aspectRatio: "original")
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.5, accuracy: 0.01)
        XCTAssertEqual(video.instructions.count, 2)
        XCTAssertEqual(video.instructions[0].timeRange.duration.seconds, 0.5, accuracy: 0.01)
        XCTAssertEqual(video.instructions[1].timeRange.start.seconds, 0.5, accuracy: 0.01)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let blue = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let red = try await generator.image(at: CMTime(seconds: 1.2, preferredTimescale: 600)).image
        let bluePixel = pixel(blue); let redPixel = pixel(red)
        XCTAssertGreaterThan(bluePixel[2], bluePixel[0] + 100)
        XCTAssertGreaterThan(redPixel[0], redPixel[2] + 100)
    }

    @MainActor
    func testPlayerContinuesAcrossTwoDifferentSourceVideos() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let recordings = (0..<2).map { _ in Recording(projectID: UUID(), localPath: "preview-test-\(UUID()).mp4", duration: 2) }
        try FileManager.default.createDirectory(at: recordings[0].fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for recording in recordings { try FileManager.default.copyItem(at: fixture, to: recording.fileURL) }
        defer { for recording in recordings { try? FileManager.default.removeItem(at: recording.fileURL) } }
        let clips = [
            CompositionClip(recordingID: recordings[0].id, startSeconds: 1, endSeconds: 1.5),
            CompositionClip(recordingID: recordings[1].id, startSeconds: 0, endSeconds: 1)
        ]
        let asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: recordings)
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: clips, recordings: recordings, aspectRatio: "original")
        let item = AVPlayerItem(asset: asset); item.videoComposition = video
        let player = AVPlayer(playerItem: item)
        defer { player.pause() }
        player.playImmediately(atRate: 1)
        for _ in 0..<30 {
            if player.currentTime().seconds > 0.8 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(player.currentTime().seconds, 0.8, "Playback must cross the cut at 0.5 seconds")
    }

    @MainActor
    func testRapidScrubbingEndsOnVisibleFrameAndCanResumeAcrossCuts() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let recording = Recording(projectID: UUID(), localPath: "seek-test-\(UUID()).mp4", duration: 2)
        try FileManager.default.copyItem(at: fixture, to: recording.fileURL)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        let clips = [
            CompositionClip(recordingID: recording.id, startSeconds: 1, endSeconds: 2),
            CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 1)
        ]
        let asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: clips, recordings: [recording], aspectRatio: "original")
        let item = AVPlayerItem(asset: asset); item.videoComposition = video
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let playback = EditorPlayback(player: AVPlayer(), duration: 2)
        playback.load(item: item, duration: 2)
        defer { playback.stop() }
        for index in 0..<100 { playback.commitSeek(Double(index % 19) / 10) }
        playback.commitSeek(2)
        for _ in 0..<50 {
            if item.status == .readyToPlay, playback.player.currentTime().seconds > 1.9 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.errorMessage)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertLessThan(playback.player.currentTime().seconds, 2, "The Out boundary must show the last frame, not an empty end boundary")
        var frame: CVPixelBuffer?
        for _ in 0..<30 {
            frame = output.copyPixelBuffer(forItemTime: playback.player.currentTime(), itemTimeForDisplay: nil)
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let buffer = try XCTUnwrap(frame, "A decoded frame must survive rapid seeks all the way to the end")
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetBytesPerRow(buffer) * (CVPixelBufferGetHeight(buffer) / 2) + (CVPixelBufferGetWidth(buffer) / 2) * 4
        XCTAssertGreaterThan(Int(bytes[offset + 2]), Int(bytes[offset]) + 100, "The final clip should display a red frame")
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        for index in 0..<30 { playback.commitSeek(Double(index % 19) / 10) }
        playback.playRange(from: 0.8, to: 2)
        for _ in 0..<30 {
            if playback.player.timeControlStatus == .playing, playback.player.currentTime().seconds > 1.2, playback.player.currentTime().seconds < 1.9 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(playback.player.timeControlStatus, .playing)
        XCTAssertLessThan(playback.player.currentTime().seconds, 1.9)
        XCTAssertGreaterThan(playback.player.currentTime().seconds, 1.2, "Playback must resume and cross the cut after scrubbing")
        XCTAssertTrue(playback.player.currentItem === item)
    }

    @MainActor
    func testPlaybackReturnsToPausedAtVideoAndEventEnd() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let playback = EditorPlayback(player: AVPlayer(url: fixture), duration: 2)
        defer { playback.stop() }
        for (start, end) in [(1.8, 2.0), (0.1, 0.4)] {
            playback.playRange(from: start, to: end)
            XCTAssertTrue(playback.isPlaying)
            for _ in 0..<40 {
                if !playback.isPlaying, playback.player.currentTime().seconds >= end - 0.06 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(playback.isPlaying, "The control must return to Play at the end of the video or event")
            XCTAssertEqual(playback.player.timeControlStatus, .paused)
            XCTAssertEqual(playback.currentSeconds, end, accuracy: 0.08)
        }
        playback.playRange(from: 0, to: 2)
        for _ in 0..<30 {
            if playback.player.timeControlStatus == .playing, playback.player.currentTime().seconds > 0.1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(playback.isPlaying, "Playback must restart after reaching the end")
        XCTAssertEqual(playback.player.timeControlStatus, .playing)
    }

    private func pixel(_ image: CGImage) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }
}
