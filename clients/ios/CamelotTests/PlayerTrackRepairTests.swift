@preconcurrency import AVFoundation
import UIKit
import SwiftUI
import XCTest
@testable import Camelot

final class PlayerTrackRepairTests: XCTestCase {
    func testAutomaticInterpolationOnlyBridgesTinyBoundedGaps() throws {
        let box = CGRect(x: 0.3, y: 0.4, width: 0.05, height: 0.15)
        var motion = PlayerMotion(samples: [.init(time: 1, box: box),
            .init(time: 1.2, box: box.offsetBy(dx: 0.02, dy: 0))], smoothing: 0)
        motion.gaps = [(1.0).nextUp...(1.2).nextDown]
        motion.gapBridging = PlayerMotion.defaultGapBridging
        motion.automaticallyInterpolatesTinyGaps = true
        motion.hidesUncertainPositions = true
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 1.1)).midX, box.midX + 0.01, accuracy: 0.001)
        XCTAssertTrue(motion.isMissing(at: 1.1), "Raw measurement gaps remain explicit")
        XCTAssertNil(motion.silhouette(at: 1.1), "Do not invent body masks")
        motion.correctionTimes = [1.2]
        XCTAssertNil(motion.box(at: 1.1), "Never interpolate across a manual identity correction")
        motion.correctionTimes = nil
        motion.samples[1] = .init(time: 1.2, box: box.offsetBy(dx: 0.5, dy: 0))
        XCTAssertNil(motion.box(at: 1.1), "Never bridge a teammate jump")
        motion.samples[0] = .init(time: 1, box: box.offsetBy(dx: -0.32, dy: 0))
        motion.samples[1] = .init(time: 1.2, box: box.offsetBy(dx: -0.3, dy: 0))
        XCTAssertNil(motion.box(at: 1.1), "Never bridge a frame exit")
        motion.samples = [.init(time: 1, box: box), .init(time: 1.4, box: box.offsetBy(dx: 0.04, dy: 0))]
        motion.gaps = [(1.0).nextUp...(1.4).nextDown]
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 1.2)).midX, box.midX + 0.02, accuracy: 0.001)
        motion.samples = [.init(time: 1, box: box), .init(time: 2, box: box.offsetBy(dx: 0.04, dy: 0))]
        motion.gaps = [(1.0).nextUp...(2.0).nextDown]
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 1.5)).midX, box.midX + 0.02, accuracy: 0.001)
        motion.samples = [.init(time: 1, box: box), .init(time: 2.1, box: box)]
        motion.gaps = [(1.0).nextUp...(2.1).nextDown]
        XCTAssertNil(motion.box(at: 1.2), "Longer losses remain hidden")
        motion.gaps = nil; motion.lostAt = (1.0).nextUp
        XCTAssertNil(motion.box(at: 1.1), "No extrapolation without a confirmed next point")
    }

    func testExitRecoveryRequiresSameEdgeOrCameraAndIdentityEvidence() {
        let left = CGRect(x: 0.02, y: 0.5, width: 0.05, height: 0.15)
        let right = left.offsetBy(dx: 0.8, dy: 0)
        XCTAssertTrue(PlayerTrackingSearch.allowsReturn(left, through: .left, cameraPosition: nil, strongIdentity: false))
        XCTAssertFalse(PlayerTrackingSearch.allowsReturn(right, through: .left, cameraPosition: nil, strongIdentity: true))
        XCTAssertFalse(PlayerTrackingSearch.allowsReturn(right, through: .left, cameraPosition: right, strongIdentity: false))
        XCTAssertFalse(PlayerTrackingSearch.allowsReturn(right, through: .left, cameraPosition: left, strongIdentity: true))
        XCTAssertTrue(PlayerTrackingSearch.allowsReturn(right, through: .left, cameraPosition: right, strongIdentity: true))
        XCTAssertFalse(PlayerTrackingSearch.allowsReturn(left, through: .right, cameraPosition: nil, strongIdentity: true))
        XCTAssertTrue(PlayerTrackingSearch.allowsReturn(right, through: nil, cameraPosition: nil, strongIdentity: false))
    }

    func testOcclusionHoldFollowsTheCameraAndHidesWhenTheBodyIsGone() throws {
        let trusted = CGRect(x: 0.4, y: 0.6, width: 0.08, height: 0.2)
        let shift = CameraTransform(values: [1, 0, 0.1, 0, 1, 0.02, 0, 0, 1])
        let held = PlayerOcclusionHold.box(trusted: trusted, trustedTime: 2, at: 2.4, camera: shift, velocity: nil, bodyStillVisible: true)
        let box = try XCTUnwrap(held)
        XCTAssertEqual(box.midX, trusted.midX + 0.1, accuracy: 0.001)
        XCTAssertEqual(box.maxY, trusted.maxY + 0.02, accuracy: 0.001)
        XCTAssertNil(PlayerOcclusionHold.box(trusted: trusted, trustedTime: 2, at: 2.4, camera: shift, velocity: nil, bodyStillVisible: false),
                     "A fully hidden player stays unmarked")
        XCTAssertNil(PlayerOcclusionHold.box(trusted: trusted, trustedTime: 2, at: 3.2, camera: shift, velocity: nil, bodyStillVisible: true),
                     "The hold ends after a second")
        let exit = CameraTransform(values: [1, 0, -0.7, 0, 1, 0, 0, 0, 1])
        XCTAssertNil(PlayerOcclusionHold.box(trusted: trusted, trustedTime: 2, at: 2.3, camera: exit, velocity: nil, bodyStillVisible: true),
                     "Off screen, the marker stays hidden until the player is seen again")
    }

    func testExitSearchStaysFastThroughoutAnAbsence() {
        XCTAssertEqual(PlayerTrackingSearch.recoveryInterval(confirming: false, exited: true, dormant: true), 0.1)
        XCTAssertEqual(PlayerTrackingSearch.recoveryInterval(confirming: false, exited: true, dormant: false), 0.1)
        XCTAssertEqual(PlayerTrackingSearch.recoveryInterval(confirming: true, exited: true, dormant: true), 0.06)
        XCTAssertEqual(PlayerTrackingSearch.recoveryInterval(confirming: false, exited: false, dormant: true), 0.4)
    }

    func testConfirmedEstimatedBodyRemainsDrawableAfterAnOffscreenGap() throws {
        let full = CGRect(x: 0.3, y: 0.7, width: 0.04, height: 0.15)
        let returning = CGRect(x: 0.05, y: 0.91, width: 0.04, height: 0.15)
        var motion = PlayerMotion(samples: [.init(time: 0, box: full), .init(time: 10, box: returning)], smoothing: 0)
        motion.gaps = [1...9.9]
        XCTAssertNotNil(motion.effectBodyBox(at: 10))
        XCTAssertGreaterThan(try XCTUnwrap(motion.groundPoint(at: 10)).y, 1)
        XCTAssertNil(motion.effectBodyBox(at: 5), "An estimate does not bridge lost identity")
        motion.samples[1] = .init(time: 10, box: CGRect(x: 0.05, y: 0.91, width: 0.04, height: 0.09))
        XCTAssertNil(motion.effectBodyBox(at: 10), "A legacy clipped box still needs a complete reference in this segment")
    }

    func testShirtHemNearBottomEdgeRetainsKnownBodyProportions() {
        let reference = CGRect(x: 0.2, y: 0.7, width: 0.045, height: 0.14)
        let visible = CGRect(x: 0.02, y: 0.915, width: 0.045, height: 0.058)
        let body = PlayerBodyExtent.estimate(visible: visible, reference: reference)
        XCTAssertEqual(body.minY, visible.minY)
        XCTAssertEqual(body.height, reference.height)
        XCTAssertGreaterThan(body.maxY, 1)
        let interior = visible.offsetBy(dx: 0.2, dy: -0.3)
        XCTAssertEqual(PlayerBodyExtent.estimate(visible: interior, reference: reference), interior,
                       "A short interior box alone does not prove occluded legs")
        let complete = CGRect(x: 0.02, y: 0.83, width: 0.045, height: 0.14)
        XCTAssertEqual(PlayerBodyExtent.estimate(visible: complete, reference: reference), complete)
    }

    func testExitSearchRegionsStayInsideImageAndIncludeTheRememberedEdge() {
        let box = CGRect(x: 0.01, y: 0.9, width: 0.04, height: 0.12)
        for side in [PlayerExitSide.left, .right, .top, .bottom] {
            let region = PlayerTrackingSearch.edgeRegion(side, near: box)
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(region))
        }
        XCTAssertEqual(PlayerTrackingSearch.edgeRegion(.left, near: box).minX, 0)
        XCTAssertEqual(PlayerTrackingSearch.edgeRegion(.bottom, near: box).maxY, 1)
    }

    func testSavedPlayerSelectionPreservesStyleTimingAndOtherLayers() throws {
        let original = motion()
        var other = motion()
        other.samples = other.samples.map { .init(time: $0.time, box: $0.box.offsetBy(dx: 0.3, dy: 0.1)) }
        var mark = AnalysisAnnotation(tool: .text, points: [.init(x: 0.22, y: 0.2)], start: 1, end: 8)
        mark.playerMotion = original.bound(at: 2, smoothing: 0.95)
        mark.text = "Captain"
        var sibling = mark; sibling.id = UUID()
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        clip.annotations = [mark, sibling]; clip.storePlayerTrack(original); clip.storePlayerTrack(other)
        let saved = try XCTUnwrap(clip.trackingLibrary?.players.last)
        let library = clip.trackingLibrary
        let oldPoints = mark.points(at: 2)
        XCTAssertTrue(clip.followSavedPlayer(saved, layerID: mark.id, at: 2))
        let changed = clip.annotations[0]
        XCTAssertEqual(changed.playerMotion?.trackID, saved.id)
        XCTAssertEqual(changed.text, "Captain")
        XCTAssertEqual(changed.start, mark.start); XCTAssertEqual(changed.end, mark.end)
        XCTAssertEqual(changed.playerMotion?.smoothing, 0.95)
        XCTAssertEqual(changed.points[0].x, oldPoints[0].x + 0.3, accuracy: 0.0001)
        XCTAssertEqual(changed.points[0].y, oldPoints[0].y + 0.1, accuracy: 0.0001)
        XCTAssertEqual(clip.annotations[1], sibling); XCTAssertEqual(clip.trackingLibrary, library)
        clip.annotations[0].isLocked = true
        XCTAssertFalse(clip.followSavedPlayer(saved, layerID: mark.id, at: 2))
        XCTAssertFalse(clip.followSavedPlayer(saved, layerID: sibling.id, at: 20))
    }

    func testShortGapsInterpolateButCorrectionsAndLongAbsencesDoNot() throws {
        var track = motion()
        track.gaps = [2...2.25]
        XCTAssertEqual(try XCTUnwrap(track.box(at: 2.1)).minX, 0.221, accuracy: 0.0001)
        XCTAssertEqual(track.gaps, [2...2.25], "Inference must not erase raw confidence")
        track.correctionTimes = [2.3]
        XCTAssertNil(track.box(at: 2.1))
        track.correctionTimes = nil; track.gaps = [2...3]
        XCTAssertNil(track.box(at: 2.5))
        track.gaps = [9.8...10.2]
        XCTAssertNil(track.box(at: 9.9), "No extrapolation without a reliable future observation")
    }

    func testGapFillOnlyAddsMissingSamplesAndPreservesTrackedSamples() {
        var saved = motion()
        saved.samples.removeAll { $0.time > 2 && $0.time < 3 }
        saved.gaps = [2...3]
        let before = saved.samples.filter { $0.time <= 2 }
        let after = saved.samples.filter { $0.time >= 3 }
        let partial = PlayerMotion(samples: [
            .init(time: 2.25, box: .init(x: 0.7, y: 0.3, width: 0.05, height: 0.15)),
            .init(time: 2.75, box: .init(x: 0.75, y: 0.3, width: 0.05, height: 0.15))
        ])

        let filled = saved.filling(with: partial, in: 2...3)

        XCTAssertEqual(filled.samples.filter { $0.time <= 2 }, before)
        XCTAssertEqual(filled.samples.filter { $0.time >= 3 }, after)
        XCTAssertEqual(filled.samples.filter { $0.time > 2 && $0.time < 3 }.count, 2)
        XCTAssertEqual(filled.samples.first { abs($0.time - 2.25) < 0.001 }?.box.minX, 0.7)
        XCTAssertTrue(filled.gaps?.contains { $0.lowerBound <= 2 && $0.upperBound < 2.25 } == true)
        XCTAssertTrue(filled.gaps?.contains { $0.lowerBound > 2.75 && $0.upperBound >= 3 } == true)

        var failedFill = partial
        failedFill.lostAt = 2.85
        let afterFailedFill = saved.filling(with: failedFill, in: 2...3)
        XCTAssertNil(afterFailedFill.lostAt, "A failed fill inside an internal gap must not hide the confirmed future")
        XCTAssertNotNil(afterFailedFill.box(at: 4))
    }

    @MainActor
    func testActualRepairReachesNextManualBoundaryWithoutChangingLaterTrackingOrOtherPlayers() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        var original = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 9.1) { _ in }
        var interrupted = original
        interrupted.gaps = (original.gaps ?? []) + [4.4...4.6]
        let automaticallyFilled = try XCTUnwrap(interrupted.bridged(camera: nil).box(at: 4.5))
        let observed = try XCTUnwrap(original.box(at: 4.5))
        XCTAssertGreaterThan(PlayerTracker.overlap(automaticallyFilled, observed), 0.55,
                             "Automatic interpolation should follow actual motion in a short gap")
        XCTAssertTrue(interrupted.isMissing(at: 4.5), "Display interpolation preserves missing measurements")
        interrupted.automaticallyInterpolatesTinyGaps = false
        XCTAssertNil(interrupted.bridged(camera: nil).box(at: 4.5), "Strict tracking still hides gaps when automatic interpolation is disabled")
        interrupted.hidesUncertainPositions = false; interrupted.gapBridging = 0.4
        let inferred = try XCTUnwrap(interrupted.box(at: 4.5))
        XCTAssertGreaterThan(PlayerTracker.overlap(inferred, observed), 0.55, "A short inferred gap should follow actual motion in the stress footage")
        original.trackID = UUID(); original.correctionTimes = [3, 8]
        let repairSeed = try XCTUnwrap(original.box(at: 4))
        let repair = try await SelectedPlayerTracking.track(url: url, seed: repairSeed, from: 4, to: 9.1, prior: original) { _ in }
        XCTAssertGreaterThan(try XCTUnwrap(repair.samples.last?.time), 7.8, "Keep repairing until the next manual boundary")
        XCTAssertLessThan(try XCTUnwrap(repair.samples.last?.time), 8)
        var reviewed = original
        for frame in 121...129 { reviewed.place(repairSeed.offsetBy(dx: 0.2, dy: 0), at: Double(frame) / 30) }
        let redoPrior = reviewed.clearingTracking(in: 4...6)
        let redone = try await SelectedPlayerTracking.track(url: url, seed: repairSeed, from: 4, to: 6,
                                                            prior: redoPrior, confirmedSeed: true) { _ in }
        let replaced = redoPrior.continuing(with: redone, from: 4)
        XCTAssertGreaterThan(try XCTUnwrap(redone.samples.last?.time), 5.9, "Redo crosses all nine old reviewed frames")
        XCTAssertEqual(replaced.samples.filter { $0.time < 4 || $0.time >= 6 }, original.samples.filter { $0.time < 4 || $0.time >= 6 })
        XCTAssertGreaterThan(PlayerTracker.overlap(try XCTUnwrap(replaced.box(at: 5)), try XCTUnwrap(original.box(at: 5))), 0.5)
        let combined = original.continuing(with: repair, from: 4)
        XCTAssertEqual(combined.samples.filter { $0.time >= 8 }, original.samples.filter { $0.time >= 8 })
        XCTAssertEqual(combined.correctionTimes, [3, 4, 8])
        var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 9.1)
        ring.playerMotion = original.bound(at: 3); ring.effect = .radar
        var beam = ring; beam.id = UUID(); beam.tool = .spotlight; beam.effect = .neon
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 3, endSeconds: 9.1)
        let unrelated = motion()
        clip.annotations = [ring, beam]; clip.storePlayerTrack(original); clip.storePlayerTrack(unrelated)
        let other = clip.trackingLibrary?.players.last
        clip.storePlayerTrack(combined)
        XCTAssertEqual(clip.trackingLibrary?.players.last, other)
        XCTAssertEqual(clip.annotations[0].playerMotion?.samples, combined.samples)
        XCTAssertEqual(clip.annotations[1].playerMotion?.samples, combined.samples)
        XCTAssertEqual(clip.annotations[0].playerMotion?.reference, ring.playerMotion?.reference)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [5.0, 7, 9] {
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height), frame = CGRect(origin: .zero, size: CGSize(width: source.width, height: source.height))
            let feet = try XCTUnwrap(combined.groundPoint(at: time))
            XCTAssertEqual(clip.annotations[0].renderedPoints(at: time).last!.y, feet.y, accuracy: 0.001)
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw(clip.annotations, time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Preserved track and grounded halo plus beam at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testFrameReviewUsesSourceRateAndStopsAtExclusiveClipEnd() throws {
        for rate in [24.0, 29.97, 30, 60, 120] {
            let review = PlayerFrameReview(range: 0...2, frameRate: rate)
            let first = try XCTUnwrap(review.next(after: 0))
            XCTAssertEqual(first, 1 / rate, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(review.next(after: first)), 2 / rate, accuracy: 0.000001)
            XCTAssertEqual(review.previous(before: first), 0)
            XCTAssertNil(review.previous(before: 0))
        }
        XCTAssertNil(PlayerFrameReview(range: 0...1, frameRate: 30).next(after: 29.0 / 30))
        XCTAssertEqual(PlayerFrameReview(range: 0.015...1, frameRate: 30).previous(before: 1.0 / 30), 0.015)
    }

    func testManualReviewKeepsAdjacentHighFrameRateSelectionsAndRemovesOldMask() throws {
        var track = motion()
        let first = CGRect(x: 0.3, y: 0.4, width: 0.04, height: 0.12)
        let second = first.offsetBy(dx: 0.01, dy: 0)
        track.place(first, at: 2)
        track.place(second, at: 2 + 1.0 / 120)
        XCTAssertEqual(track.anchors?.count, 2)
        XCTAssertEqual(track.samples.first { abs($0.time - 2) < 0.00001 }?.box, first)
        XCTAssertEqual(track.samples.first { abs($0.time - (2 + 1.0 / 120)) < 0.00001 }?.box, second)
        XCTAssertEqual(track.box(at: 2), first)
        XCTAssertEqual(track.box(at: 2 + 1.0 / 120), second)
        XCTAssertEqual(track, try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(track)))
    }

    func testAutomaticRepairsRespectManualFramesInBothDirections() {
        var saved = motion()
        let manual = CGRect(x: 0.5, y: 0.4, width: 0.04, height: 0.12)
        saved.place(manual, at: 4)
        XCTAssertEqual(saved.repairEnd(from: 3, to: 9), 4)
        XCTAssertEqual(saved.repairStart(from: 5, to: 0), 4)
        let forward = saved.continuing(with: motion(from: 3, to: 8), from: 3)
        let backward = saved.prepending(motion(from: 1, to: 5), seed: 5)
        XCTAssertEqual(forward.box(at: 4), manual)
        XCTAssertEqual(backward.box(at: 4), manual)
        XCTAssertEqual(backward.samples.filter { $0.time < 4 }, saved.samples.filter { $0.time < 4 })
        XCTAssertEqual(backward.samples.filter { $0.time >= 5 }, saved.samples.filter { $0.time >= 5 })
    }

    func testNewIdentityGapsStayHiddenAfterStorageIntoLegacyBridgedEffects() throws {
        var old = motion(); old.gapBridging = 2
        var layer = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 0.05, y: 0.15)], start: 0, end: 10)
        layer.playerMotion = old
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        clip.annotations = [layer]; clip.storePlayerTrack(old)
        var fresh = old; fresh.gaps = [4...4.2]; fresh.hidesUncertainPositions = true
        clip.storePlayerTrack(fresh)
        XCTAssertNil(clip.annotations[0].playerMotion?.box(at: 4.1))
        XCTAssertEqual(clip.annotations[0].opacity(at: 4.1), 0)
        clip.setGapBridging(2, layerID: layer.id)
        XCTAssertNotNil(clip.annotations[0].playerMotion?.box(at: 4.1), "The user can explicitly request estimated display")
    }

    @MainActor
    func testManualReviewControlsRenderOnPhoneAtCompactAndWideWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for width in [360.0, 744.0] {
            let controls = AnalysisPlayerFrameReviewControls(name: "Blue player 9", time: 9.833,
                canGoBack: true, canGoNext: true, canUndo: true, canTrack: true, isSeeking: false,
                previous: {}, next: {}, undo: {}, track: {}, done: {})
                .frame(width: width).environment(\.colorScheme, .dark)
            // Menu uses a UIKit-backed button. ImageRenderer substitutes a
            // placeholder; a real hosting window exercises the actual control.
            let host = UIHostingController(rootView: controls)
            host.safeAreaRegions = []
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(150))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 150))
            host.view.frame = CGRect(origin: .zero, size: size); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, width, accuracy: 1)
            XCTAssertLessThan(image.size.height, 150, "Controls must leave room for the footage")
            let attachment = XCTAttachment(image: image); attachment.name = "Player frame review controls \(Int(width))pt"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor
    func testUnifiedTrackingSheetRendersOnPhoneWithoutTouchingProjectData() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldWindow?.makeKey() }
        var track = motion(); track.gaps = [4...5]; track.hidesUncertainPositions = true
        let player = AnalysisTrackingLibrary.Player(id: UUID(), name: "Blue player 9", motion: track)
        let view = AnalysisPlayerTrackingSheet(player: player, clipRange: 0...10, time: 4.5, isBusy: false,
            includeBodyMasks: .constant(false), trackWholeClip: {}, trackToEnd: {}, trackBackToStart: {}, fillGap: {},
            seek: { _ in }, bridge: { _ in },
            smoothing: { _ in }, rename: { _ in })
        let host = UIHostingController(rootView: view)
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Unified tracking and manual correction sheet"
        attachment.lifetime = .keepAlways; add(attachment)
        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host.view).max { $0.contentSize.height < $1.contentSize.height })
        scroll.setContentOffset(CGPoint(x: 0, y: min(650, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let identityImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let identity = XCTAttachment(image: identityImage); identity.name = "Player identity views and number controls"
        identity.lifetime = .keepAlways; add(identity)
    }

    @MainActor
    func testRedoRangeControlsRenderOnPhone() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let view = AnalysisPlayerTrackingReplacementSheet(request: .init(id: UUID(), name: "Blue player 9", time: 3),
            clipRange: 0...33, frameRate: 30, replace: { _, _ in })
        let host = UIHostingController(rootView: view)
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Redo range and whole clip controls"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func motion(from start: Double = 0, to end: Double = 10) -> PlayerMotion {
        PlayerMotion(samples: stride(from: start, through: end, by: 0.05).map {
            .init(time: $0, box: .init(x: 0.2 + $0 * 0.01, y: 0.3, width: 0.05, height: 0.15))
        }, smoothing: 0, trackID: UUID())
    }

    func testEarlyFailedRepairKeepsBothSidesAndLaterGapsExactly() throws {
        var original = motion(); original.gaps = [7...8]; original.lostAt = 9.8
        var repair = motion(from: 2, to: 3); repair.lostAt = 3.01
        repair.samples = repair.samples.map { .init(time: $0.time, box: $0.box.offsetBy(dx: 0.02, dy: 0)) }
        let combined = original.continuing(with: repair, from: 2)
        XCTAssertEqual(combined.samples.filter { $0.time < 2 }, original.samples.filter { $0.time < 2 })
        XCTAssertEqual(combined.samples.filter { $0.time > repair.samples.last!.time }, original.samples.filter { $0.time > repair.samples.last!.time })
        XCTAssertEqual(combined.box(at: 6), original.box(at: 6))
        XCTAssertEqual(combined.lostAt, original.lostAt)
        XCTAssertNil(combined.box(at: 7.5))
        XCTAssertNotNil(combined.box(at: 9))
        XCTAssertEqual(combined.trackID, original.trackID)
        XCTAssertEqual(combined, try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(combined)))
    }

    func testEarlierRepairCannotOverwriteLaterManualCorrection() {
        var original = motion(); original.correctionTimes = [0, 6]
        let repair = motion(from: 2, to: 9)
        let result = original.continuing(with: repair, from: 2)
        XCTAssertEqual(original.repairEnd(from: 2, to: 10), 6)
        XCTAssertEqual(result.correctionTimes, [0, 2, 6])
        XCTAssertEqual(result.samples.filter { $0.time >= 6 }, original.samples.filter { $0.time >= 6 })
        XCTAssertEqual(result.repairEnd(from: 1, to: 10), 2)
    }

    func testExtendingTrackKeepsAbsenceHiddenAndReplacesTerminalLoss() {
        var original = motion(from: 0, to: 2); original.lostAt = 2.01
        let result = original.continuing(with: motion(from: 4, to: 6), from: 4)
        XCTAssertNil(result.box(at: 3))
        XCTAssertNil(result.lostAt)
        XCTAssertNotNil(result.box(at: 5))
    }

    func testBackfillingBeforeTrackDoesNotInventMotionBetweenRuns() {
        var original = motion(from: 6, to: 10); original.lostAt = 10.01
        let result = original.continuing(with: motion(from: 1, to: 2), from: 1)
        XCTAssertNil(result.box(at: 4))
        XCTAssertEqual(result.samples.filter { $0.time >= 6 }, original.samples)
        XCTAssertEqual(result.lostAt, 10.01)
    }

    func testEmptyRepairIsNoOpAndOldLostSamplesStayHidden() {
        var original = motion(); original.lostAt = 2
        XCTAssertEqual(original.continuing(with: PlayerMotion(samples: []), from: 1), original)
        let result = original.continuing(with: motion(from: 3, to: 4), from: 3)
        XCTAssertNil(result.box(at: 2.5))
        XCTAssertNotNil(result.box(at: 3.5))
        XCTAssertNil(result.box(at: 6), "Raw samples previously marked lost must not become confirmed")
    }


    func testFocusedSearchStaysInImageAtEdgesAndRejectsOffscreenTarget() {
        for x in [0.0, 0.5, 0.99] {
            let region = PlayerTrackingSearch.region(around: .init(x: x, y: 0.9, width: 0.01, height: 0.03))!
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(region))
            XCTAssertEqual(region.width, 0.18, accuracy: 0.001)
        }
        XCTAssertNil(PlayerTrackingSearch.region(around: .init(x: 2, y: 2, width: 0.01, height: 0.03)))
    }

    func testGroundContactBridgesShortGapsAndDoesNotFollowLiftedFootJitter() {
        var source = motion(from: 0, to: 2)
        source.samples = source.samples.enumerated().map { index, sample in
            var sample = sample
            sample.box.origin.y += index.isMultiple(of: 2) ? -0.01 : 0
            return sample
        }
        let rawRange = (10...20).map { source.box(at: Double($0) * 0.05)!.maxY }
        let groundRange = (10...20).map { source.groundPoint(at: Double($0) * 0.05)!.y }
        XCTAssertLessThan(groundRange.max()! - groundRange.min()!, rawRange.max()! - rawRange.min()!)
        XCTAssertGreaterThan(source.groundPoint(at: 0.5)!.y, source.box(at: 0.5)!.maxY)
        source.gaps = [0.8...1.2]
        XCTAssertNotNil(source.groundPoint(at: 1), "Grounded effects also bridge short, bounded gaps")
        source.gaps = [0.6...1.3]
        XCTAssertNil(source.groundPoint(at: 1))
        XCTAssertNotNil(source.groundPoint(at: 1.5))
    }

    func testSmoothingDoesNotPullAnExplicitCorrectionTowardTheOldPosition() {
        var source = motion(from: 0, to: 4)
        source.smoothing = 1; source.correctionTimes = [0, 2]
        source.samples = source.samples.map { sample in
            .init(time: sample.time, box: sample.box.offsetBy(dx: sample.time >= 2 ? 0.2 : 0, dy: 0))
        }
        for time in [1.9, 2, 2.1] {
            let expected = source.samples.first { abs($0.time - time) < 0.001 }!.box
            XCTAssertEqual(source.box(at: time)!.midX, expected.midX, accuracy: 0.001)
        }
    }
}

