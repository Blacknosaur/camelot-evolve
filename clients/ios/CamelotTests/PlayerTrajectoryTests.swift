import XCTest
import UIKit
@testable import Camelot

final class PlayerTrajectoryTests: XCTestCase {
    @MainActor
    func testTrajectoryIsVisibleAndUsesSamePreviewAndExportRenderer() {
        let mark = trail(), frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func render(_ marks: [AnalysisAnnotation], editing: Bool = false) -> UIImage {
            UIGraphicsImageRenderer(size: frame.size, format: format).image { renderer in
                UIColor.black.setFill(); renderer.fill(frame)
                AnnotationRenderer.draw(marks, time: 5, in: renderer.cgContext, frame: frame, editing: editing)
            }
        }
        let output = render([mark])
        XCTAssertNotEqual(output.pngData(), render([]).pngData())
        XCTAssertEqual(output.pngData(), render([mark], editing: true).pngData())
        var pastOnly = mark; pastOnly.trajectoryStyle?.futureSeconds = 0
        XCTAssertNotEqual(output.pngData(), render([pastOnly]).pngData())
        var hidden = mark; hidden.isHidden = true
        XCTAssertEqual(render([hidden]).pngData(), render([]).pngData())
        let attachment = XCTAttachment(image: output)
        attachment.name = "Confirmed trajectory: solid past and dashed future"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func trail() -> AnalysisAnnotation {
        let samples = (0...100).map { index in
            PlayerMotionSample(time: Double(index) / 10, box: CGRect(x: Double(index) / 200, y: 0.3, width: 0.04, height: 0.1))
        }
        var mark = AnalysisAnnotation(tool: .trajectory, points: [samples[0].box.origin, .init(x: 0.04, y: 0.4)], start: 0, end: 10)
        mark.playerMotion = .init(samples: samples, smoothing: 0, trackID: UUID())
        mark.trajectoryStyle = .init(pastSeconds: 2, futureSeconds: 3)
        return mark
    }

    func testPastAndFutureUseConfirmedMovementAndIndependentDurations() throws {
        var mark = trail()
        let past = try XCTUnwrap(PlayerTrajectory.paths(mark: mark, time: 5, future: false).first)
        let future = try XCTUnwrap(PlayerTrajectory.paths(mark: mark, time: 5, future: true).first)
        XCTAssertEqual(try XCTUnwrap(past.first).x, 0.17, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(past.last).x, 0.27, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(future.first).x, 0.27, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(future.last).x, 0.42, accuracy: 0.0001)
        XCTAssertTrue(PlayerTrajectory.paths(mark: mark, time: 10, future: true).isEmpty)
        XCTAssertTrue(PlayerTrajectory.paths(mark: mark, time: 10.01, future: false).isEmpty)
        mark.trajectoryStyle?.pastSeconds = 0
        XCTAssertTrue(PlayerTrajectory.paths(mark: mark, time: 5, future: false).isEmpty)
        XCTAssertFalse(PlayerTrajectory.paths(mark: mark, time: 5, future: true).isEmpty)
    }

    func testTrackingGapsNeverGetJoinedEvenBetweenRenderedSamples() {
        var mark = trail()
        mark.playerMotion?.gaps = [6.011...6.019]
        let paths = PlayerTrajectory.paths(mark: mark, time: 5, future: true)
        XCTAssertEqual(paths.count, 2)
        for path in paths {
            XCTAssertFalse(path.first!.x < 0.32055 && path.last!.x > 0.32095)
        }
        mark.playerMotion?.lostAt = 6
        XCTAssertLessThan(PlayerTrajectory.paths(mark: mark, time: 5, future: true).flatMap { $0 }.map(\.x).max()!, 0.32)
        XCTAssertTrue(PlayerTrajectory.paths(mark: mark, time: 6.015, future: false).isEmpty)
    }

    func testCameraCompensationCancelsCameraPanAndStopsAtCameraCoverage() throws {
        var mark = trail()
        mark.trajectoryCameraMotion = .init(samples: (0...80).map { index in
            .init(time: Double(index) / 10, transform: .init(values: [1, 0, Double(index) / 200, 0, 1, 0, 0, 0, 1]))
        }, trackID: UUID())
        for future in [false, true] {
            let points = PlayerTrajectory.paths(mark: mark, time: 5, future: future).flatMap { $0 }
            XCTAssertFalse(points.isEmpty)
            for point in points { XCTAssertEqual(point.x, 0.27, accuracy: 0.0001) }
        }
        XCTAssertTrue(PlayerTrajectory.paths(mark: mark, time: 9, future: false).isEmpty)
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
    }

    func testTrajectoryReusesPlayerAndCameraTracksAndReceivesCorrections() throws {
        let mark = trail(), source = try XCTUnwrap(mark.playerMotion)
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        clip.storePlayerTrack(source)
        let camera = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity), .init(time: 10, transform: .identity)], trackID: UUID())
        clip.storeCameraTrack(camera)
        var options = AnalysisPlayerEffects(); options.trajectory = true; options.label = true; options.spotlight = true
        _ = clip.applyPlayerEffects(options, replacing: [], box: try XCTUnwrap(source.box(at: 5)), motion: source, at: 5)
        XCTAssertEqual(clip.annotations.count, 4)
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        XCTAssertEqual(Set(clip.annotations.compactMap { $0.playerMotion?.trackID }), [source.trackID!])
        let index = try XCTUnwrap(clip.annotations.firstIndex { $0.tool == .trajectory })
        XCTAssertEqual(clip.annotations[index].trajectoryCameraMotion?.trackID, camera.trackID)
        let original = clip.annotations[index]
        clip.annotations[index].isLocked = true
        options.trajectory = false
        _ = clip.applyPlayerEffects(options, replacing: Set(clip.annotations.map(\.id)), box: source.samples[50].box, motion: source, at: 5)
        XCTAssertTrue(clip.annotations.contains { $0.id == original.id }, "Locked trail is retained")
        var corrected = source; corrected.lostAt = 7
        clip.storePlayerTrack(corrected)
        XCTAssertEqual(clip.annotations[index].playerMotion?.lostAt, 7)
        XCTAssertEqual(clip.annotations[index].points, original.points)
    }
}
