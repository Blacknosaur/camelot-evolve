import XCTest
@testable import Camelot

final class FieldPreviewTests: XCTestCase {
    func testFieldPreviewFollowsCameraAndPreviewViewportWithoutMutatingCalibration() throws {
        let camera = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity),
            .init(time: 1, transform: .init(values: [1, 0, 0.08, 0, 1, -0.03, 0, 0, 1]))])
        var ground = GroundCalibration(mode: .plane,
            points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.3), .init(x: 0.8, y: 0.9), .init(x: 0.2, y: 0.9)],
            lengthMeters: 68, widthMeters: 105, referenceTime: 0, imageAspectRatio: 16.0 / 9, cameraMotion: camera)
        ground.fieldReference = .init(landmark: .fullPitch)
        let original = ground
        let frame = CGRect(x: -40, y: 20, width: 640, height: 360)
        let before = AnalysisFieldPreviewGeometry.make(calibration: ground, time: 0, frame: frame)
        let after = AnalysisFieldPreviewGeometry.make(calibration: ground, time: 1, frame: frame)
        XCTAssertFalse(before.calibratedPath.isEmpty)
        XCTAssertNil(after.status)
        XCTAssertEqual(after.referencePath.boundingBox.minX - before.referencePath.boundingBox.minX, 0.08 * frame.width, accuracy: 0.001)
        XCTAssertEqual(after.referencePath.boundingBox.minY - before.referencePath.boundingBox.minY, -0.03 * frame.height, accuracy: 0.001)
        XCTAssertEqual(ground, original)
    }

    func testMissingCalibrationExplainsHowToStart() {
        let result = AnalysisFieldPreviewGeometry.make(calibration: nil, time: 0, frame: .init(x: 0, y: 0, width: 160, height: 90))
        XCTAssertEqual(result.status, "Set up field calibration in Measure")
        XCTAssertTrue(result.referencePath.isEmpty)
    }

    func testCustomReferenceUsesSavedPoseWithoutFieldTemplate() {
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.3)],
                                             lengthMeters: 10, referenceTime: 0,
                                             imageAspectRatio: 16.0 / 9.0, fixedCamera: true)
        let result = AnalysisFieldPreviewGeometry.make(calibration: calibration, time: 0,
                                                        frame: .init(x: 0, y: 0, width: 160, height: 90))
        XCTAssertNil(result.status)
        XCTAssertFalse(result.referencePath.isEmpty)
        XCTAssertTrue(result.calibratedPath.isEmpty)
    }

    func testCameraCoverageFailureHidesStaleLines() {
        let camera = AnnotationCameraMotion(samples: [
            .init(time: 0, transform: .identity), .init(time: 1, transform: .identity)
        ])
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.zero, .init(x: 1, y: 0)], lengthMeters: 10,
                                             referenceTime: 0, imageAspectRatio: 1, cameraMotion: camera)
        let result = AnalysisFieldPreviewGeometry.make(calibration: calibration, time: 2,
                                                        frame: .init(x: 0, y: 0, width: 160, height: 90))
        XCTAssertTrue(result.status?.contains("camera tracking") == true)
        XCTAssertTrue(result.referencePath.isEmpty)
    }
}