extension PlayerTrackRepairTests {
    func testExplicitRedoClearsManualBoundariesOnlyInsideItsRange() throws {
        var saved = motion()
        saved.trackID = UUID(); saved.correctionTimes = [0, 3, 4, 7]
        saved.anchors = [2, 3.1, 3.2, 5, 8]
        saved.identity = PlayerIdentityMemory(); saved.identity?.number.manual = "9"
        let before = saved
        let prepared = saved.clearingTracking(in: 3...6)
        XCTAssertEqual(prepared.samples.filter { $0.time < 3 || $0.time >= 6 }, before.samples.filter { $0.time < 3 || $0.time >= 6 })
        XCTAssertEqual(prepared.anchors, [2, 8]); XCTAssertEqual(prepared.correctionTimes, [0, 7])
        XCTAssertEqual(prepared.identity, saved.identity); XCTAssertEqual(prepared.trackID, saved.trackID)
        XCTAssertEqual(prepared.repairEnd(from: 3, to: 6), 6, "Adjacent manual picks no longer stop an explicit redo")
        let stopped = prepared.continuing(with: motion(from: 3, to: 4), from: 3)
        XCTAssertNotNil(stopped.trackingSeed(at: 3.5)); XCTAssertNil(stopped.trackingSeed(at: 5))
        XCTAssertNotNil(stopped.trackingSeed(at: 7))
        let all = saved.clearingTracking(in: 0...10)
        XCTAssertTrue(all.samples.allSatisfy { $0.time == 10 }); XCTAssertTrue(all.anchors?.isEmpty == true)
        XCTAssertTrue(all.correctionTimes?.isEmpty == true)
        XCTAssertEqual(all.identity, saved.identity)
    }

