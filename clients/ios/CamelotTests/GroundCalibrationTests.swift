import XCTest
@testable import Camelot

final class GroundCalibrationTests: XCTestCase {
    func testCroppedFeetAndDisplayHoldsNeverProduceMeasuredSpeed() {
        let calibration = GroundCalibration(mode: .localScale, points: [.zero, .init(x: 1, y: 0)],
                                             lengthMeters: 10, referenceTime: 0, imageAspectRatio: 1, fixedCamera: true)
        let samples = (0...30).map { i in
            PlayerMotionSample(time: Double(i) / 30, box: .init(x: 0.3, y: 0.8, width: 0.06, height: 0.2))
        }
        XCTAssertNil(calibration.speed(of: PlayerMotion(samples: samples), at: 0.5))
    }

    func testLocalScaleCorrectsAspectRatio() throws {
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)],
                                             lengthMeters: 10, referenceTime: 0, imageAspectRatio: 2,
                                             fixedCamera: true)
        XCTAssertTrue(calibration.valid)
        XCTAssertEqual(try XCTUnwrap(calibration.distance(from: .init(x: 0.2, y: 0.2), to: .init(x: 0.3, y: 0.2), at: 0)), 5, accuracy: 0.0001)
        XCTAssertTrue(calibration.isApproximate)
    }

    func testPerspectiveRectangleMapsKnownDistancesAndCircle() throws {
        let corners: [CGPoint] = [.init(x: 0.25, y: 0.15), .init(x: 0.75, y: 0.15),
                                   .init(x: 0.9, y: 0.9), .init(x: 0.1, y: 0.9)]
        let calibration = GroundCalibration(mode: .plane, points: corners, lengthMeters: 100,
                                             widthMeters: 50, referenceTime: 0, imageAspectRatio: 1,
                                             fixedCamera: true)
        XCTAssertTrue(calibration.valid)
        let near = try XCTUnwrap(calibration.imagePoint(.init(x: 50, y: 25), at: 0))
        XCTAssertEqual(calibration.worldPoint(near, at: 0)?.x ?? -1, 50, accuracy: 0.0001)
        XCTAssertEqual(calibration.worldPoint(near, at: 0)?.y ?? -1, 25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibration.distance(from: corners[0], to: corners[1], at: 0)), 100, accuracy: 0.0001)
        XCTAssertEqual(calibration.circle(center: near, radiusMeters: 2, at: 0)?.count, 32)
    }

    func testCameraPanCancelsForStationaryPlayerAndUnknownCoverageIsNil() throws {
        let camera = AnnotationCameraMotion(samples: [
            .init(time: 0, transform: .identity),
            .init(time: 1, transform: .init(values: [1, 0, 0.1, 0, 1, 0, 0, 0, 1]))
        ])
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)],
                                             lengthMeters: 10, referenceTime: 0, imageAspectRatio: 1,
                                             cameraMotion: camera)
        let reference = try XCTUnwrap(calibration.imagePoint(.init(x: 5, y: 0), at: 0))
        XCTAssertEqual(calibration.worldPoint(.init(x: reference.x + 0.1, y: reference.y), at: 1)?.x ?? -1, 5, accuracy: 0.0001)
        XCTAssertNil(calibration.worldPoint(reference, at: 2))
        let frozen = try XCTUnwrap(calibration.frozen(at: 1))
        XCTAssertTrue(frozen.fixedCamera)
        XCTAssertNil(frozen.cameraMotion)
        XCTAssertEqual(frozen.worldPoint(.init(x: reference.x + 0.1, y: reference.y), at: 4)?.x ?? -1, 5, accuracy: 0.0001)
        XCTAssertNil(calibration.frozen(at: 2))
    }

    func testSpeedUsesWorldFeetAndRejectsGaps() throws {
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.zero, .init(x: 1, y: 0)], lengthMeters: 10,
                                             referenceTime: 0, imageAspectRatio: 1, fixedCamera: true)
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map {
            PlayerMotionSample(time: $0, box: CGRect(x: 0.2 + $0 * 0.1, y: 0.2, width: 0.05, height: 0.1))
        }
        let motion = PlayerMotion(samples: samples, gaps: nil, smoothing: 0)
        XCTAssertEqual(calibration.speed(of: motion, at: 0.5) ?? -1, 1, accuracy: 0.001)
        var gapped = motion; gapped.gaps = [0.45...0.55]
        XCTAssertNil(calibration.speed(of: gapped, at: 0.5))
    }

    func testSpeedRejectsCameraCutAtCurrentTimestamp() throws {
        let camera = AnnotationCameraMotion(samples: [
            .init(time: 0, transform: .identity), .init(time: 1, transform: .identity)
        ], lostAt: 0.5)
        let calibration = GroundCalibration(mode: .localScale, points: [.zero, .init(x: 1, y: 0)],
                                             lengthMeters: 10, referenceTime: 0, imageAspectRatio: 1,
                                             cameraMotion: camera)
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map {
            PlayerMotionSample(time: $0, box: CGRect(x: $0 * 0.1, y: 0.2, width: 0.05, height: 0.1))
        }
        XCTAssertNil(calibration.speed(of: PlayerMotion(samples: samples, smoothing: 0), at: 0.5))
    }

    func testCodableRoundTripAndInvalidHorizon() throws {
        let calibration = GroundCalibration(mode: .plane,
                                             points: [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)],
                                             lengthMeters: 10, widthMeters: 5, referenceTime: 0,
                                             imageAspectRatio: 1, fixedCamera: true)
        XCTAssertEqual(try JSONDecoder().decode(GroundCalibration.self,
                                                 from: JSONEncoder().encode(calibration)), calibration)
        var invalid = calibration
        invalid.points[2] = invalid.points[1]
        XCTAssertFalse(invalid.valid)
        XCTAssertNil(invalid.worldPoint(.init(x: 0.5, y: 0.5), at: 0))
    }

    func testGroundBelowImageCenterKeepsCorrectHorizonBranch() throws {
        let calibration = GroundCalibration(mode: .plane,
            points: [.init(x: 0.4, y: 0.7), .init(x: 0.6, y: 0.7), .init(x: 0.8, y: 0.9), .init(x: 0.2, y: 0.9)],
            lengthMeters: 10, widthMeters: 10, referenceTime: 0, imageAspectRatio: 1, fixedCamera: true)
        XCTAssertTrue(calibration.valid)
        XCTAssertNotNil(calibration.worldPoint(.init(x: 0.5, y: 0.8), at: 0))
        XCTAssertNil(calibration.worldPoint(.init(x: 0.5, y: 0.5), at: 0))
        XCTAssertNil(calibration.imagePoint(.init(x: 5, y: 30), at: 0))
    }
}
