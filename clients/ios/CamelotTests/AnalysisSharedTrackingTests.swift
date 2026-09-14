@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import Camelot

final class AnalysisSharedTrackingTests: XCTestCase {
    func testAlignedTextMetricsScaleAndPreserveLegacyDefaults() throws {
        var mark = AnalysisAnnotation(tool: .text, points: [.zero], text: "Player 10\nForward", start: 0, end: 4)
        XCTAssertEqual(mark.resolvedTextStyle.alignment, .left)
        XCTAssertEqual(mark.resolvedTextStyle.size, mark.width * 6)
        mark.textStyle = .init(alignment: .center, size: 0.04, weight: .regular, background: true)
        let centre = AnnotationTextLayout(mark: mark, frameWidth: 1000)
        XCTAssertEqual(centre.bounds.midX, 0, accuracy: 0.01)
        XCTAssertEqual(centre.lines.count, 2)
        mark.textStyle?.alignment = .right
        let right = AnnotationTextLayout(mark: mark, frameWidth: 1000)
        XCTAssertLessThan(right.bounds.minX, centre.bounds.minX)
        XCTAssertLessThan(right.bounds.maxX, centre.bounds.maxX)
        let doubled = AnnotationTextLayout(mark: mark, frameWidth: 2000)
        XCTAssertEqual(doubled.bounds.width, right.bounds.width * 2, accuracy: 1)
        XCTAssertEqual(doubled.bounds.height, right.bounds.height * 2, accuracy: 1)
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
    }

