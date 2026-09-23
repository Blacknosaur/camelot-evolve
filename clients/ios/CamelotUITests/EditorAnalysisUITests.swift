import XCTest
import UIKit

final class EditorAnalysisUITests: XCTestCase {
    @MainActor
    func testSimplifiedTrackingSheetOnPhone() throws {
        let app = try openAnalysisForMeasurements()
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 3, ruler: ruler, app: app)
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
        let frame = app.otherElements["analysis-preview-touch-surface"].frame
        let height = min(frame.height, frame.width * 9 / 16)
        let target = CGPoint(x: frame.midX + height * 16 / 9 * (0.394 - 0.5), y: frame.midY + height * (0.586 - 0.5))
        let player = try XCTUnwrap(candidates.allElementsBoundByIndex.min {
            hypot($0.frame.midX - target.x, $0.frame.midY - target.y) < hypot($1.frame.midX - target.x, $1.frame.midY - target.y)
        })
        player.tap()
        app.buttons["analysis-player-effects"].tap()
        XCTAssertTrue(app.buttons["analysis-apply-player-effects"].waitForExistence(timeout: 5))
        app.buttons["analysis-apply-player-effects"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 90))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        seekAnalysis(to: 3, ruler: ruler, app: app)
        let tracking = app.buttons["analysis-player-tracking"]
        XCTAssertTrue(tracking.waitForExistence(timeout: 10)); tracking.tap()
        XCTAssertFalse(app.segmentedControls["analysis-tracking-engine"].exists)
        XCTAssertFalse(app.buttons["analysis-track-selected-player-v2"].exists)
        for identifier in ["analysis-track-player", "analysis-track-player-forward",
                           "analysis-track-player-backward", "analysis-fill-player-gap"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5), "Missing simplified tracking action: \(identifier)")
        }
        XCTAssertFalse(app.buttons["analysis-next-gap"].exists)
        XCTAssertFalse(app.buttons["analysis-correct-selected-player"].exists)
        XCTAssertFalse(app.buttons["analysis-review-player-frames"].exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Tracking and repair controls \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testForwardRetrackKeepsLaterEffectsOnPhone() throws {
        let app = try openAnalysisForMeasurements()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-"))
        func pick(_ x: Double, _ y: Double) throws {
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
            let detected = candidates.allElementsBoundByIndex.map { ($0, $0.frame) }
            // The accessibility container is the union of clipped children and
            // the hint. The actual gesture surface has the full preview bounds.
            let frame = app.otherElements["analysis-preview-touch-surface"].frame
            let height = min(frame.height, frame.width * 9 / 16)
            let target = CGPoint(x: frame.midX + height * 16 / 9 * (x - 0.5), y: frame.midY + height * (y - 0.5))
            let player = try XCTUnwrap(detected.min {
                hypot($0.1.midX - target.x, $0.1.midY - target.y) < hypot($1.1.midX - target.x, $1.1.midY - target.y)
            }?.0)
            print("REPAIR_UI_PICK canvas=\(frame) target=\(target) player=\(player.identifier) box=\(player.frame)")
            let selection = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); selection.name = "Player correction selection at \(x),\(y)"; selection.lifetime = .keepAlways; add(selection)
            player.tap()
        }
        func waitForTracking() {
            XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 90))
            if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        }
        seekAnalysis(to: 3, ruler: ruler, app: app)
        try pick(0.394, 0.586)
        app.buttons["analysis-player-effects"].tap()
        app.switches["analysis-player-spotlight"].coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        app.buttons["analysis-apply-player-effects"].tap()
        waitForTracking()
        seekAnalysis(to: 6, ruler: ruler, app: app)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); before.name = "Grounded shared halo and spotlight before forward retrack"; before.lifetime = .keepAlways; add(before)
        let bars = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-"))
        XCTAssertEqual(bars.count, 2)
        seekAnalysis(to: 4, ruler: ruler, app: app)
        app.buttons["analysis-clip-tracks"].tap()
        app.buttons["analysis-manage-player-tracks"].tap()
        let savedPlayer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-use-player-")).firstMatch
        XCTAssertTrue(savedPlayer.waitForExistence(timeout: 5)); savedPlayer.tap()
        XCTAssertTrue(app.buttons["analysis-player-tracking"].waitForExistence(timeout: 5))
        app.buttons["analysis-player-tracking"].tap()
        XCTAssertTrue(app.buttons["analysis-track-player-forward"].waitForExistence(timeout: 5))
        app.buttons["analysis-track-player-forward"].tap()
        waitForTracking()
        seekAnalysis(to: 6, ruler: ruler, app: app)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(app.staticTexts["analysis-active-player-track"].label, "Player 1")
        XCTAssertFalse(app.buttons["analysis-resume-player"].exists, "Later saved motion is still available after an earlier correction")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); after.name = "Later grounded effects preserved after forward retrack"; after.lifetime = .keepAlways; add(after)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    private var analysisRecordingID: String { ProcessInfo.processInfo.environment["CAMELOT_ANALYSIS_RECORDING_ID"] ?? "EBB12192-62DB-495B-A6CE-218F0C420A74" }

    @MainActor
    private func seekAnalysis(to target: Double, ruler: XCUIElement, app: XCUIApplication, duration: Double = 33) {
        let zoom = Double((app.staticTexts["analysis-timeline-scale"].label).replacingOccurrences(of: "×", with: "")) ?? 1
        let span = duration / max(1, zoom)
        for _ in 0..<20 {
            let current = Double((ruler.value as? String ?? "0").replacingOccurrences(of: " seconds", with: "")) ?? 0
            let normalized = 0.5 + (target - current) / span
            if normalized >= 0.05 && normalized <= 0.95 {
                ruler.coordinate(withNormalizedOffset: CGVector(dx: normalized, dy: 0.5)).tap()
                return
            }
            let origin = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let translation = min(0.38, max(-0.38, -(target - current) / span)) * ruler.frame.width
            origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: translation, dy: 0)))
        }
        XCTFail("Could not reach analysis time \(target)")
    }
    @MainActor
    private func openAnalysisForMeasurements() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else {
            throw XCTSkip("Opt in on the fixture device")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        // Project rows are lazy. Reveal the existing recording before querying it.
        for _ in 0..<8 {
            if source.exists && source.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 3)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        if app.alerts["Analysis"].waitForExistence(timeout: 5) { app.alerts["Analysis"].buttons["OK"].tap() }
        return app
    }

    @MainActor
    func testMeasurementsTwoPointKnownLengthFixedCameraApplyDoesNotCreateDrawingLayer() throws {
        let app = try openAnalysisForMeasurements()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Custom distance / rectangle"].tap()
        app.buttons["ground-settings"].tap()
        XCTAssertTrue(app.segmentedControls["ground-reference-mode"].buttons["2 points · local"].isSelected)
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if (fixed.value as? String) != "1" { fixed.tap() }
        app.textFields["ground-length"].tap()
        app.textFields["ground-length"].typeText("10")
        app.buttons["Done"].tap()
        preview.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.42)).tap()
        preview.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.58)).tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("2 points"))
        let apply = app.buttons["ground-apply"]
        XCTAssertTrue(apply.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        apply.tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).count, 0, "Calibration is clip data, not a drawing layer")
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testMeasurementsFourPointEditSupportsPinchAndCornerDragThenCancel() throws {
        let app = try openAnalysisForMeasurements()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Custom distance / rectangle"].tap()
        app.buttons["ground-settings"].tap()
        app.segmentedControls["ground-reference-mode"].buttons["4 points · ground"].tap()
        // Toggle before typing: the decimal keyboard would otherwise cover the switch.
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if (fixed.value as? String) != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(NSPredicate(format: "value == %@", "1").evaluate(with: fixed) || XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: fixed)], timeout: 3) == .completed)
        app.textFields["ground-length"].tap(); app.textFields["ground-length"].typeText("20")
        app.textFields["ground-width"].tap(); app.textFields["ground-width"].typeText("10")
        app.buttons["Done"].tap()
        for (index, point) in [CGPoint(x: 0.22, y: 0.35), .init(x: 0.78, y: 0.35), .init(x: 0.80, y: 0.78), .init(x: 0.20, y: 0.78)].enumerated() {
            app.buttons["ground-point-\(index)"].tap()
            preview.coordinate(withNormalizedOffset: .init(dx: point.x, dy: point.y)).tap()
        }
        XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
        let apply = app.buttons["ground-apply"]
        XCTAssertTrue(apply.wait(for: \.isEnabled, toEqual: true, timeout: 5)); apply.tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["analysis-clip-tracks"].wait(for: \.isEnabled, toEqual: true, timeout: 90))
        app.buttons["analysis-clip-tracks"].tap(); app.buttons["Measurements & ground"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
        app.buttons["ground-point-2"].tap()
        let point = preview.coordinate(withNormalizedOffset: .init(dx: 0.78, dy: 0.35))
        point.press(forDuration: 0.2, thenDragTo: point.withOffset(.init(dx: 18, dy: 12)))
        let beforePinch = preview.value as? String
        preview.pinch(withScale: 1.8, velocity: 1)
        XCTAssertEqual(preview.value as? String, beforePinch, "Pinch and navigation must not add or remove calibration points")
        let cornerDrag = preview.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.6))
        cornerDrag.press(forDuration: 0.1, thenDragTo: cornerDrag.withOffset(.init(dx: -32, dy: 18)))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Four-point Measurements editor after pinch and corner drag"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["ground-cancel"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testMobileInspectorFixedPlayheadAndLayerTimelineGestures() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else { throw XCTSkip("Opt in on the fixture device") }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let initialRuler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 1, ruler: initialRuler, app: app)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = canvas.frame, height = min(canvas.frame.height, canvas.frame.width * 9 / 16)
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: frame.width * x, dy: (frame.height - height) / 2 + height * y))
        }
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        }
        let canvasBeforePinch = canvas.value as? String
        canvas.pinch(withScale: 1.35, velocity: 1)
        XCTAssertNotEqual(canvas.value as? String, canvasBeforePinch, "Two fingers zoom the analysis preview")
        XCTAssertTrue(app.buttons["analysis-inspect-fit"].waitForExistence(timeout: 5))
        app.buttons["analysis-inspect-fit"].tap()
        XCTAssertEqual(canvas.value as? String, canvasBeforePinch)
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-arrow"].tap()
        point(0.25, 0.5).press(forDuration: 0.1, thenDragTo: point(0.7, 0.7))
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let placedTiming = bar.value as? String
        let startHandle = app.descendants(matching: .any).matching(identifier: "analysis-layer-start").firstMatch
        let inPoint = startHandle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        inPoint.press(forDuration: 0.1, thenDragTo: inPoint.withOffset(.init(dx: -9, dy: 0)))
        XCTAssertNotEqual(bar.value as? String, placedTiming, "The In handle remains draggable when it overlaps the playhead")
        let timing = bar.value as? String
        let time = app.staticTexts["analysis-current-time"], oldTime = time.label
        let playhead = app.descendants(matching: .any).matching(identifier: "analysis-playhead").firstMatch
        XCTAssertTrue(playhead.exists)
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        XCTAssertEqual(playhead.frame.midX, ruler.frame.midX, accuracy: 2)
        let rulerDrag = ruler.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5))
        rulerDrag.press(forDuration: 0.1, thenDragTo: rulerDrag.withOffset(CGVector(dx: -22, dy: 0)))
        XCTAssertNotEqual(time.label, oldTime, "Dragging the ruler scrubs the video")
        XCTAssertEqual(bar.value as? String, timing, "Scrubbing must not move a layer")
        app.buttons["analysis-timeline-zoom-in"].tap()
        XCTAssertFalse(app.sliders["Scroll layer timeline"].exists)
        let timeline = app.otherElements.matching(identifier: "analysis-layer-timeline").firstMatch
        let visibleRange = timeline.value as? String, scrubbedTime = time.label
        let panArea = app.descendants(matching: .any).matching(identifier: "analysis-timeline-pan-area").firstMatch
        let panPoint = panArea.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.3))
        panPoint.press(forDuration: 0.1, thenDragTo: panPoint.withOffset(.init(dx: -45, dy: 0)))
        XCTAssertNotEqual(timeline.value as? String, visibleRange, "Drag the empty track area to pan without a slider")
        XCTAssertNotEqual(time.label, scrubbedTime, "Dragging the empty track area seeks under the fixed playhead")
        XCTAssertEqual(bar.value as? String, timing)
        app.buttons["analysis-timeline-fit"].tap()
        app.buttons["Drawing style"].tap()
        let tabs = app.segmentedControls["analysis-inspector-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["analysis-effect-style"].exists)
        XCTAssertFalse(app.textFields["analysis-layer-name"].exists)
        capture("Phone layer inspector Style")
        tabs.buttons["Timing"].tap()
        XCTAssertTrue(app.steppers["analysis-layer-in"].exists)
        XCTAssertTrue(app.buttons["End at playhead"].exists)
        capture("Phone layer inspector Timing")
        tabs.buttons["Layer"].tap()
        XCTAssertTrue(app.textFields["analysis-layer-name"].exists)
        XCTAssertTrue(app.buttons["Duplicate layer"].exists)
        capture("Phone layer inspector Layer")
        app.buttons["Done"].tap()
        let endHandle = app.descendants(matching: .any).matching(identifier: "analysis-layer-end").firstMatch
        XCTAssertTrue(endHandle.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(endHandle.frame.width, 43)
        XCTAssertLessThan(endHandle.frame.maxX, app.frame.maxX - 1, "The arrow end-handle touch target fits inside the phone")
        let endPoint = endHandle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.3))
        endPoint.press(forDuration: 0.1, thenDragTo: endPoint.withOffset(.init(dx: -28, dy: 0)))
        XCTAssertFalse(app.staticTexts["Drag handles to reshape · drag inside to move"].exists)
        capture("Arrow layer and inset timeline trim handles")
        app.buttons["Layer actions"].tap()
        app.buttons["Follow clip camera"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 90))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        XCTAssertEqual(app.buttons["analysis-motion-mode"].value as? String, "Follow camera")
        seekAnalysis(to: 1, ruler: ruler, app: app)
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-arrow"].tap()
        point(0.55, 0.45).press(forDuration: 0.1, thenDragTo: point(0.78, 0.62))
        XCTAssertTrue(app.buttons["save-analysis-workspace"].isEnabled)
        XCTAssertEqual(app.buttons["analysis-motion-mode"].value as? String, "Follow camera", "The second arrow reuses the camera track immediately")
        capture("Second arrow reuses the saved camera track")
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testEditablePolygonTimedZoomAndPinchTimelineOnDevice() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else { throw XCTSkip("Opt in on the fixture device") }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = canvas.frame
            let height = min(frame.height, frame.width * 9 / 16), width = height * 16 / 9
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (frame.width - width) / 2 + width * x, dy: (frame.height - height) / 2 + height * y))
        }
        app.buttons["analysis-tools"].tap()
        XCTAssertEqual(app.buttons["analysis-tool-zone"].label, "Polygon")
        app.buttons["analysis-tool-zone"].tap()
        for corner in [CGPoint(x: 0.15, y: 0.4), .init(x: 0.7, y: 0.4), .init(x: 0.75, y: 0.85), .init(x: 0.2, y: 0.85)] { point(corner.x, corner.y).tap() }
        app.buttons["analysis-finish-construction"].tap()
        point(0.15, 0.4).tap()
        XCTAssertTrue(app.staticTexts["Corner 1"].waitForExistence(timeout: 5))
        app.buttons["Add corner"].tap()
        XCTAssertTrue(app.staticTexts["Corner 2"].waitForExistence(timeout: 5))
        app.buttons["Remove corner"].tap()
        XCTAssertFalse(app.buttons["Remove corner"].isEnabled)
        point(0.15, 0.4).press(forDuration: 0.1, thenDragTo: point(0.25, 0.5))
        app.buttons["analysis-motion-mode"].tap(); app.buttons["Keyframes"].tap()
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 2, ruler: ruler, app: app)
        point(0.25, 0.5).press(forDuration: 0.1, thenDragTo: point(0.3, 0.6))
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-keyframe-")).count, 2)
        let shape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shape.name = "Editable polygon with animated corners"; shape.lifetime = .keepAlways; add(shape)
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-zoom"].tap()
        point(0.65, 0.6).tap()
        XCTAssertTrue(app.sliders["analysis-zoom-amount"].waitForExistence(timeout: 5))
        app.sliders["analysis-zoom-amount"].adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["Done"].tap()
        point(0.65, 0.6).press(forDuration: 0.1, thenDragTo: point(0.55, 0.65))
        let bars = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-"))
        XCTAssertEqual(bars.count, 2)
        let scale = app.staticTexts["analysis-timeline-scale"], scaleBefore = scale.label
        let zoomBar = bars.matching(NSPredicate(format: "label == %@", "Zoom timing")).firstMatch
        let timing = zoomBar.value as? String
        let timeline = app.otherElements.matching(identifier: "analysis-layer-timeline").firstMatch
        timeline.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(scale.label, scaleBefore, "Two fingers zoom the shared time axis")
        let pinchScale = Double(scale.label.replacingOccurrences(of: "×", with: "")) ?? 0
        XCTAssertGreaterThan(pinchScale, 1)
        XCTAssertEqual(zoomBar.value as? String, timing, "Pinching must not move or trim a layer")
        timeline.pinch(withScale: 0.5, velocity: -1)
        let reducedScale = Double(scale.label.replacingOccurrences(of: "×", with: "")) ?? 0
        XCTAssertLessThan(reducedScale, pinchScale, "Pinching inward zooms the time axis out")
        XCTAssertEqual(zoomBar.value as? String, timing)
        // A native pinch's final scale varies slightly by device. Fit, then use
        // a known scale so the Out handle is on screen before trying to drag it.
        app.buttons["Fit timeline"].tap()
        for _ in 0..<2 { app.buttons["analysis-timeline-zoom-in"].tap() }
        let end = app.descendants(matching: .any).matching(identifier: "analysis-layer-end").firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        end.press(forDuration: 0.1, thenDragTo: end.withOffset(.init(dx: 20, dy: 0)))
        XCTAssertNotEqual(zoomBar.value as? String, timing)
        let zoom = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); zoom.name = "Timed zoom focus and zoomable layer timeline"; zoom.lifetime = .keepAlways; add(zoom)
        app.buttons["analysis-clip-tracks"].tap()
        app.buttons["Preview effect"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let playing = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); playing.name = "Timed zoom playing on stress video"; playing.lifetime = .keepAlways; add(playing)
        app.buttons["Pause"].tap()
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testConnectedPlayersPolygonAndCameraLockOnDevice() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else { throw XCTSkip("Opt in on the fixture device") }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = canvas.frame
            let height = min(frame.height, frame.width * 9 / 16), width = height * 16 / 9
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (frame.width - width) / 2 + width * x, dy: (frame.height - height) / 2 + height * y))
        }
        func choose(_ name: String) {
            let button = app.buttons["analysis-tool-\(name)"]
            app.buttons["analysis-tools"].tap()
            button.tap()
        }
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 3, ruler: ruler, app: app)
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
        choose("connection")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        candidates.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["analysis-construction-count"].label, "1 player")
        let firstPlayer = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); firstPlayer.name = "First connected player has a numbered START marker"; firstPlayer.lifetime = .keepAlways; add(firstPlayer)
        candidates.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["analysis-finish-construction"].isEnabled)
        app.buttons["analysis-finish-construction"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 45))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        XCTAssertEqual(app.buttons["analysis-motion-mode"].value as? String, "Follow player")
        app.buttons["Drawing style"].tap()
        app.segmentedControls["analysis-effect-style"].buttons["Wall"].tap()
        XCTAssertTrue(app.sliders["analysis-wall-height"].exists)
        app.sliders["analysis-wall-height"].adjust(toNormalizedSliderPosition: 0.45)
        app.buttons["Done"].tap()
        seekAnalysis(to: 4, ruler: ruler, app: app)
        let linked = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); linked.name = "Animated connection attached to two players"; linked.lifetime = .keepAlways; add(linked)
        if app.buttons["Cancel pick"].exists { app.buttons["Cancel pick"].tap() }
        XCTAssertTrue(app.buttons["analysis-correct-anchor-0"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["analysis-correct-anchor-0"].frame.height, 44)
        let playerCards = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        playerCards.name = "Direct numbered player correction cards"; playerCards.lifetime = .keepAlways; add(playerCards)
        app.buttons["analysis-correct-anchor-1"].tap()
        XCTAssertTrue(app.otherElements["analysis-connection-correction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reselect 2 ·")).firstMatch.exists)
        let correction = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); correction.name = "Numbered connection correction with selected player reference"; correction.lifetime = .keepAlways; add(correction)
        app.buttons["Cancel pick"].tap()
        choose("zone")
        point(0.1, 0.6).tap()
        XCTAssertEqual(app.staticTexts["analysis-construction-count"].label, "1 corner")
        let firstCorner = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); firstCorner.name = "Polygon first corner remains visible before adding another"; firstCorner.lifetime = .keepAlways; add(firstCorner)
        for corner in [CGPoint(x: 0.35, y: 0.6), .init(x: 0.4, y: 0.85), .init(x: 0.12, y: 0.85)] { point(corner.x, corner.y).tap() }
        app.buttons["analysis-finish-construction"].tap()
        // Reshape only the first vertex, keeping the other area corners fixed.
        point(0.1, 0.6).press(forDuration: 0.1, thenDragTo: point(0.15, 0.65))
        app.buttons["Layer actions"].tap()
        app.buttons["Follow clip camera"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 30))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        XCTAssertEqual(app.buttons["analysis-motion-mode"].value as? String, "Follow camera")
        app.buttons["Drawing style"].tap()
        XCTAssertTrue(app.segmentedControls["analysis-effect-style"].waitForExistence(timeout: 5))
        app.segmentedControls["analysis-effect-style"].buttons["Wall"].tap()
        app.sliders["analysis-wall-height"].adjust(toNormalizedSliderPosition: 0.6)
        app.sliders["analysis-wall-intensity"].adjust(toNormalizedSliderPosition: 0.65)
        app.buttons["Done"].tap()
        let area = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); area.name = "Camera-locked polygon and connected player layers"; area.lifetime = .keepAlways; add(area)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    /// Opt-in, non-saving walkthrough of the user's existing recording. Never
    /// resets onboarding, seeds records, or changes the saved project.
    @MainActor
    func testSelectPlayerAndAutomaticallyAttachEffectOnDevice() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else {
            throw XCTSkip("Opt in with TEST_RUNNER_CAMELOT_EXISTING_ANALYSIS_PROJECT=1 on the fixture device")
        }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        func savedPlayer(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "analysis-saved-player-", name)).firstMatch
        }
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let open = app.buttons["open-analysis"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap(); app.buttons["open-video-analysis"].tap()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 3, ruler: ruler, app: app)
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
        let frame = canvas.frame
        let videoHeight = frame.width * 9 / 16
        let target = CGPoint(x: frame.minX + frame.width * 0.394, y: frame.minY + (frame.height - videoHeight) / 2 + videoHeight * 0.586)
        let players = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-")).allElementsBoundByIndex
        let player = try XCTUnwrap(players.map { ($0, $0.frame) }.min { hypot($0.1.midX - target.x, $0.1.midY - target.y) < hypot($1.1.midX - target.x, $1.1.midY - target.y) }?.0)
        player.tap()
        let effects = app.buttons["analysis-player-effects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 5)); effects.tap()
        XCTAssertTrue(app.switches["analysis-player-ring"].waitForExistence(timeout: 5))
        app.buttons["analysis-apply-player-effects"].tap()
        let tracks = app.buttons["analysis-clip-tracks"]
        XCTAssertTrue(tracks.waitForExistence(timeout: 25))
        XCTAssertTrue(tracks.wait(for: \.isEnabled, toEqual: true, timeout: 90))
        if app.alerts["Analysis"].exists {
            app.alerts["Analysis"].buttons["OK"].tap()
            XCTAssertNotEqual(app.staticTexts["analysis-current-time"].label, "0:03.0", "Failure must seek to the last tracked frame")
            let correction = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); correction.name = "Tracking failure pauses at the last confirmed frame"; correction.lifetime = .keepAlways; add(correction)
        }
        app.buttons["Drawing style"].tap()
        let smoothing = app.sliders["analysis-tracking-smoothing"]
        XCTAssertTrue(smoothing.waitForExistence(timeout: 5))
        smoothing.adjust(toNormalizedSliderPosition: 0)
        smoothing.adjust(toNormalizedSliderPosition: 0.75)
        app.buttons["Done"].tap()
        let trackedBar = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        let trackedTiming = trackedBar.value as? String
        let trackedIn = app.descendants(matching: .any).matching(identifier: "analysis-layer-start").firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        trackedIn.press(forDuration: 0.1, thenDragTo: trackedIn.withOffset(.init(dx: -15, dy: 0)))
        XCTAssertNotEqual(trackedBar.value as? String, trackedTiming, "A tracked layer can extend earlier than its first tracking sample")
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); selected.name = "Selected player with automatically tracked ring"; selected.lifetime = .keepAlways; add(selected)
        app.buttons["analysis-clip-tracks"].tap()
        app.buttons["Preview effect"].tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.waitForNonExistence(timeout: 12))
        let followed = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); followed.name = "Effect after playback"; followed.lifetime = .keepAlways; add(followed)
        seekAnalysis(to: 3, ruler: ruler, app: app)
        app.buttons["analysis-clip-tracks"].tap()
        savedPlayer("Player 1").tap()
        effects.tap()
        app.switches["analysis-player-label"].coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["analysis-player-label-text"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.segmentedControls["analysis-text-alignment"].buttons["Right"].tap()
        app.sliders["analysis-text-size"].adjust(toNormalizedSliderPosition: 0.3)
        app.segmentedControls["analysis-text-weight"].buttons["Regular"].tap()
        app.switches["analysis-text-background"].coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        let textStyle = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); textStyle.name = "Player text alignment size weight and background controls"; textStyle.lifetime = .keepAlways; add(textStyle)
        app.buttons["analysis-apply-player-effects"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].isEnabled, "Adding text reuses the saved track synchronously")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).count, 2)
        effects.tap()
        XCTAssertTrue(app.segmentedControls["analysis-text-alignment"].buttons["Right"].isSelected)
        XCTAssertEqual(app.switches["analysis-player-ring"].value as? String, "1")
        XCTAssertEqual(app.switches["analysis-player-label"].value as? String, "1")
        app.switches["analysis-player-spotlight"].coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        let combined = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); combined.name = "Unified Player panel combines ring spotlight and name label"; combined.lifetime = .keepAlways; add(combined)
        app.buttons["analysis-apply-player-effects"].tap()
        XCTAssertTrue(app.buttons["save-analysis-workspace"].isEnabled, "Spotlight also reuses the same track")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).count, 3)
        let reused = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); reused.name = "One saved player track reused by ring label and spotlight"; reused.lifetime = .keepAlways; add(reused)
        app.buttons["analysis-clip-tracks"].tap()
        app.buttons["analysis-track-new-player"].tap()
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
        let secondFrame = canvas.frame
        let secondHeight = min(secondFrame.height, secondFrame.width * 9 / 16)
        let secondTarget = CGPoint(x: secondFrame.midX + secondHeight * 16 / 9 * (0.685 - 0.5),
                                   y: secondFrame.midY + secondHeight * (0.53 - 0.5))
        let secondPlayer = try XCTUnwrap(candidates.allElementsBoundByIndex.min {
            hypot($0.frame.midX - secondTarget.x, $0.frame.midY - secondTarget.y) < hypot($1.frame.midX - secondTarget.x, $1.frame.midY - secondTarget.y)
        })
        secondPlayer.tap()
        let save = app.buttons["save-analysis-workspace"]
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 90))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).count, 3, "Tracking a second player must not create an effect")
        app.buttons["analysis-clip-tracks"].tap()
        XCTAssertTrue(savedPlayer("Player 1").exists)
        XCTAssertTrue(savedPlayer("Player 2").exists)
        app.buttons["analysis-manage-player-tracks"].tap()
        let names = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-player-name-"))
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(names.count, 2)
        let manager = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); manager.name = "Two independent player tracks with coverage and correction controls"; manager.lifetime = .keepAlways; add(manager)
        names.element(boundBy: 1).tap(); names.element(boundBy: 1).typeText(" White")
        app.buttons["Done"].tap()
        seekAnalysis(to: 3, ruler: ruler, app: app)
        app.buttons["analysis-clip-tracks"].tap()
        savedPlayer("Player 2 White").tap()
        effects.tap()
        app.buttons["analysis-apply-player-effects"].tap()
        XCTAssertTrue(save.isEnabled, "Second player's ring must reuse its own track without processing")
        XCTAssertEqual(app.staticTexts["analysis-active-player-track"].label, "Player 2 White")
        seekAnalysis(to: 5, ruler: ruler, app: app)
        let twoPlayers = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); twoPlayers.name = "Two independent players following at five seconds"; twoPlayers.lifetime = .keepAlways; add(twoPlayers)
        app.buttons["analysis-clip-tracks"].tap()
        savedPlayer("Player 1").tap()
        XCTAssertEqual(app.staticTexts["analysis-active-player-track"].label, "Player 1")
        seekAnalysis(to: 20, ruler: ruler, app: app)
        let resume = app.buttons["analysis-resume-player"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let absent = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); absent.name = "Absent player keeps its identity and offers Resume here"; absent.lifetime = .keepAlways; add(absent)
        resume.tap()
        XCTAssertTrue(app.buttons["Cancel pick"].waitForExistence(timeout: 5))
        app.buttons["Cancel pick"].tap()
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testLayerTimelineAddsEditsAndMovesKeyframes() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else {
            throw XCTSkip("Opt in on the fixture device")
        }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(analysisRecordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        let canvas = app.otherElements.matching(identifier: "analysis-workspace-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-arrow"].tap()
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = canvas.frame
            let height = min(frame.height, frame.width * 9 / 16), width = height * 16 / 9
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (frame.width - width) / 2 + width * x, dy: (frame.height - height) / 2 + height * y))
        }
        point(0.3, 0.5).press(forDuration: 0.1, thenDragTo: point(0.6, 0.6))
        let modes = app.buttons["analysis-motion-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5)); modes.tap(); app.buttons["Keyframes"].tap()
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        seekAnalysis(to: 2, ruler: ruler, app: app)
        app.buttons["analysis-add-keyframe"].tap()
        let keyframes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-keyframe-"))
        XCTAssertGreaterThanOrEqual(keyframes.count, 2)
        point(0.45, 0.55).press(forDuration: 0.1, thenDragTo: point(0.52, 0.70))
        for _ in 0..<2 { app.buttons["analysis-timeline-zoom-in"].tap() }
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        let timingBefore = bar.value as? String
        // Grab the upper band, away from the diamond at the bar's midpoint.
        let middle = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 25, dy: 0)))
        XCTAssertNotEqual(bar.value as? String, timingBefore)
        app.buttons["Previous keyframe"].tap()
        XCTAssertTrue(app.buttons["Delete keyframe"].isEnabled)
        let beforeKeyframeMove = app.staticTexts["analysis-current-time"].label
        let beforeDiamond = keyframes.firstMatch.value as? String
        let beforeKeyframeLayerTiming = bar.value as? String
        let diamond = keyframes.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        diamond.press(forDuration: 0.1, thenDragTo: diamond.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertNotEqual(keyframes.firstMatch.value as? String, beforeDiamond)
        XCTAssertEqual(bar.value as? String, beforeKeyframeLayerTiming)
        XCTAssertNotEqual(app.staticTexts["analysis-current-time"].label, beforeKeyframeMove)
        let beforeTrim = bar.value as? String
        let handle = app.descendants(matching: .any).matching(identifier: "analysis-layer-end").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 20, dy: 0)))
        XCTAssertNotEqual(bar.value as? String, beforeTrim)
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-ellipse"].tap()
        point(0.65, 0.45).press(forDuration: 0.1, thenDragTo: point(0.78, 0.7))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).count, 2)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "analysis-layer-", "Arrow")).firstMatch.tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Layer timeline with authored motion keyframes"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testEditorOffersDedicatedVideoAndFreezeAnalysisWorkspaces() throws {
        guard let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_CAMELOT_SAMPLE_VIDEO to a local video to run editor analysis tests")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-seedSampleVideo", sample, "-seedEventCount", "3"]
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 5) { app.buttons["Continue offline"].tap() }
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " events,")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        XCTAssertTrue(app.navigationBars["Untitled video"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 5)); app.buttons["open-analysis"].tap()
        let videoAnalysis = app.buttons["open-video-analysis"]
        XCTAssertTrue(videoAnalysis.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-freeze-analysis"].exists)
        videoAnalysis.tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        app.buttons["analysis-tools"].tap()
        XCTAssertTrue(app.buttons["analysis-tool-arrow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["analysis-tool-pen"].exists)
        XCTAssertTrue(app.buttons["analysis-tool-select"].exists)
        app.buttons["analysis-tool-select"].tap()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["analysis-tool-arrow"])
        wait(for: [dismissed], timeout: 5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Video analysis workspace"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["cancel-analysis-workspace"].tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 5)); app.buttons["open-analysis"].tap()
        XCTAssertTrue(app.buttons["open-freeze-analysis"].waitForExistence(timeout: 5))
        app.buttons["open-freeze-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Freeze-frame analysis"].exists)
    }
}
