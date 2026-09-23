@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import Camelot

final class UnifiedCameraTrackingTests: XCTestCase {
    func testEquivalentCameraMatricesCannotCancelDuringInterpolation() throws {
        let shifted = CameraTransform(values: [1, 0, 0.12, 0, 1, -0.02, 0, 0, 1])
        let scaled = CameraTransform(values: shifted.values.map { $0 * -3 })
        let motion = AnnotationCameraMotion(samples: [.init(time: 0, transform: shifted), .init(time: 1, transform: scaled)])
        let expected = try XCTUnwrap(shifted.point(.init(x: 0.4, y: 0.6)))
        for t in [0.0, 0.25, 0.5, 1] {
            let actual = try XCTUnwrap(motion.transform(at: t)?.point(.init(x: 0.4, y: 0.6)))
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001)
        }
        XCTAssertNil(motion.transform(at: .nan))
        let invalid = AnnotationCameraMotion(samples: [.init(time: 0, transform: .init(values: [0, 0, 0, 0, 0, 0, 0, 0, 1]))])
        XCTAssertNil(invalid.transform(at: 0))
    }

    private func camera(from start: Double = 0, to end: Double = 10) -> AnnotationCameraMotion {
        .init(samples: [.init(time: start, transform: .identity),
                        .init(time: end, transform: .init(values: [1, 0, 0.1, 0, 1, -0.02, 0, 0, 1]))], trackID: UUID())
    }

    private func ground(at time: Double = 5, camera: AnnotationCameraMotion? = nil) -> GroundCalibration {
        .init(mode: .plane, points: [.init(x: 0.3, y: 0.4), .init(x: 0.7, y: 0.4),
                                    .init(x: 0.9, y: 0.9), .init(x: 0.1, y: 0.9)],
              lengthMeters: 68, widthMeters: 105, referenceTime: time, imageAspectRatio: 16.0 / 9, cameraMotion: camera)
    }

    func testLegacyPartialFieldReusesFullDrawingCameraIncludingBothEnds() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        let full = camera()
        var mark = AnalysisAnnotation(tool: .line, points: [.zero, .init(x: 1, y: 1)], start: 0, end: 10)
        mark.cameraMotion = full; clip.annotations = [mark]
        clip.groundCalibration = ground(camera: camera(from: 5))
        let originalPoints = clip.groundCalibration?.points
        clip.importAnnotationTracks()
        XCTAssertEqual(clip.groundCalibration?.cameraMotion?.trackID, full.trackID)
        XCTAssertEqual(clip.annotations.first?.cameraMotion?.trackID, full.trackID)
        XCTAssertEqual(clip.groundCalibration?.points, originalPoints)
        XCTAssertEqual(clip.cameraTrackingRange, 0...10)
        XCTAssertTrue(clip.hasFullCameraTrack)
        for time in [0.0, 5, 9.999, 10] {
            let preview = AnalysisFieldPreviewGeometry.make(calibration: clip.groundCalibration, time: time,
                                                            frame: .init(x: 0, y: 0, width: 640, height: 360))
            XCTAssertNil(preview.status)
            XCTAssertFalse(preview.referencePath.isEmpty)
        }
        let count = clip.trackingLibrary?.cameras.count
        clip.importAnnotationTracks()
        XCTAssertEqual(clip.trackingLibrary?.cameras.count, count)
        XCTAssertEqual(clip, try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip)))
    }

    func testFullPassRefreshesEveryBindingWithoutChangingAuthoredGeometry() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        for reference in [2.0, 4] {
            var mark = AnalysisAnnotation(tool: .line, points: [.init(x: 0.3, y: 0.4), .init(x: 0.6, y: 0.8)], start: 0, end: 10)
            mark.cameraMotion = camera(from: reference); mark.cameraMotion?.referenceTime = reference
            clip.annotations.append(mark)
        }
        var trail = AnalysisAnnotation(tool: .trajectory, points: [.zero], start: 0, end: 10)
        trail.trajectoryCameraMotion = camera(from: 3); clip.annotations.append(trail)
        clip.groundCalibration = ground(camera: camera(from: 5))
        let original = clip.annotations
        let shared = camera()
        XCTAssertTrue(clip.storeSharedCameraTrack(shared))
        for (index, reference) in [2.0, 4].enumerated() {
            let mark = clip.annotations[index]
            XCTAssertEqual(mark.points, original[index].points)
            XCTAssertEqual(mark.cameraMotion?.trackID, shared.trackID)
            XCTAssertEqual(mark.cameraMotion?.referenceTime, reference)
            let point = try XCTUnwrap(mark.cameraMotion?.transform(at: reference)?.point(mark.points[0]))
            XCTAssertEqual(point.x, mark.points[0].x, accuracy: 0.00001)
            XCTAssertEqual(point.y, mark.points[0].y, accuracy: 0.00001)
        }
        XCTAssertEqual(clip.annotations[2].trajectoryCameraMotion?.trackID, shared.trackID)
        XCTAssertEqual(clip.groundCalibration?.cameraMotion?.trackID, shared.trackID)
        clip.groundCalibration = ground(at: 8)
        clip.refreshSharedCameraBindings()
        XCTAssertEqual(clip.groundCalibration?.cameraMotion?.trackID, shared.trackID)
        XCTAssertEqual(clip.trackingLibrary?.cameras.count, 1, "Changing field reference reuses the pass")
    }

    func testShortFailedRetryPreservesLongerSharedTrack() {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        let full = camera(); clip.groundCalibration = ground()
        clip.storeSharedCameraTrack(full)
        var partial = camera(to: 3); partial.lostAt = 3.1
        XCTAssertFalse(clip.storeSharedCameraTrack(partial))
        XCTAssertEqual(clip.trackingLibrary?.sharedCamera, full)
        XCTAssertEqual(clip.groundCalibration?.cameraMotion, full)
        XCTAssertTrue(clip.hasFullCameraTrack)
    }

    func testGroundedShapeRemembersItsAuthoredFrameUntilCameraIsAvailable() {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        clip.groundCalibration = ground(at: 6)
        var mark = AnalysisAnnotation(tool: .rectangle, points: [.init(x: 0.3, y: 0.5), .init(x: 0.6, y: 0.8)], start: 0, end: 10)
        mark.setGrounding(true, at: 6, ground: clip.groundCalibration)
        XCTAssertEqual(mark.groundReferenceTime, 6)
        clip.annotations = [mark]; clip.storeSharedCameraTrack(camera())
        XCTAssertEqual(clip.annotations[0].cameraMotion?.referenceTime, 6)
        clip.startSeconds = 8
        XCTAssertEqual(clip.cameraTrackingRange, 6...10, "Trim retains the saved geometry reference")
    }

    func testLegacyFieldOnlyTrackIsPromotedOnceAndDecodesWithoutNewFields() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        var legacy = camera(); legacy.trackID = nil
        clip.groundCalibration = ground(camera: legacy)
        clip.importAnnotationTracks(); clip.importAnnotationTracks()
        XCTAssertEqual(clip.trackingLibrary?.cameras.count, 1)
        XCTAssertEqual(clip.trackingLibrary?.sharedCamera?.trackID, clip.id)
        XCTAssertTrue(clip.hasFullCameraTrack)
        let library = try JSONDecoder().decode(AnalysisTrackingLibrary.self, from: Data("{\"players\":[],\"cameras\":[]}".utf8))
        XCTAssertNil(library.sharedCameraID)
    }

    func testFieldAndDrawingUseSameEndpointToleranceButNeverCrossTrackingLoss() {
        var motion = camera()
        XCTAssertNotNil(motion.transform(at: 10.02))
        XCTAssertNotNil(ground(camera: motion).frozen(at: 10.02))
        motion.lostAt = 10.01
        XCTAssertNil(motion.transform(at: 10.02))
        XCTAssertNil(ground(camera: motion).frozen(at: 10.02))
        XCTAssertFalse(motion.covers(0...10.02))
    }

    @MainActor
    func testFullStressVideoCoverageWithMidClipFieldReference() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Requires fixture phone")
        let asset = AVURLAsset(url: url), began = Date()
        let duration = try await asset.load(.duration).seconds
        let motion = try await CameraMotionTracking.track(url: url, from: 0, to: duration) { _ in }
        print("SHARED_CAMERA fullDuration=\(duration) elapsed=\(Date().timeIntervalSince(began)) samples=\(motion.samples.count) lost=\(String(describing: motion.lostAt))")
        XCTAssertNil(motion.lostAt)
        XCTAssertEqual(try XCTUnwrap(motion.samples.first?.time), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(motion.samples.last?.time), duration, accuracy: 0.002)
        XCTAssertTrue(motion.covers(0...duration))
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: duration)
        clip.groundCalibration = ground(at: duration / 2)
        clip.storeSharedCameraTrack(motion)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [0, duration / 2, duration - 1 / 30] {
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let preview = AnalysisFieldPreviewGeometry.make(calibration: clip.groundCalibration, time: time, frame: frame)
            XCTAssertNil(preview.status)
            let rendered = UIGraphicsImageRenderer(size: frame.size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                renderer.cgContext.setStrokeColor(UIColor.cyan.cgColor); renderer.cgContext.setLineWidth(4)
                renderer.cgContext.addPath(preview.referencePath); renderer.cgContext.strokePath()
            }
            let attachment = XCTAttachment(image: rendered); attachment.name = "Shared camera draft plane at \(time)s"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertNil(AnalysisFieldPreviewGeometry.make(calibration: clip.groundCalibration, time: duration,
                                                       frame: .init(x: 0, y: 0, width: 640, height: 360)).status)
    }
}