    func testOffscreenReturnResumesSameIdentityWithoutDrawingAcrossAbsence() throws {
        let id = UUID()
        let before = PlayerMotion(samples: [
            .init(time: 0, box: .init(x: 0.8, y: 0.4, width: 0.1, height: 0.2)),
            .init(time: 1, box: .init(x: 0.96, y: 0.4, width: 0.04, height: 0.2))
        ], lostAt: 1.1, trackID: id)
        let returned = PlayerMotion(samples: [
            .init(time: 4, box: .init(x: 0.91, y: 0.4, width: 0.09, height: 0.2)),
            .init(time: 6, box: .init(x: 0.7, y: 0.4, width: 0.1, height: 0.2))
        ])
        XCTAssertEqual(before.correctionTime, 1)
        XCTAssertNil(returned.correctionTime)
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 6)
        clip.storePlayerTrack(before)
        var options = AnalysisPlayerEffects(); options.label = true; options.spotlight = true
        _ = clip.applyPlayerEffects(options, replacing: [], box: before.samples[0].box, motion: before, at: 0)
        clip.storePlayerTrack(before.continuing(with: returned, from: 4))
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        XCTAssertEqual(clip.trackingLibrary?.players.first?.id, id)
        for mark in clip.annotations {
            XCTAssertEqual(mark.opacity(at: 2), 0, "Hide every attached effect while outside the view")
            XCTAssertEqual(mark.opacity(at: 5), 1, "Resume without assigning a new player")
            XCTAssertEqual(mark.playerMotion?.trackID, id)
            XCTAssertEqual(mark.playerMotion?.samples.first, before.samples.first)
        }
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
    }

    @MainActor
    func testLightWallsAndFirstConstructionPointAreVisible() throws {
        let size = CGSize(width: 640, height: 360), frame = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func render(_ draw: (CGContext) -> Void) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.black.setFill(); renderer.fill(frame); draw(renderer.cgContext)
            }
        }
        var wall = AnalysisAnnotation(tool: .connection, points: [.init(x: 0.2, y: 0.7), .init(x: 0.8, y: 0.7)],
                                      color: .init(red: 0.1, green: 0.8, blue: 1), width: 0.002, start: 0, end: 5)
        wall.effect = .wall; wall.wallHeight = 0.3; wall.wallOpacity = 0.6
        let projected = render { AnnotationRenderer.draw([wall], time: 1, in: $0, frame: frame) }
        var flat = wall; flat.effect = .clean
        let baseline = render { AnnotationRenderer.draw([flat], time: 1, in: $0, frame: frame) }
        XCTAssertNotEqual(projected.pngData(), baseline.pngData())
        let crop = CGRect(x: 300, y: 185, width: 12, height: 12)
        XCTAssertNotEqual(projected.cgImage?.cropping(to: crop)?.dataProvider?.data as Data?, baseline.cgImage?.cropping(to: crop)?.dataProvider?.data as Data?, "Light must rise above the ground line")
        let first = render { AnalysisConstructionOverlay.draw(points: [.init(x: 0.3, y: 0.6)], frame: frame, in: $0) }
        let empty = render { _ in }
        XCTAssertNotEqual(first.pngData(), empty.pngData(), "One point must be visible before a segment exists")
        for (name, image) in [("Light wall on a connected line", projected), ("Visible first construction point", first)] {
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(wall, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(wall)))
    }
    private func motion() -> PlayerMotion {
        .init(samples: (0...120).map { i in
            .init(time: Double(i) / 30, box: .init(x: 0.2 + Double(i) / 1200, y: 0.3, width: 0.05, height: 0.2))
        }, trackID: UUID())
    }

    func testTrackSurvivesDeletingLayersAndRoundTrips() throws {
        let source = motion()
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        clip.storePlayerTrack(source)
        let saved = try XCTUnwrap(clip.trackingLibrary?.players.first)
        let pose = try XCTUnwrap(saved.motion.bound(at: 2))
        var ring = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 0.1, y: 0.2)], start: 2, end: 4)
        ring.playerMotion = pose; clip.annotations = [ring]
        let restored = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(restored, clip)
        clip.annotations = []
        XCTAssertEqual(clip.trackingLibrary?.players.first?.motion.samples, source.samples)
        XCTAssertNotNil(clip.trackingLibrary?.player(matching: try XCTUnwrap(source.box(at: 3)), at: 3))
        XCTAssertNil(clip.trackingLibrary?.player(matching: try XCTUnwrap(source.box(at: 3)), at: 8))
    }

    func testIndependentPlayersCorrectionAndReuseRemainIsolated() throws {
        var first = motion(), second = motion()
        second.samples = second.samples.map { .init(time: $0.time, box: $0.box.offsetBy(dx: 0.4, dy: 0)) }
        first.lostAt = 2
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        clip.storePlayerTrack(first); clip.storePlayerTrack(second)
        let secondBefore = try XCTUnwrap(clip.trackingLibrary?.players.last)
        var ring = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 0.1, y: 0.2)], start: 0, end: 4)
        ring.playerMotion = first.bound(at: 0)
        var label = AnalysisAnnotation(tool: .text, points: [.zero], text: "Two", start: 0, end: 4)
        label.playerMotion = second.bound(at: 0, smoothing: 0.95)
        var link = AnalysisAnnotation(tool: .connection, points: [.zero, .init(x: 1, y: 1)], start: 0, end: 4)
        link.linkedPlayers = [first.bound(at: 0)!, second.bound(at: 0)!]
        clip.annotations = [ring, label, link]
        let continuation = PlayerMotion(samples: first.samples.filter { $0.time >= 3 }.map {
            .init(time: $0.time, box: $0.box.offsetBy(dx: 0.01, dy: 0))
        })
        let corrected = first.continuing(with: continuation, from: 3)
        clip.storePlayerTrack(corrected)
        XCTAssertEqual(clip.trackingLibrary?.players.count, 2)
        XCTAssertEqual(clip.trackingLibrary?.players.map(\.name), ["Player 1", "Player 2"])
        XCTAssertEqual(clip.trackingLibrary?.players.last, secondBefore)
        XCTAssertEqual(clip.annotations[1], label, "Correcting Player 1 must never modify Player 2's label")
        XCTAssertEqual(clip.annotations[2].linkedPlayers?[1], link.linkedPlayers?[1])
        XCTAssertEqual(clip.annotations[0].playerMotion?.samples, corrected.samples)
        XCTAssertNil(corrected.box(at: 2.5), "Do not invent motion across the missing interval")
        XCTAssertNotNil(corrected.box(at: 3))
        XCTAssertEqual(clip.trackingLibrary?.player(matching: second.samples[90].box, at: 3)?.id, second.trackID)
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
        clip.annotations = []
        XCTAssertEqual(clip.trackingLibrary?.players.count, 2)
    }

    func testUnifiedPlayerOptionsReuseMotionAndPreserveLayerEdits() throws {
        let source = motion(), box = try XCTUnwrap(source.box(at: 1))
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        clip.storePlayerTrack(source)
        var options = AnalysisPlayerEffects(name: "Player 1")
        options.spotlight = true; options.label = true; options.text = "10 · Alex"
        _ = clip.applyPlayerEffects(options, replacing: [], box: box, motion: source, at: 1)
        XCTAssertEqual(clip.annotations.count, 3)
        XCTAssertEqual(Set(clip.annotations.compactMap { $0.playerMotion?.trackID }), [source.trackID!])
        XCTAssertEqual(clip.annotations.first { $0.tool == .text }?.text, "10 · Alex")
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        clip.annotations[0].end = 2
        clip.annotations[0].points[0].x += 0.02
        clip.annotations[1].isLocked = true
        let ring = clip.annotations[0], spotlight = clip.annotations[1]
        let ids = Set(clip.annotations.map(\.id))
        var edited = AnalysisPlayerEffects(layers: clip.annotations)
        edited.label = false; edited.spotlight = false; edited.ringStyle = .pulse
        edited.color = .init(red: 0, green: 1, blue: 1)
        _ = clip.applyPlayerEffects(edited, replacing: ids, box: box, motion: source, at: 1)
        XCTAssertEqual(clip.annotations.count, 2, "Remove label; keep the locked spotlight")
        XCTAssertEqual(clip.annotations[0].id, ring.id)
        XCTAssertEqual(clip.annotations[0].end, 2)
        XCTAssertEqual(clip.annotations[0].points, ring.points)
        XCTAssertEqual(clip.annotations[0].playerMotion, ring.playerMotion)
        XCTAssertEqual(clip.annotations[0].effect, .pulse)
        XCTAssertEqual(clip.annotations[1], spotlight)
        XCTAssertFalse(AnalysisDrawingTool.toolbarTools.contains(.spotlight))
        XCTAssertTrue(AnalysisDrawingTool.toolbarTools.contains(.text), "Keep general text drawing")
    }

    func testStillPlayerOptionsStayGroupedWithoutInventingTracking() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 3, endSeconds: 3.1)
        clip.freezeDuration = 5
        var options = AnalysisPlayerEffects(); options.spotlight = true; options.label = true
        let box = CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.2)
        _ = clip.applyPlayerEffects(options, replacing: [], box: box, motion: nil, at: 3)
        XCTAssertEqual(clip.annotations.count, 3)
        XCTAssertEqual(Set(clip.annotations.compactMap(\.playerEffectGroupID)).count, 1)
        XCTAssertTrue(clip.annotations.allSatisfy { $0.playerMotion == nil && $0.playerEffectBox == box })
        let ids = Set(clip.annotations.map(\.id))
        _ = clip.applyPlayerEffects(options, replacing: ids, box: box, motion: nil, at: 4)
        XCTAssertEqual(Set(clip.annotations.map(\.id)), ids)
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
    }

    func testCorrectionUpdatesEveryAttachedEffectWithoutChangingItsBindPose() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        var source = motion()
        var label = AnalysisAnnotation(tool: .text, points: [.init(x: 0.4, y: 0.2)], text: "10", start: 2, end: 4)
        label.playerMotion = source.bound(at: 2, smoothing: 0.95)
        var ring = AnalysisAnnotation(tool: .player, points: [.init(x: 0.2, y: 0.3), .init(x: 0.25, y: 0.5)], start: 0, end: 4)
        ring.playerMotion = source.bound(at: 0); ring.isLocked = true
        var link = AnalysisAnnotation(tool: .connection, points: [.zero, .init(x: 1, y: 1)], start: 0, end: 4)
        link.linkedPlayers = [source.bound(at: 1)!, motion()]
        clip.annotations = [ring, label, link]
        clip.storePlayerTrack(source)
        source.samples[100].box.origin.x += 0.01
        clip.storePlayerTrack(source)
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        XCTAssertEqual(clip.annotations[0].playerMotion?.samples, source.samples)
        XCTAssertEqual(clip.annotations[1].playerMotion?.samples, source.samples)
        XCTAssertEqual(clip.annotations[2].linkedPlayers?[0].samples, source.samples)
        XCTAssertEqual(clip.annotations[1].playerMotion?.referenceBox, label.playerMotion?.referenceBox)
        XCTAssertEqual(clip.annotations[1].playerMotion?.smoothing, 0.95)
        XCTAssertEqual(clip.annotations[1].points(at: 2)[0].x, label.points[0].x, accuracy: 0.00001)
        XCTAssertEqual(clip.annotations[1].points(at: 2)[0].y, label.points[0].y, accuracy: 0.00001)
        XCTAssertEqual(clip.annotations[0].isLocked, true)
    }

    func testLabelTranslationDoesNotAmplifyChangingBoxHeightAndCanBeEdited() throws {
        var source = PlayerMotion(samples: [
            .init(time: 0, box: .init(x: 0.3, y: 0.3, width: 0.1, height: 0.2)),
            .init(time: 1, box: .init(x: 0.3, y: 0.25, width: 0.1, height: 0.3))
        ], smoothing: 0)
        source.referenceBox = source.samples[0].box
        var label = AnalysisAnnotation(tool: .text, points: [.init(x: 0.35, y: 0.2)], text: "Player", start: 0, end: 2)
        label.playerMotion = source
        XCTAssertEqual(label.points(at: 1)[0].y, 0.2, accuracy: 0.00001, "Same body centre; height noise must not bounce the text")
        label.moveDrawing(to: [.init(x: 0.42, y: 0.12)], at: 1)
        XCTAssertEqual(label.points(at: 1)[0].y, 0.12, accuracy: 0.00001)
        label.makeStatic(at: 1)
        XCTAssertNil(label.playerMotion)
        XCTAssertTrue(label.isActiveInEditor(at: -0.001), "A rounded exact seek keeps the In frame editable")
        XCTAssertFalse(label.isActiveInEditor(at: -0.01))
        XCTAssertEqual(label.opacity(at: -0.001), 0, "Export timing stays exact")
        source.smoothing = nil; label.playerMotion = source
        XCTAssertEqual(label.displayPlayerMotion?.smoothing, 0.95, "Legacy labels benefit without retracking")
    }

    func testCameraReuseAtDifferentTimesAndSharedCorrection() throws {
        let id = UUID()
        var camera = AnnotationCameraMotion(samples: [
            .init(time: 0, transform: .identity),
            .init(time: 4, transform: .init(values: [1.2, 0, 0.1, 0, 1.2, -0.1, 0, 0, 1]))
        ], trackID: id)
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        clip.storeCameraTrack(camera)
        var mark = AnalysisAnnotation(tool: .line, points: [.init(x: 0.2, y: 0.4), .init(x: 0.7, y: 0.4)], start: 2, end: 4)
        camera.referenceTime = 2; mark.cameraMotion = camera
        XCTAssertEqual(mark.points(at: 2)[0].x, 0.2, accuracy: 0.00001)
        let edited = [CGPoint(x: 0.3, y: 0.6), CGPoint(x: 0.8, y: 0.7)]
        mark.moveDrawing(to: edited, at: 3)
        XCTAssertEqual(mark.points(at: 3)[0].y, 0.6, accuracy: 0.00001)
        clip.annotations = [mark]
        camera.samples[1].transform.values[2] += 0.02
        clip.storeCameraTrack(camera)
        XCTAssertEqual(clip.annotations[0].cameraMotion?.referenceTime, 2)
        XCTAssertEqual(clip.trackingLibrary?.cameras.count, 1)
        XCTAssertNil(clip.trackingLibrary?.cameras.first?.referenceTime)
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
    }

    func testLegacyTracksArePromotedWithoutReprocessingAndGapsStayHidden() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 4)
        var mark = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 1, y: 1)], start: 0, end: 4)
        var source = motion(); source.trackID = nil; source.gaps = [1...1.5]; source.lostAt = 3
        mark.playerMotion = source; clip.annotations = [mark]
        clip.importAnnotationTracks()
        let imported = clip
        clip.importAnnotationTracks()
        XCTAssertEqual(clip, imported)
        XCTAssertEqual(clip.trackingLibrary?.players.first?.motion.samples, source.samples)
        XCTAssertNil(clip.trackingLibrary?.players.first?.motion.bound(at: 1.2))
        XCTAssertNil(clip.trackingLibrary?.players.first?.motion.bound(at: 3.5))
    }

    func testFieldProjectionMapsAllFourCornersAndRejectsCrossedOrCollapsedShapes() throws {
        let corners: [CGPoint] = [.init(x: 0.3, y: 0.2), .init(x: 0.7, y: 0.25), .init(x: 0.9, y: 0.9), .init(x: 0.1, y: 0.8)]
        let projection = try XCTUnwrap(AnalysisFieldGuide.projection(corners: corners))
        for (input, expected) in zip([CGPoint.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)], corners) {
            let mapped = try XCTUnwrap(projection.point(input))
            XCTAssertEqual(mapped.x, expected.x, accuracy: 0.00001)
            XCTAssertEqual(mapped.y, expected.y, accuracy: 0.00001)
        }
        XCTAssertFalse(AnalysisFieldGuide.path(corners: corners).isEmpty)
        XCTAssertNil(AnalysisFieldGuide.projection(corners: [corners[0], corners[2], corners[1], corners[3]]))
        XCTAssertNil(AnalysisFieldGuide.projection(corners: Array(repeating: .zero, count: 4)))
        var mark = AnalysisAnnotation(tool: .zone, points: corners, start: 0, end: 4)
        mark.fieldLines = true
        mark.insertPolygonCorner(after: 0); mark.removePolygonCorner(at: 1)
        XCTAssertEqual(mark.points.count, 4)
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
    }

    @MainActor
    func testSmootherSharedLabelAndCameraOnActualStressFootage() async throws {
        let sourceRecordingID = ProcessInfo.processInfo.environment["CAMELOT_ANALYSIS_RECORDING_ID"] ?? "EBB12192-62DB-495B-A6CE-218F0C420A74"
        let url = URL.documentsDirectory.appending(path: "Recordings/\(sourceRecordingID).mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let detected = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detected.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        var player = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 9.1) { _ in }
        player.trackID = UUID()
        let secondSeed = try XCTUnwrap(detected.frames.first?.detections.first { $0.rect.contains(.init(x: 0.685, y: 0.53)) }?.rect)
        var secondPlayer = try await SelectedPlayerTracking.track(url: url, seed: secondSeed, from: 3, to: 9.1) { _ in }
        secondPlayer.trackID = UUID()
        let secondAtFive = try XCTUnwrap(secondPlayer.box(at: 5))
        // Read from the unannotated source frame: a different, white-shirted
        // player, not the blue-shirted player's identity used above.
        XCTAssertEqual(secondAtFive.midX, 0.679, accuracy: 0.035)
        XCTAssertEqual(secondAtFive.midY, 0.57, accuracy: 0.035)
        XCTAssertGreaterThan(abs(secondAtFive.midX - (player.box(at: 5)?.midX ?? 0)), 0.08)
        var secondRing = AnalysisAnnotation(tool: .player, points: [secondSeed.origin, .init(x: secondSeed.maxX, y: secondSeed.maxY)],
                                            color: .init(red: 0.1, green: 0.8, blue: 1), start: 3, end: 9.1)
        secondRing.playerMotion = secondPlayer.bound(at: 3); secondRing.effect = .radar
        let raw = player.samples
        var label = AnalysisAnnotation(tool: .text, points: [.init(x: seed.midX, y: seed.minY - 0.03)], text: "PLAYER 10", start: 3, end: 9.1)
        label.playerMotion = player.bound(at: 3, smoothing: 0.95)
        label.textStyle = .init(alignment: .center, size: 0.028, weight: .bold, background: true)
        var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 9.1)
        ring.playerMotion = player.bound(at: 3); ring.effect = .radar
        var spotlight = ring; spotlight.id = UUID(); spotlight.tool = .spotlight; spotlight.effect = .neon
        var rawJitter = 0.0, smoothJitter = 0.0
        for i in 2..<(raw.count - 2) {
            let a = raw[i - 1], b = raw[i], c = raw[i + 1]
            guard let pa = label.playerMotion?.box(at: a.time), let pb = label.playerMotion?.box(at: b.time), let pc = label.playerMotion?.box(at: c.time) else { continue }
            rawJitter += pow(c.box.midX - 2 * b.box.midX + a.box.midX, 2) + pow(c.box.midY - 2 * b.box.midY + a.box.midY, 2)
            smoothJitter += pow(pc.midX - 2 * pb.midX + pa.midX, 2) + pow(pc.midY - 2 * pb.midY + pa.midY, 2)
        }
        print("SHARED_LABEL_JITTER raw=\(rawJitter) smooth=\(smoothJitter) ratio=\(smoothJitter / max(1e-12, rawJitter))")
        XCTAssertLessThan(smoothJitter, rawJitter * 0.5)
        XCTAssertEqual(label.playerMotion?.samples, raw)
        let camera = try await CameraMotionTracking.track(url: url, from: 3, to: 9.1) { _ in }
        print("SHARED_CAMERA samples=\(camera.samples.count) lost=\(String(describing: camera.lostAt))")
        XCTAssertNil(camera.lostAt)
        // Fixed floodlight base, manually read from source frames. Coverage alone
        // cannot detect a plausible but drifting image-registration matrix.
        let landmark = CGPoint(x: 0.531, y: 0.414)
        if let moved = camera.transform(at: 9)?.point(landmark) {
            print("CAMERA_FIXED_LANDMARK at9=\(moved)")
            XCTAssertEqual(moved.x, 0.88, accuracy: 0.03)
            XCTAssertEqual(moved.y, 0.385, accuracy: 0.03)
        } else { XCTFail("Missing camera motion at the landmark check") }
        let doorway = try XCTUnwrap(camera.transform(at: 9)?.point(.init(x: 0.377, y: 0.401)))
        XCTAssertEqual(doorway.x, 0.70, accuracy: 0.03)
        XCTAssertEqual(doorway.y, 0.372, accuracy: 0.03)
        var guide = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.15, y: 0.5), .init(x: 0.75, y: 0.5), .init(x: 0.95, y: 0.9), .init(x: 0.05, y: 0.9)], start: 3, end: 9.1)
        guide.fieldLines = true; guide.width = 0.001; guide.cameraMotion = camera
        var wall = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.15, y: 0.65), .init(x: 0.36, y: 0.62), .init(x: 0.42, y: 0.82), .init(x: 0.18, y: 0.87)],
                                      color: .init(red: 0.1, green: 0.8, blue: 1), width: 0.0015, start: 3, end: 9.1)
        wall.effect = .wall; wall.wallHeight = 0.22; wall.cameraMotion = camera
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [3.0, 5, 7, 9] {
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height)
            let rendered = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw([guide, wall, spotlight, ring, label, secondRing], time: time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
            }
            let attachment = XCTAttachment(image: rendered); attachment.name = "Shared track label and field template at \(time)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 9.1)
        clip.annotations = [guide, wall, spotlight, ring, label, secondRing]; clip.storePlayerTrack(player); clip.storePlayerTrack(secondPlayer)
        XCTAssertEqual(clip.trackingLibrary?.players.count, 2)
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let encoded = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        encoded.requestedTimeToleranceBefore = .zero; encoded.requestedTimeToleranceAfter = .zero
        let output = try await encoded.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
        let exportAttachment = XCTAttachment(image: UIImage(cgImage: output)); exportAttachment.name = "Encoded shared label halo spotlight and camera field"; exportAttachment.lifetime = .keepAlways; add(exportAttachment)
        XCTAssertEqual(output.width, 1920)
    }
}
