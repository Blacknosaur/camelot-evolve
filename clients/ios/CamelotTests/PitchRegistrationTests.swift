import XCTest
import CoreGraphics
import UIKit
@testable import Camelot

/// Synthetic pitch frames with a known homography. These prove the snapping
/// geometry and its quality report; they are not evidence about real footage.
final class PitchRegistrationTests: XCTestCase {
    private let truth: [CGPoint] = [.init(x: 0.18, y: 0.16), .init(x: 0.83, y: 0.15), .init(x: 0.98, y: 0.92), .init(x: 0.03, y: 0.94)]

    private func calibration(corners: [CGPoint], landmark: GroundLandmark = .fullPitch) -> GroundCalibration {
        var result = GroundCalibration(mode: .plane, points: corners, lengthMeters: landmark == .fullPitch ? 68 : landmark.defaultLengthMeters,
                                       widthMeters: landmark == .fullPitch ? 105 : landmark.defaultWidthMeters,
                                       referenceTime: 0, imageAspectRatio: 16 / 9, fixedCamera: true)
        result.fieldReference = .init(landmark: landmark, pitchLength: 105, pitchWidth: 68)
        return result
    }

    /// Green turf with noise, players and painted lines whose width shrinks
    /// with distance, drawn from the ground-truth calibration.
    private func frame(_ calibration: GroundCalibration, size: CGSize = .init(width: 1920, height: 1080), lines: Bool = true) -> CGImage {
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { renderer in
            let context = renderer.cgContext
            var generator = SystemRandomNumberGenerator()
            UIColor(red: 0.22, green: 0.52, blue: 0.2, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<4000 {
                let x = CGFloat.random(in: 0..<size.width, using: &generator), y = CGFloat.random(in: 0..<size.height, using: &generator)
                UIColor(red: 0.2, green: CGFloat.random(in: 0.42...0.6, using: &generator), blue: 0.18, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
            // Stands above the far touchline: bright, not turf.
            UIColor(white: 0.75, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.12))
            guard lines else { return }
            let frame = CGRect(origin: .zero, size: size)
            let path = GroundFieldOverlay.path(calibration: calibration, frame: frame)
            context.setStrokeColor(UIColor.white.cgColor); context.setLineCap(.round)
            for width in stride(from: CGFloat(2), through: 7, by: 1) {
                // Approximate perspective thickness: fatter near the bottom of the frame.
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: size.height * (width - 2) / 5, width: size.width, height: size.height / 5 + 2))
                context.addPath(path); context.setLineWidth(width); context.strokePath()
                context.restoreGState()
            }
            // A few white shirts on the turf should not attract the snap.
            UIColor.white.setFill()
            for x in [0.3, 0.55, 0.7] { context.fill(CGRect(x: size.width * x, y: size.height * 0.6, width: 22, height: 40)) }
        }
        return image.cgImage!
    }

    private func perturbed(_ corners: [CGPoint], by pixels: CGFloat) -> [CGPoint] {
        let offsets: [CGPoint] = [.init(x: 1, y: -0.6), .init(x: -0.8, y: 0.9), .init(x: 0.5, y: 1), .init(x: -1, y: -0.4)]
        return zip(corners, offsets).map { CGPoint(x: $0.x + $1.x * pixels / 1920, y: $0.y + $1.y * pixels / 1080) }
    }

    private func cornerError(_ corners: [CGPoint]) -> Double {
        zip(corners, truth).map { hypot(Double($0.x - $1.x) * 1920, Double($0.y - $1.y) * 1080) }.max() ?? .infinity
    }

    func testSnapRecoversWholePitchFromRoughHandles() throws {
        let image = frame(calibration(corners: truth))
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        let rough = calibration(corners: perturbed(truth, by: 18))
        XCTAssertGreaterThan(cornerError(rough.points), 12)
        let result = try XCTUnwrap(PitchRegistration.snap(rough, evidence: evidence))
        XCTAssertLessThan(cornerError(result.calibration.points), 1.5, "Corners should land within about a source pixel")
        XCTAssertEqual(result.quality.grade, .good)
        XCTAssertLessThan(result.quality.residualPixels, 1.2)
        XCTAssertGreaterThan(result.quality.supportedLines, 6)
        XCTAssertTrue(result.calibration.valid)
        XCTAssertEqual(result.calibration.fieldReference?.landmark, .fullPitch)
        XCTAssertEqual(try JSONDecoder().decode(GroundCalibration.self, from: JSONEncoder().encode(result.calibration)), result.calibration)
    }

