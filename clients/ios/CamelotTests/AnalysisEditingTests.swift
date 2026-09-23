@preconcurrency import AVFoundation
import SwiftData
import UIKit
import XCTest
@testable import Camelot

final class AnalysisEditingTests: XCTestCase {
    func testPlayerMotionInterpolatesAndHidesUntrackedFrames() throws {
        var mark = AnalysisAnnotation(tool: .player, points: [.init(x: 0.1, y: 0.2), .init(x: 0.2, y: 0.4)], start: 1, end: 8)
        mark.playerMotion = .init(samples: [
            .init(time: 1, box: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2)),
            .init(time: 3, box: CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.4))
        ], lostAt: 3.1)
        XCTAssertEqual(mark.points(at: 2)[1].x, 0.45, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 2)[1].y, 0.6, accuracy: 0.001)
        XCTAssertEqual(mark.opacity(at: 2), 1)
        XCTAssertEqual(mark.opacity(at: 4), 0, "Never leave an effect frozen on the pitch after tracking stops")
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
        mark.playerMotion?.lostAt = nil
        mark.playerMotion?.gaps = [1.5...2.5]
        XCTAssertEqual(mark.opacity(at: 2), 0, "Manual corrections must not interpolate across an occlusion")
        XCTAssertEqual(mark.opacity(at: 3), 1)
    }

    @MainActor
    func testOverlappingBlueAndWhitePlayersDoNotSilentlySwapIdentity() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the fixture phone")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Stress-test recording unavailable")
        let detections = try await AnalysisEngine.analyze(url: url, range: 6.6...6.7) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.filter { $0.rect.contains(CGPoint(x: 0.444, y: 0.53)) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect)
        PlayerTrackingLimits.trace = { line in print("  CROSSING_TRACE \(line)") }
        defer { PlayerTrackingLimits.trace = nil }
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 6.6, to: 12.7) { _ in }
        for sample in motion.samples where Int(sample.time * 10) % 5 == 0 { print(String(format: "  CROSSING_BOX t=%.2f x=%.3f y=%.3f w=%.3f h=%.3f", sample.time, sample.box.minX, sample.box.minY, sample.box.width, sample.box.height)) }
        print("CROSSING_FOLLOW seed=\(seed) lost=\(String(describing: motion.lostAt)) final=\(String(describing: motion.samples.last))")
        // At the end the blue shirt is left of the white one. Either follow the
        // blue player or report loss; never confidently attach to the white one.
        if let box = motion.box(at: 12.6) {
            XCTAssertEqual(box.midX, 731.0 / 1920, accuracy: 0.025)
            XCTAssertEqual(box.maxY, 708.0 / 1080, accuracy: 0.035)
        } else { XCTAssertNotNil(motion.lostAt) }
        #endif
    }

    @MainActor
    func testWhiteDefenderKeepsIdentityThroughBlueAndWhiteCrossing() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 9...9.1) { _ in }
        let point = CGPoint(x: 0.569, y: 0.762)
        let seed = try XCTUnwrap(detections.frames.first?.detections.filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect)
        var motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 9, to: 10.3) { _ in }
        XCTAssertGreaterThan(motion.samples.count, 3, "The test must establish actual motion")
        motion.trackID = UUID()
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 9, endSeconds: 10.3)
        clip.storePlayerTrack(motion)
        let stored = try XCTUnwrap(clip.trackingLibrary?.players.first?.motion)
        for (time, x, feet) in [(9.8, 0.564, 0.854), (10.0, 0.572, 0.846)] {
            if let box = stored.box(at: time) {
                XCTAssertEqual(box.midX, x, accuracy: 0.025, "This is the white defender, not the blue carrier or the other white defender")
                XCTAssertEqual(box.maxY, feet, accuracy: 0.04)
            } else { XCTAssertTrue(stored.isMissing(at: time)) }
        }
    }

    @MainActor
    func testLearnedJerseyFollowsBluePlayerThroughCrossing() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.filter { $0.rect.contains(CGPoint(x: 0.417, y: 0.495)) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect)
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 12.7) { _ in }
        print("LEARNED_CROSSING seed=\(seed) lost=\(String(describing: motion.lostAt)) recoveries=\(motion.recoveryCount ?? 0) last=\(String(describing: motion.samples.last))")
        XCTAssertTrue(motion.jerseyProfile?.isConfirmed == true)
        XCTAssertGreaterThan(motion.recoveryCount ?? 0, 0)
        print("LEARNED_CROSSING gaps=\(motion.gaps ?? []) bridging=\(String(describing: motion.gapBridging))")
        // Gaps within the short display bridge are interpolated by design; longer ones stay hidden.
        for gap in motion.gaps ?? [] where gap.upperBound - gap.lowerBound > 0.4 { XCTAssertNil(motion.box(at: (gap.lowerBound + gap.upperBound) / 2)) }
        var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 12.7)
        ring.playerMotion = motion; ring.effect = .radar
        var label = AnalysisAnnotation(tool: .text, points: [.init(x: seed.midX, y: seed.minY - 0.025)], text: "BLUE PLAYER", start: 3, end: 12.7)
        label.playerMotion = motion.bound(at: 3, smoothing: 0.95)
        label.textStyle = .init(alignment: .center, size: 0.024, weight: .bold, background: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, feet) in [(5.0, CGPoint(x: 835.0 / 1920, y: 590.0 / 1080)),
                             (9.0, CGPoint(x: 1310.0 / 1920, y: 651.0 / 1080)),
                             (12.6, CGPoint(x: 731.0 / 1920, y: 708.0 / 1080))] {
            let box = try XCTUnwrap(motion.box(at: time))
            XCTAssertEqual(box.midX, feet.x, accuracy: 0.025, "Wrong identity at \(time)")
            XCTAssertEqual(box.maxY, feet.y, accuracy: 0.035, "Wrong feet at \(time)")
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height), frame = CGRect(origin: .zero, size: CGSize(width: source.width, height: source.height))
            let rendered = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw([ring, label], time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: rendered); attachment.name = "Hybrid blue player identity at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor
    func testSelectedPlayerFollowsMovementAndCameraPanOnStressVideo() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision object tracking requires the physical device")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Stress-test recording unavailable")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(CGPoint(x: 0.394, y: 0.586)) }?.rect)
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 9.1) { _ in }
        XCTAssertNil(motion.lostAt)
        XCTAssertGreaterThan(motion.samples.count, 150)
        var mark = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 9.1)
        mark.playerMotion = motion
        // Ground-truth foot positions read from exact source frames, not detector output.
        let expected: [(Double, CGPoint)] = [(3, .init(x: 755.0/1920, y: 674.0/1080)), (5, .init(x: 1040.0/1920, y: 736.0/1080)), (7, .init(x: 1210.0/1920, y: 810.0/1080)), (9, .init(x: 1017.0/1920, y: 923.0/1080))]
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, feet) in expected {
            let box = try XCTUnwrap(motion.box(at: time), "Missing tracking at \(time)")
            print("PLAYER_FOLLOW t=\(time) box=\(box) expectedFeet=\(feet)")
            XCTAssertEqual(box.midX, feet.x, accuracy: 0.025, "Wrong player at \(time)")
            XCTAssertEqual(box.maxY, feet.y, accuracy: 0.035, "Ring must stay at the player's feet at \(time)")
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height)
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw([mark], time: time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Following selected player at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
        // Reopen the serialized edit, then exercise the actual sequence compositor
        // and encoded video. Source positions must survive a nonzero clip In.
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 9.1)
        clip.annotations = [try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark))]
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let composition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: composition) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = composition
        let encoded = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for generator in [preview, encoded] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for sourceTime in [5.0, 7.0, 9.0] {
                let image = try await generator.image(at: CMTime(seconds: sourceTime - 3, preferredTimescale: 600)).image
                let box = try XCTUnwrap(motion.effectBodyBox(at: sourceTime))
                let feet = try XCTUnwrap(motion.groundPoint(at: sourceTime))
                // The ring uses stable body proportions, not stride-dependent
                // detector width. Ground-truth identity checks above stay intact.
                let x = feet.x - box.width * 0.7, y = feet.y
                let hasRing = (-4...4).contains { dx in
                    (-4...4).contains { dy in
                        let rgb = pixel(image, x: x + Double(dx) / Double(image.width), y: y + Double(dy) / Double(image.height))
                        return rgb[0] > 165 && rgb[1] > 220 && rgb[2] < 100
                    }
                }
                XCTAssertTrue(hasRing, "Preview/export must follow the saved player at source time \(sourceTime)")
            }
        }
        #endif
    }

    func testSavedLayersPreserveTimingMotionAndLegacyClips() throws {
        let id = UUID()
        let legacy = Data("{\"recordingID\":\"\(id)\",\"startSeconds\":0,\"endSeconds\":10}".utf8)
        let decoded = try JSONDecoder().decode(CompositionClip.self, from: legacy)
        XCTAssertTrue(decoded.annotations.isEmpty)
        var mark = AnalysisAnnotation(tool: .text, points: [CGPoint(x: 0.1, y: 0.2)], text: "Press here", start: 2, end: 6)
        mark.setKeyframe(at: 2, points: [CGPoint(x: 0.1, y: 0.2)])
        mark.setKeyframe(at: 4, points: [CGPoint(x: 0.5, y: 0.6)])
        XCTAssertEqual(mark.points(at: 3)[0].x, 0.3, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 3)[0].y, 0.4, accuracy: 0.001)
        XCTAssertEqual(mark.opacity(at: 1), 0)
        XCTAssertEqual(mark.opacity(at: 3), 1)
        XCTAssertEqual(mark.opacity(at: 6), 0)
        var clip = decoded; clip.annotations = [mark]; clip.freezeDuration = 5
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
        XCTAssertEqual(clip.playbackDuration, 5)
        let hold = EditorSequenceSegment(id: clip.id, sourceStart: 0, sourceEnd: 1 / 60, rate: 1, start: 2, freezeDuration: 5)
        XCTAssertEqual(hold.sourceTime(at: 6), 0)
        XCTAssertNil(hold.eventSnapshot(TimelineEventSnapshot(id: TimelineEventID(eventID: UUID()), offset: 1, preRoll: 2, postRoll: 2, kind: "Goal", colorHex: "")))
    }

    @MainActor
    func testLayersPersistWithTheCompositionAndInvalidateRenderRevision() throws {
        let container = try ModelContainer(for: VideoComposition.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 5)
        let video = VideoComposition(projectID: UUID(), name: "Analysis", kind: "multi-clip", clips: [clip])
        container.mainContext.insert(video); try container.mainContext.save()
        let originalRevision = video.renderRevision
        var edited = clip
        edited.annotations = [AnalysisAnnotation(tool: .player, points: [.init(x: 0.2, y: 0.3), .init(x: 0.3, y: 0.6)], start: 1, end: 4)]
        try video.saveEdit(clips: [edited], aspectRatio: "original", name: video.name, context: container.mainContext)
        let restored = try ModelContext(container).fetch(FetchDescriptor<VideoComposition>()).first
        XCTAssertEqual(restored?.decodedClips?.first?.annotations, edited.annotations)
        XCTAssertNotEqual(video.renderRevision, originalRevision)
    }

    @MainActor
    func testTimedZoomMovesVideoAndDrawingsTogetherInPreviewAndExport() async throws {
        let recording = try fixtureRecording()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        var zoom = AnalysisAnnotation(tool: .zoom, points: [.init(x: 0.65, y: 0.5)], start: 0.3, end: 1.7)
        zoom.zoomScale = 2; zoom.zoomRamp = 0.2
        let line = AnalysisAnnotation(tool: .line, points: [.init(x: 0.6, y: 0.4), .init(x: 0.7, y: 0.4)], width: 0.01, start: 0, end: 2)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 2)
        clip.annotations = [line, zoom]
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = video
        let output = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for generator in [preview, output] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let active = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
            XCTAssertGreaterThan(pixel(active, x: 0.5, y: 0.3)[1], 180, "Drawing scales and pans with the video")
            XCTAssertLessThan(pixel(active, x: 0.65, y: 0.4)[1], 80, "Original drawing location is empty")
            let before = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            XCTAssertGreaterThan(pixel(before, x: 0.65, y: 0.4)[1], 180)
            let after = try await generator.image(at: CMTime(seconds: 1.8, preferredTimescale: 600)).image
            // The fixture is blue at this time, so the yellow line remains distinguishable.
            XCTAssertGreaterThan(pixel(after, x: 0.65, y: 0.4)[1], 180)
        }
    }

    @MainActor
    func testTimedZoomSourcePixelsStayAlignedOnStressVideo() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 5)
        var zoom = AnalysisAnnotation(tool: .zoom, points: [.init(x: 0.65, y: 0.5)], start: 3.2, end: 4.8)
        zoom.zoomScale = 2; zoom.zoomRamp = 0.2; clip.annotations = [zoom]
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let source = AVAssetImageGenerator(asset: AVURLAsset(url: url)); source.appliesPreferredTrackTransform = true
        source.requestedTimeToleranceBefore = .zero; source.requestedTimeToleranceAfter = .zero
        let original = try await source.image(at: CMTime(seconds: 4, preferredTimescale: 600)).image
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = video
        let output = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for generator in [preview, output] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            var error = 0.0, count = 0
            for x in stride(from: 0.1, through: 0.9, by: 0.1) {
                for y in stride(from: 0.1, through: 0.9, by: 0.1) {
                    let actual = pixel(frame, x: x, y: y), expected = pixel(original, x: 0.4 + x / 2, y: 0.25 + y / 2)
                    for channel in 0..<3 { error += Double(abs(actual[channel] - expected[channel])); count += 1 }
                }
            }
            XCTAssertLessThan(error / Double(count), 15, "Video pixels must use the same top-left zoom transform as the drawings")
            let attachment = XCTAttachment(image: UIImage(cgImage: frame)); attachment.name = "Timed zoom on stress video"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor
    func testConnectedPlayersAndCameraAreaSurvivePreviewAndExport() async throws {
        let recording = try fixtureRecording()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        var connection = AnalysisAnnotation(tool: .connection, points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.3)], width: 0.025, start: 0, end: 1.8)
        connection.effect = .neon
        connection.linkedPlayers = [
            .init(samples: [.init(time: 0, box: .init(x: 0.15, y: 0.1, width: 0.1, height: 0.2)), .init(time: 2, box: .init(x: 0.25, y: 0.2, width: 0.1, height: 0.2))]),
            .init(samples: [.init(time: 0, box: .init(x: 0.75, y: 0.1, width: 0.1, height: 0.2)), .init(time: 2, box: .init(x: 0.65, y: 0.4, width: 0.1, height: 0.2))])
        ]
        var area = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.05, y: 0.65), .init(x: 0.2, y: 0.65), .init(x: 0.2, y: 0.8), .init(x: 0.05, y: 0.8)], start: 0, end: 1.8)
        area.effect = .neon; area.areaFill = 0.55
        area.cameraMotion = .init(samples: [.init(time: 0, transform: .identity), .init(time: 2, transform: .init(values: [1, 0, 0.2, 0, 1, 0, 0, 0, 1]))])
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 2)
        clip.annotations = [connection, area]
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = video
        let output = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for generator in [preview, output] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            XCTAssertGreaterThan(pixel(image, x: 0.5, y: 0.4)[1], 85, "Connection must use both moving endpoint positions")
            XCTAssertGreaterThan(pixel(image, x: 0.25, y: 0.72)[1], 100, "Area must follow its saved camera transform")
            XCTAssertLessThan(pixel(image, x: 0.5, y: 0.3)[1], 70, "Connection must leave its initial position")
        }
    }

    @MainActor
    func testTimelineKeyframesRenderAfterMovingLayerInPreviewAndExport() async throws {
        let recording = try fixtureRecording()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        var mark = AnalysisAnnotation(tool: .line, points: [.init(x: 0.2, y: 0.25), .init(x: 0.8, y: 0.25)], width: 0.03, start: 0.2, end: 1.4)
        mark.enableKeyframes(at: 0.2)
        mark.moveDrawing(to: [.init(x: 0.2, y: 0.75), .init(x: 0.8, y: 0.75)], at: 1.2)
        mark = mark.applying(.move(0.25), within: 0...2)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 2)
        clip.annotations = [mark]
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = video
        let output = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for generator in [preview, output] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: 0.95, preferredTimescale: 600)).image
            XCTAssertGreaterThan(pixel(frame, x: 0.5, y: 0.5)[1], 180, "The moved layer must interpolate between its shifted keyframes")
            let absent = try await generator.image(at: CMTime(seconds: 1.8, preferredTimescale: 600)).image
            XCTAssertLessThan(pixel(absent, x: 0.5, y: 0.5)[1], 70)
        }
    }

    @MainActor
    func testTimedDrawingAppearsInPreviewAndExportAtTheSamePosition() async throws {
        let recording = try fixtureRecording()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 2)
        var mark = AnalysisAnnotation(tool: .line, points: [.init(x: 0.2, y: 0.25), .init(x: 0.8, y: 0.25)], width: 0.03, start: 0.2, end: 0.8)
        mark.fade = false; clip.annotations = [mark]
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original", maximumDimension: nil)
        let generator = AVAssetImageGenerator(asset: asset); generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let drawn = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
        let absent = try await generator.image(at: CMTime(seconds: 1.4, preferredTimescale: 600)).image
        XCTAssertGreaterThan(pixel(drawn, x: 0.5, y: 0.25)[1], 180, "Yellow line must be at the authored top-left position")
        XCTAssertLessThan(pixel(absent, x: 0.5, y: 0.25)[1], 70, "Line must disappear at Out")
        let id = UUID()
        let exported = try await CompositionRenderer.export(asset: asset, id: id, videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let outputGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        outputGenerator.requestedTimeToleranceBefore = .zero; outputGenerator.requestedTimeToleranceAfter = .zero
        let frame = try await outputGenerator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
        XCTAssertGreaterThan(pixel(frame, x: 0.5, y: 0.25)[1], 160, "Shared video must contain the drawing")
        let attachment = XCTAttachment(image: UIImage(cgImage: frame)); attachment.name = "Rendered annotation"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testFreezeFrameHoldsWithoutAdvancingTheSourceAndResumesNextClip() async throws {
        let recording = try fixtureRecording()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        var freeze = CompositionClip(recordingID: recording.id, startSeconds: 0.25, endSeconds: 0.25 + 1 / 60)
        freeze.freezeDuration = 3
        freeze.annotations = [AnalysisAnnotation(tool: .text, points: [.init(x: 0.1, y: 0.15)], text: "HOLD", start: 0.25, end: 3.25)]
        let after = CompositionClip(recordingID: recording.id, startSeconds: 1, endSeconds: 2)
        let asset = try await CompositionRenderer.makeAsset(clips: [freeze, after], recordings: [recording])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.02)
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [freeze, after], recordings: [recording], aspectRatio: "original")
        let generator = AVAssetImageGenerator(asset: asset); generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [0.5, 2.5, 3.5] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let sample = pixel(frame, x: 0.5, y: 0.5)
            if time < 3 { XCTAssertGreaterThan(sample[0], sample[2] + 100, "Freeze must retain the red source frame") }
            else { XCTAssertGreaterThan(sample[2], sample[0] + 100, "Playback must resume into the blue clip") }
        }
    }

    @MainActor
    func testDetectionOnUsersStressTestSoccerVideo() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the connected phone for the on-device model")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "The user's stress-test soccer recording is not on this device")
        let result = try await AnalysisEngine.analyze(url: url, range: 3...3.3) { _ in }
        let frame = try XCTUnwrap(result.frames.first)
        XCTAssertGreaterThanOrEqual(frame.detections.count, 8, "The real wide soccer shot contains more than eight visible players")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let source = try await generator.image(at: CMTime(seconds: frame.time, preferredTimescale: 600)).image
        let size = CGSize(width: source.width, height: source.height)
        let marks = frame.detections.map { AnalysisAnnotation(tool: .player, points: [$0.rect.origin, .init(x: $0.rect.maxX, y: $0.rect.maxY)], start: 0, end: 100) }
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
            AnnotationRenderer.draw(marks, time: frame.time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Stress soccer – \(frame.detections.count) detections"; attachment.lifetime = .keepAlways; add(attachment)
        print("STRESS_SOCCER_DETECTIONS=\(frame.detections.count)")
        #endif
    }

    @MainActor private func fixtureRecording() throws -> Recording {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let recording = Recording(projectID: UUID(), localPath: ".annotation-test-\(UUID()).mp4", duration: 2)
        try FileManager.default.createDirectory(at: recording.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: recording.fileURL)
        return recording
    }
    private func pixel(_ image: CGImage, x: Double, y: Double) -> [Int] {
        let crop = image.cropping(to: CGRect(x: Double(image.width) * x, y: Double(image.height) * y, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }
}
