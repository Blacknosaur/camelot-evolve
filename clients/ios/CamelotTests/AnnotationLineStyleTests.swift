import CoreGraphics
import XCTest
@testable import Camelot

final class AnnotationLineStyleTests: XCTestCase {
    func testDefaultsAreSolidWithoutEndpoints() {
        XCTAssertEqual(AnnotationLineStyle(), .default)
        XCTAssertEqual(AnnotationLineStyle().pattern, .solid)
        XCTAssertEqual(AnnotationLineStyle().start, .none)
        XCTAssertEqual(AnnotationLineStyle().end, .none)
    }

    func testRoundTripsStyle() throws {
        let style = AnnotationLineStyle(pattern: .dotted, start: .circle, end: .arrow)
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationLineStyle.self, from: data), style)
    }

    func testRendererProducesDifferentPixelsForDashedAndSolidLines() {
        var solid = line(style: .default)
        var dashed = solid
        dashed.lineStyle = AnnotationLineStyle(pattern: .dashed)
        XCTAssertNotEqual(nonTransparentPixels(render: solid), nonTransparentPixels(render: dashed))
    }

    func testExplicitArrowEndpointNoneOmitsLegacyArrowhead() {
        var legacy = line(tool: .arrow, style: nil)
        var noHead = line(tool: .arrow, style: AnnotationLineStyle(pattern: .solid, end: .none))
        XCTAssertNotEqual(nonTransparentPixels(render: legacy), nonTransparentPixels(render: noHead))
    }

    func testExplicitDashedConnectionsHaveTransparentGaps() {
        let solid = line(tool: .connection, style: .default)
        let dashed = line(tool: .connection, style: .init(pattern: .dashed))
        XCTAssertLessThan(nonTransparentPixels(render: dashed), nonTransparentPixels(render: solid))
    }

    private func line(tool: AnalysisDrawingTool = .line, style: AnnotationLineStyle?) -> AnalysisAnnotation {
        var mark = AnalysisAnnotation(tool: tool, points: [.init(x: 0.18, y: 0.5), .init(x: 0.82, y: 0.5)], start: 0, end: 2)
        mark.lineStyle = style
        return mark
    }

    private func nonTransparentPixels(render mark: AnalysisAnnotation) -> Int {
        let width = 240, height = 120, bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            AnnotationRenderer.draw([mark], time: 0.5, in: context, frame: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
    }
}