    func testSnapRefinesPartialPenaltyAreaReference() throws {
        let image = frame(calibration(corners: truth))
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        // The left penalty area corners in the same frame, from the truth plane.
        let plane = calibration(corners: truth)
        let box: [CGPoint] = [.init(x: (68 - 40.32) / 2, y: 0), .init(x: (68 + 40.32) / 2, y: 0),
                              .init(x: (68 + 40.32) / 2, y: 16.5), .init(x: (68 - 40.32) / 2, y: 16.5)]
        let exact = try box.map { try XCTUnwrap(plane.imagePoint($0, at: 0)) }
        let rough = calibration(corners: perturbed(exact, by: 14), landmark: .penaltyArea)
        let result = try XCTUnwrap(PitchRegistration.snap(rough, evidence: evidence))
        for (actual, expected) in zip(result.calibration.points, exact) {
            XCTAssertEqual(Double(actual.x) * 1920, Double(expected.x) * 1920, accuracy: 1.5)
            XCTAssertEqual(Double(actual.y) * 1080, Double(expected.y) * 1080, accuracy: 1.5)
        }
        XCTAssertNotEqual(result.quality.grade, .poor)
    }

    func testFlatTurfWithoutMarkingsIsReportedAsWeak() throws {
        let image = frame(calibration(corners: truth), lines: false)
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        let result = PitchRegistration.snap(calibration(corners: perturbed(truth, by: 10)), evidence: evidence)
        XCTAssertTrue(result == nil || result!.quality.grade == .poor)
    }

    func testTracedLinesReprojectOntoSnappedTemplateAndRefit() throws {
        let image = frame(calibration(corners: truth))
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        let rough = calibration(corners: perturbed(truth, by: 16))
        let kinds: [GroundPitchLine] = [.farTouch, .nearTouch, .halfway, .leftGoal, .leftBoxFront]
        // Trace the lines on the rough plane so the fit reproduces it exactly.
        let traced = try kinds.map { kind -> GroundLineObservation in
            let k = kind.coordinate(length: 105, width: 68)
            let world = kind.across ? [CGPoint(x: 68 * 0.3, y: 105 * k), CGPoint(x: 68 * 0.7, y: 105 * k)]
                                    : [CGPoint(x: 68 * k, y: 105 * 0.2), CGPoint(x: 68 * k, y: 105 * 0.6)]
            return .init(kind: kind, points: try world.map { try XCTUnwrap(rough.imagePoint($0, at: 0)) })
        }
        let fit = try XCTUnwrap(GroundLineAlignment.fit(traced, length: 105, width: 68, time: 0, aspect: 16 / 9, fixed: true))
        let snapped = try XCTUnwrap(PitchRegistration.snap(fit.calibration, evidence: evidence))
        XCTAssertLessThan(cornerError(snapped.calibration.points), 1.5)
        let moved = try XCTUnwrap(PitchRegistration.reproject(traced, onto: snapped.calibration, pitchLength: 105, pitchWidth: 68))
        let refit = try XCTUnwrap(GroundLineAlignment.fit(moved, length: 105, width: 68, time: 0, aspect: 16 / 9, fixed: true))
        for (a, b) in zip(refit.calibration.points, snapped.calibration.points) {
            XCTAssertEqual(Double(a.x) * 1920, Double(b.x) * 1920, accuracy: 0.05)
            XCTAssertEqual(Double(a.y) * 1080, Double(b.y) * 1080, accuracy: 0.05)
        }
    }

    func testSnapRejectsReferencesWithoutAPlane() throws {
        let image = frame(calibration(corners: truth))
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        let local = GroundCalibration(mode: .localScale, points: [.zero, .init(x: 0.5, y: 0)], lengthMeters: 10, referenceTime: 0, imageAspectRatio: 16 / 9)
        XCTAssertNil(PitchRegistration.snap(local, evidence: evidence))
        var custom = calibration(corners: truth); custom.fieldReference = nil
        XCTAssertNil(PitchRegistration.snap(custom, evidence: evidence))
    }

    func testEvidenceAndSnapStayInteractive() throws {
        let image = frame(calibration(corners: truth))
        let start = Date()
        let evidence = try XCTUnwrap(PitchRegistration.Evidence(image: image))
        let prepared = Date().timeIntervalSince(start)
        let result = PitchRegistration.snap(calibration(corners: perturbed(truth, by: 12)), evidence: evidence)
        let total = Date().timeIntervalSince(start)
        XCTAssertNotNil(result)
        print("PITCH_SNAP evidence=\(prepared)s total=\(total)s")
        XCTAssertLessThan(total, 6, "Snapping a 1080p frame must stay interactive even unoptimized")
    }
}