    func testRedoCanCrossOldTerminalLossWithoutExposingStaleFuture() throws {
        var saved = motion(); saved.lostAt = 2
        let prepared = saved.clearingTracking(in: 3...6)
        let repaired = prepared.continuing(with: motion(from: 3, to: 5), from: 3)
        XCTAssertNil(repaired.trackingSeed(at: 2.5))
        XCTAssertNotNil(repaired.trackingSeed(at: 4))
        XCTAssertNil(repaired.trackingSeed(at: 7))
    }

    func testFullRedoFromMiddleJoinsBothDirectionsWithoutAnArtificialSeedGap() throws {
        var saved = motion(); saved.anchors = [1, 2, 3, 4, 6, 7, 8, 9]
        var prepared = saved.clearingTracking(in: 0...10)
        prepared.place(try XCTUnwrap(saved.box(at: 5)), at: 5)
        let backward = prepared.prepending(motion(from: 0, to: 5), seed: 5)
        let complete = backward.continuing(with: motion(from: 5, to: 9.95), from: 5)
        XCTAssertNotNil(complete.trackingSeed(at: 1))
        XCTAssertNotNil(complete.trackingSeed(at: 4.99), "Both sides meet at the confirmed seed; do not leave the cleared range over that join")
        XCTAssertNotNil(complete.trackingSeed(at: 7))
        XCTAssertEqual(complete.trackID, saved.trackID)
        XCTAssertEqual(complete.correctionTimes, [5])
        XCTAssertTrue(complete.anchors?.isEmpty ?? true)
    }

