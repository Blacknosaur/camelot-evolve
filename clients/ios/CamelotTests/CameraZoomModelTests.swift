import CoreGraphics
import XCTest
@testable import Camelot

final class CameraZoomModelTests: XCTestCase {
    func testLensPillsMatchCameraAppOnCommonDevices() {
        // Triple camera with 3× telephoto (iPhone 15 Pro): switch-overs at 2× and 6× hardware, ×0.5 display.
        let triple3 = CameraZoomStops.lensFactors(switchOverFactors: [2, 6], displayMultiplier: 0.5)
        XCTAssertEqual(triple3, [1, 3])
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: triple3, minimum: 0.5, maximum: 6), [0.5, 1, 2, 3])
        // Triple camera with 5× telephoto (iPhone 16 Pro).
        let triple5 = CameraZoomStops.lensFactors(switchOverFactors: [2, 10], displayMultiplier: 0.5)
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: triple5, minimum: 0.5, maximum: 6), [0.5, 1, 2, 5])
        // Dual wide (iPhone 16): one switch-over at 2× hardware.
        let dualWide = CameraZoomStops.lensFactors(switchOverFactors: [2], displayMultiplier: 0.5)
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: dualWide, minimum: 0.5, maximum: 6), [0.5, 1, 2])
        // Single lens: 1× and a 2× crop.
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: [], minimum: 1, maximum: 6), [1, 2])
        // Hardware range clamps the pills; a 2× lens replaces the crop stop.
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: [2], minimum: 1, maximum: 1.5), [1])
        XCTAssertEqual(CameraZoomStops.pills(lensFactors: [2], minimum: 1, maximum: 6), [1, 2])
        // Near-duplicates collapse.
        let merged = CameraZoomStops.merge([1, 1.02, 2, 1.99], minimum: 0.5, maximum: 6)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], 1, accuracy: 0.03)
        XCTAssertEqual(merged[1], 2, accuracy: 0.03)
    }

    func testSelectedPillAndLabels() {
        let pills: [CGFloat] = [0.5, 1, 2, 5]
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 1.7, in: pills), 1)
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 2, in: pills), 2)
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 1.9999, in: pills), 2, "A ramp that settles just under its target still owns the pill")
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 1.95, in: pills), 1)
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 0.5, in: pills), 0.5)
        XCTAssertEqual(CameraZoomStops.selectedPill(for: 5.9, in: pills), 5)
        XCTAssertEqual(CameraZoomStops.label(for: 1, value: 1.7, isSelected: true), "1.7×")
        XCTAssertEqual(CameraZoomStops.label(for: 2, value: 1.7, isSelected: false), "2")
        XCTAssertEqual(CameraZoomStops.label(for: 0.5, value: 1.7, isSelected: false), "0.5")
    }

    func testRulerIsLogarithmicAndClamped() {
        let scale = CameraZoomScale(minimum: 0.5, maximum: 6, lensFactors: [1, 3])
        let ruler = CameraZoomRuler(scale: scale, pointsPerOctave: 100)
        XCTAssertEqual(ruler.offset(of: 2, around: 1), 100, accuracy: 0.001)
        XCTAssertEqual(ruler.offset(of: 0.5, around: 1), -100, accuracy: 0.001)
        XCTAssertEqual(ruler.offset(of: 4, around: 2), 100, accuracy: 0.001, "Equal ratios are equal distances")
        XCTAssertEqual(ruler.value(from: 1, translation: -100), 2, accuracy: 0.001, "Dragging left zooms in")
        XCTAssertEqual(ruler.value(from: 2, translation: 100), 1, accuracy: 0.001)
        XCTAssertEqual(ruler.value(from: 1, translation: -10_000), 6)
        XCTAssertEqual(ruler.value(from: 1, translation: 10_000), 0.5)
        let ticks = ruler.ticks(around: 1, width: 240)
        XCTAssertTrue(ticks.contains { $0.isStop && $0.zoom == 1 && abs($0.offset) < 0.001 })
        XCTAssertTrue(ticks.contains { $0.isStop && $0.zoom == 2 && abs($0.offset - 100) < 0.001 })
        XCTAssertTrue(ticks.contains { $0.isStop && $0.zoom == 0.5 })
        XCTAssertFalse(ticks.contains { $0.zoom > 2.31 }, "Ticks outside the visible width are skipped")
        XCTAssertFalse(ticks.contains { !$0.isStop && abs($0.zoom - 2) < 0.01 }, "Stops are not duplicated by minor ticks")
        XCTAssertEqual(ticks, ticks.sorted { $0.offset < $1.offset })
        XCTAssertEqual(scale.stops, [0.5, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(scale.hapticStops, [0.5, 1, 2, 3])
    }

    func testStopCrossingAndSnapping() {
        let stops: [CGFloat] = [0.5, 1, 2, 3]
        XCTAssertEqual(CameraZoomRuler.crossedStop(from: 1.8, to: 2.1, stops: stops), 2)
        XCTAssertEqual(CameraZoomRuler.crossedStop(from: 2.1, to: 1.9, stops: stops), 2)
        XCTAssertNil(CameraZoomRuler.crossedStop(from: 1.2, to: 1.6, stops: stops))
        XCTAssertNil(CameraZoomRuler.crossedStop(from: 2, to: 2, stops: stops), "Sitting on a stop is not a crossing")
        XCTAssertEqual(CameraZoomRuler.snapped(2.01, to: stops), 2)
        XCTAssertEqual(CameraZoomRuler.snapped(2.2, to: stops), 2.2)
    }

    func testExposureSliderMapsDragToBias() {
        let slider = CameraExposureSlider(minimum: -2, maximum: 2, pointsPerStop: 40, trackHeight: 120)
        XCTAssertEqual(slider.bias(from: 0, verticalTranslation: -40), 1, accuracy: 0.001, "Dragging up brightens")
        XCTAssertEqual(slider.bias(from: 0, verticalTranslation: 20), -0.5, accuracy: 0.001)
        XCTAssertEqual(slider.bias(from: 1.5, verticalTranslation: -400), 2)
        XCTAssertEqual(slider.bias(from: 0, verticalTranslation: 400), -2)
        XCTAssertEqual(slider.knobOffset(for: 2), 0)
        XCTAssertEqual(slider.knobOffset(for: 0), 60)
        XCTAssertEqual(slider.knobOffset(for: -2), 120)
    }
}
