import UIKit
import XCTest
@testable import Camelot

/// Diagnostics for the 2D board drawing: a phase breakdown and a render gallery. Both are opt-in, so a
/// normal run neither spends ~280 frames on them nor warms the process-wide surface cache that the timing
/// tests would then silently depend on. `TacticalBoardTests.testHeavyBoardRendersWithinFrameBudget` owns
/// the budget these help diagnose.
final class BoardPerfProbeTests: XCTestCase {
    private let size = CGSize(width: 402, height: 620)

    private func imageRenderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// Times two variants by alternating them frame by frame, so thermal drift and CPU ramp hit both
    /// equally. On a phone a straight A-then-B comparison is worthless: the same code measured twice in
    /// one run can differ by 50%, and later blocks can come out faster than earlier ones.
    private func compare(_ labelA: String, _ bodyA: () -> Void, _ labelB: String, _ bodyB: () -> Void,
                         count: Int = 40) -> (a: Double, b: Double) {
        var timesA: [Double] = [], timesB: [Double] = []
        bodyA(); bodyB()
        for _ in 0..<count {
            var start = CFAbsoluteTimeGetCurrent()
            bodyA()
            timesA.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            start = CFAbsoluteTimeGetCurrent()
            bodyB()
            timesB.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let a = timesA.sorted()[timesA.count / 2], b = timesB.sorted()[timesB.count / 2]
        print(String(format: "PROBE A/B %@ %6.2f ms  vs  %@ %6.2f ms  (%+.0f%%)",
                     labelA as NSString, a, labelB as NSString, b, (b - a) / a * 100))
        return (a, b)
    }

    @discardableResult
    private func time(_ label: String, count: Int = 40, _ body: (Int) -> Void) -> (median: Double, p95: Double) {
        var times: [Double] = []
        for frame in 0..<count {
            let start = CFAbsoluteTimeGetCurrent()
            body(frame)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let sorted = times.sorted()
        let result = (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        print(String(format: "PROBE %-34@ median %6.2f ms  p95 %6.2f ms", label as NSString, result.0, result.1))
        return result
    }

    /// Phase breakdown of a heavy animated board while playing: each row adds one kind of element,
    /// so the difference between neighbouring rows is that kind's cost.
    /// Run with `BOARD_PROBE=1 xcodebuild test …` (`TEST_RUNNER_BOARD_PROBE=1` for a device).
    func testProbeDrawingCosts() throws {
        guard ProcessInfo.processInfo.environment["BOARD_PROBE"] != nil else { throw XCTSkip("Set BOARD_PROBE to run the drawing probe") }
        let full = TacticalBoardTests.heavyDocument()
        let duration = full.duration
        let renderer = imageRenderer()
        func subset(_ keep: (BoardElement) -> Bool) -> BoardDocument {
            var copy = full
            copy.elements = full.elements.filter(keep)
            return copy
        }
        let empty = subset { _ in false }
        let people = subset { $0.kind.isPerson }
        let peopleBall = subset { $0.kind.isPerson || $0.kind == .ball }
        let noLines = subset { !$0.isLineLike }
        let noAerial = subset { !$0.isLineLike || !$0.isAerial }

        // Warm caches (surface slab, fonts) the way the editor does before playback starts.
        _ = renderer.image { context in BoardRenderer(document: full, time: 0, inset: 10).draw(in: context.cgContext, size: size) }

        let floor = time("blank image (renderer floor)") { _ in _ = renderer.image { _ in } }
        var phases: [(String, (median: Double, p95: Double))] = []
        for (label, document) in [("surface only", empty), ("+ players (22)", people), ("+ ball", peopleBall),
                                  ("+ equipment & zones", noLines), ("+ flat lines", noAerial), ("+ aerial line = everything", full)] {
            phases.append((label, time(label) { frame in
                let time = duration * Double(frame) / 40
                _ = renderer.image { context in BoardRenderer(document: document, time: time, inset: 10).draw(in: context.cgContext, size: size) }
            }))
        }
        // The breakdown is only meaningful if every phase really drew: each must cost more than an empty
        // image, and the whole board must cost at least as much as the surface alone.
        for (label, result) in phases {
            XCTAssertGreaterThan(result.median, floor.median, "\(label) drew something")
            XCTAssertLessThan(result.median, 200, "\(label) is not pathologically slow")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(phases.last).1.median, try XCTUnwrap(phases.first).1.median,
                                    "The full board costs at least as much as the bare surface")
        time("everything, field behind canvas") { frame in
            let time = duration * Double(frame) / 40
            _ = renderer.image { context in BoardRenderer(document: full, time: time, inset: 10, drawsSurface: false).draw(in: context.cgContext, size: size) }
        }
        var editing = full
        editing.showsOnionSkin = true
        func drawOnion(cached: Bool) {
            _ = renderer.image { context in
                var onion = BoardRenderer(document: editing, selectedID: editing.elements.last?.id, showsHandles: true, inset: 10,
                                          drawsSurface: false, animationFrame: 2, onionFrame: 2)
                onion.cachesOnionLayer = cached
                onion.draw(in: context.cgContext, size: size)
            }
        }
        let onion = compare("onion ghosts redrawn", { drawOnion(cached: false) }, "onion layer cached", { drawOnion(cached: true) })
        XCTAssertLessThan(onion.b, onion.a, "The cached ghost layer is the cheaper of the two")
        time("layout resolve only") { frame in _ = full.elements(at: duration * Double(frame) / 40) }
        time("onion skin layouts only") { _ in _ = full.onionSkin(aroundFrame: 2) }
        time("surface cache lookup") { _ in _ = BoardSurfaceCache.shared.slab(field: .footballFull, style: .grass, pixelsPerMeter: 12) }
    }

    /// Writes renders of the heavy board for visual review when BOARD_SHOTS_DIR is set.
    /// Composed the way the editor does it: the field as an image, the elements drawn over it.
    func testRenderGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["BOARD_SHOTS_DIR"] else { throw XCTSkip("Set BOARD_SHOTS_DIR to write the gallery") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let full = TacticalBoardTests.heavyDocument()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        for (name, size) in [("portrait", CGSize(width: 402, height: 620)), ("landscape", CGSize(width: 780, height: 380))] {
            for style in [BoardFieldStyle.grass, .chalk] {
                var document = full
                document.fieldStyle = style
                for (suffix, onion) in [("", nil as Int?), ("-onion", 2)] {
                    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        let cg = context.cgContext
                        UIColor(white: 0.07, alpha: 1).setFill()
                        cg.fill(CGRect(origin: .zero, size: size))
                        if let surface = BoardSurfaceCache.shared.canvas(field: document.fieldType, style: style, size: size, inset: 10, reserved: .zero, scale: 3) {
                            cg.saveGState()
                            cg.translateBy(x: 0, y: size.height)
                            cg.scaleBy(x: 1, y: -1)
                            cg.draw(surface, in: CGRect(origin: .zero, size: size))
                            cg.restoreGState()
                        }
                        BoardRenderer(document: document, time: onion == nil ? 0.4 : nil, inset: 10, drawsSurface: false,
                                      animationFrame: onion, onionFrame: onion).draw(in: cg, size: size)
                    }
                    try XCTUnwrap(image.pngData()).write(to: directory.appending(path: "board-\(style.rawValue)-\(name)\(suffix).png"))
                }
            }
        }
    }
}