    func testFixInvalidatesOnlyAutomaticSectionAndKeepsNextManualBoundary() {
        var saved = motion()
        saved.correctionTimes = [0, 7]; saved.anchors = [8]
        let prepared = saved.preparingCorrection(at: 3, direction: .forward)
        XCTAssertFalse(prepared.samples.contains { $0.time > 3 && $0.time < 7 })
        XCTAssertEqual(prepared.samples.filter { $0.time >= 7 }, saved.samples.filter { $0.time >= 7 })
        let partial = motion(from: 3, to: 4)
        let repaired = prepared.continuing(with: partial, from: 3)
        XCTAssertNil(repaired.trackingSeed(at: 5), "Stopping a fix cannot restore the wrong old automatic track")
        XCTAssertNotNil(repaired.trackingSeed(at: 8))
        let backward = saved.preparingCorrection(at: 6, direction: .backward)
        XCTAssertFalse(backward.samples.contains { $0.time > 0 && $0.time < 6 })
        XCTAssertEqual(backward.samples.filter { $0.time >= 6 }, saved.samples.filter { $0.time >= 6 })
    }

    func testTrackFromMissingFrameRequiresPickInsteadOfMovingPlayhead() {
        var saved = motion(); saved.gaps = [3...4]; saved.lostAt = 7
        XCTAssertNil(saved.trackingSeed(at: 3.5))
        XCTAssertNil(saved.trackingSeed(at: 8))
        XCTAssertNotNil(saved.trackingSeed(at: 2))
    }

