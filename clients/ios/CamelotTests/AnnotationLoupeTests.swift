import CoreGraphics
import CoreImage
import UIKit
import XCTest
@testable import Camelot

final class AnnotationLoupeTests: XCTestCase {
    func testLensMagnifiesCorrectSourceAndPreservesOutsidePixelsAndFade() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let base = CIImage(color: .blue).cropped(to: bounds)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)).composited(over: base)
        let geometry = try XCTUnwrap(AnnotationLoupeGeometry.make(style: .init(magnification: 3, diameter: 0.2, offset: .init(x: 0.5, y: 0)), focus: .init(x: 50, y: 50), frame: bounds, bounds: bounds))
        let context = CIContext()
        func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let rendered = AnnotationLoupeRenderer.image(source, geometry: geometry, bounds: bounds)
        XCTAssertGreaterThan(pixel(rendered, x: 150, y: 50)[0], 240, "The lens must sample red from its focus, not blue from its destination")
        XCTAssertGreaterThan(pixel(rendered, x: 190, y: 50)[2], 240, "Outside the lens is unchanged")
        let hidden = AnnotationLoupeRenderer.image(source, geometry: geometry, bounds: bounds, opacity: 0)
        XCTAssertGreaterThan(pixel(hidden, x: 150, y: 50)[2], 240)
        let faded = AnnotationLoupeRenderer.image(source, geometry: geometry, bounds: bounds, opacity: 0.5)
        XCTAssertGreaterThan(pixel(faded, x: 150, y: 50)[0], 80)
        XCTAssertGreaterThan(pixel(faded, x: 150, y: 50)[2], 80)
    }

    func testLoupeReusesPlayerTrackAndEditingUsesTranslationWithoutBoxScaling() throws {
        var motion = PlayerMotion(samples: [.init(time: 0, box: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.2)),
                                           .init(time: 0.1, box: .init(x: 0.4, y: 0.4, width: 0.15, height: 0.3))], smoothing: 0)
        motion.trackID = UUID()
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 1)
        clip.storePlayerTrack(motion)
        var options = AnalysisPlayerEffects(); options.loupe = true; options.label = true
        _ = clip.applyPlayerEffects(options, replacing: [], box: motion.samples[0].box, motion: motion, at: 0)
        XCTAssertEqual(Set(clip.annotations.compactMap { $0.playerMotion?.trackID }), [motion.trackID!])
        var loupe = try XCTUnwrap(clip.annotations.first { $0.tool == .loupe })
        XCTAssertEqual(loupe.points(at: 0.1)[0].x, 0.475, accuracy: 0.0001)
        let moved = CGPoint(x: 0.5, y: 0.5)
        loupe.moveDrawing(to: [moved], at: 0.1)
        XCTAssertEqual(loupe.points(at: 0.1)[0].x, moved.x, accuracy: 0.0001)
        XCTAssertEqual(loupe.points(at: 0.1)[0].y, moved.y, accuracy: 0.0001)
    }

    func testStyleDefaultsRoundTrip() throws {
        let style = AnnotationLoupeStyle()
        XCTAssertEqual(style.magnification, 2)
        XCTAssertEqual(style.diameter, 0.22)
        XCTAssertEqual(style.offset, CGPoint(x: 0, y: -0.18))
        XCTAssertEqual(style, try JSONDecoder().decode(AnnotationLoupeStyle.self, from: JSONEncoder().encode(style)))
    }

    func testGeometryHasFixedDiameterAndClampsLens() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let geometry = try! XCTUnwrap(AnnotationLoupeGeometry.make(style: .init(), focus: CGPoint(x: 990, y: 10), frame: frame, bounds: frame))
        XCTAssertEqual(geometry.lensRect.width, 220, accuracy: 0.001)
        XCTAssertEqual(geometry.lensRect.maxX, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(geometry.lensRect.minY, frame.minY, accuracy: 0.001)
    }

    func testMissingTrackedPointHidesLoupe() {
        var mark = AnalysisAnnotation(tool: .loupe, points: [.zero], start: 0, end: 2)
        mark.playerMotion = PlayerMotion(samples: [.init(time: 0, box: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.2))])
        XCTAssertNil(AnnotationLoupeGeometry.make(mark: mark, time: 1, frame: .init(x: 0, y: 0, width: 100, height: 100), bounds: .init(x: 0, y: 0, width: 100, height: 100)))
    }
}