    @MainActor
    func testReviewSelectionsAdvanceActualVideoAndKeepDistinctManualFrames() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        let playback = EditorPlayback(player: AVPlayer(url: url), duration: 33)
        defer { playback.stop() }
        let review = PlayerFrameReview(range: 0...33, frameRate: 30)
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 33)
        var track = motion(); track.trackID = UUID(); clip.storePlayerTrack(track)
        let id = try XCTUnwrap(track.trackID)
        playback.commitSeek(3)
        func waitForSeek() async throws {
            for _ in 0..<200 {
                if !playback.isSeeking { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Frame seek did not complete")
        }
        try await waitForSeek()
        let box = CGRect(x: 0.3, y: 0.4, width: 0.04, height: 0.15)
        for frame in 90..<100 {
            XCTAssertEqual(playback.currentSeconds, Double(frame) / 30, accuracy: 0.002)
            XCTAssertTrue(clip.placePlayerSample(trackID: id, box: box, at: playback.currentSeconds))
            playback.commitSeek(try XCTUnwrap(review.next(after: playback.currentSeconds)))
            try await waitForSeek()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertEqual(playback.player.currentTime().seconds, Double(frame + 1) / 30, accuracy: 0.002)
        }
        let samples = try XCTUnwrap(clip.trackingLibrary?.players.first?.motion)
        XCTAssertEqual(samples.anchors?.filter { $0 >= 3 && $0 < 10.0 / 3 }.count, 10)
    }
}


extension PlayerTrackRepairTests {
    func testEffectBindingsRestoreTheSameConfirmedIdentityBeforeTracking() throws {
        let id = UUID(), seed = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.3)
        var memory = PlayerIdentityMemory()
        let blue = PlayerJerseySignature(colors: [SIMD3<Float>(0.1, 0.2, 0.8)])
        memory.confirm(PlayerObservation(box: seed, jersey: blue, print: [1, 0], time: 2), view: .back)
        memory.number.manual = "9"
        let source = PlayerMotion(samples: [.init(time: 2, box: seed)], trackID: id)
        let library = AnalysisTrackingLibrary(players: [.init(id: id, name: "Nine", motion: source, identity: memory)])
        let effect = try XCTUnwrap(source.bound(at: 2))
        XCTAssertNil(effect.identity)
        let resumed = library.resuming(effect)
        XCTAssertEqual(resumed.identity, memory)
        XCTAssertEqual(resumed.jerseyProfile?.trusted?.count, 1)
        XCTAssertEqual(resumed.referenceBox, effect.referenceBox)
        XCTAssertEqual(resumed.samples, effect.samples)
        var unrelated = effect; unrelated.trackID = UUID()
        XCTAssertEqual(library.resuming(unrelated), unrelated)
    }
}


extension PlayerTrackRepairTests {
    func testTapInsidePlayerCannotBeStolenByPaddedNarrowNeighbour() {
        // Actual 3 s soccer detections include a thin duplicate just to the right.
        let player = CGRect(x: 0.381, y: 0.548, width: 0.0243, height: 0.0735)
        let narrow = CGRect(x: 0.400, y: 0.533, width: 0.0073, height: 0.0937)
        XCTAssertEqual(PlayerSelection.box(at: CGPoint(x: 0.394, y: 0.586), among: [narrow, player], aspectRatio: 16 / 9), player)
        XCTAssertEqual(PlayerSelection.box(at: CGPoint(x: 0.379, y: 0.586), among: [narrow, player], aspectRatio: 16 / 9), player)
        XCTAssertNil(PlayerSelection.box(at: CGPoint(x: 0.8, y: 0.7), among: [player], aspectRatio: 16 / 9))
    }
}
