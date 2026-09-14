import XCTest

final class AnalysisCompactUITests: XCTestCase {
    private var recordingID: String { ProcessInfo.processInfo.environment["CAMELOT_ANALYSIS_RECORDING_ID"] ?? "EBB12192-62DB-495B-A6CE-218F0C420A74" }

    @MainActor
    private func openAnalysis() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else {
            throw XCTSkip("Opt in on the fixture device")
        }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(recordingID)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-video-analysis"].waitForExistence(timeout: 10)); app.buttons["open-video-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        if app.alerts["Analysis"].waitForExistence(timeout: 3) { app.alerts["Analysis"].buttons["OK"].tap() }
        return app
    }

    @MainActor
    func testCompactHeaderAndLoupeInspectorStayUsableOnPhone() throws {
        let app = try openAnalysis()
        let header = app.otherElements["analysis-compact-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        // The container includes the status-bar safe area; controls don't.
        let close = app.buttons["cancel-analysis-workspace"]
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertLessThanOrEqual(close.frame.height, 48)

        let canvas = app.otherElements["analysis-workspace-canvas"]
        func imagePoint(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let bounds = canvas.frame
            let imageHeight = min(bounds.height, bounds.width * 9 / 16)
            let imageWidth = imageHeight * 16 / 9
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: (bounds.width - imageWidth) / 2 + imageWidth * x,
                dy: (bounds.height - imageHeight) / 2 + imageHeight * y))
        }
        let tools = app.scrollViews["analysis-drawing-tools"]
        tools.swipeLeft()
        let loupeTool = app.buttons["analysis-tool-loupe"]
        XCTAssertTrue(loupeTool.waitForExistence(timeout: 5)); loupeTool.tap()
        // Empty frame area intentionally creates a static, timed loupe without
        // selecting or changing a saved player track.
        imagePoint(0.50, 0.90).tap()
        let magnification = app.sliders["analysis-loupe-magnification"]
        let size = app.sliders["analysis-loupe-size"]
        if !magnification.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(magnification.waitForExistence(timeout: 5)); XCTAssertTrue(size.exists)
        magnification.adjust(toNormalizedSliderPosition: 0.65)
        size.adjust(toNormalizedSliderPosition: 0.55)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Compact phone loupe inspector"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].tap()
        let workspace = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        workspace.name = "Workspace after loupe inspector"; workspace.lifetime = .keepAlways; add(workspace)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testPolygonAerialAndLineEndpointControlsAndMeasurementPresetsAreNonSaving() throws {
        let app = try openAnalysis()
        let canvas = app.otherElements["analysis-workspace-canvas"]
        XCTAssertFalse(app.staticTexts["Draw on the video to add a layer"].exists)
        XCTAssertFalse(app.staticTexts["Draw to add a layer · tap its row to edit"].exists)
        func imagePoint(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let bounds = canvas.frame
            let imageHeight = min(bounds.height, bounds.width * 9 / 16)
            let imageWidth = imageHeight * 16 / 9
            return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: (bounds.width - imageWidth) / 2 + imageWidth * x,
                dy: (bounds.height - imageHeight) / 2 + imageHeight * y))
        }
        let tools = app.scrollViews["analysis-drawing-tools"]
        tools.swipeLeft()
        app.buttons["analysis-tool-zone"].tap()
        for point in [CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.66, y: 0.35), CGPoint(x: 0.70, y: 0.70), CGPoint(x: 0.22, y: 0.70)] {
            imagePoint(point.x, point.y).tap()
        }
        XCTAssertTrue(app.buttons["analysis-finish-construction"].waitForExistence(timeout: 5)); app.buttons["analysis-finish-construction"].tap()
        app.buttons["analysis-drawing-style"].tap()
        let effect = app.segmentedControls["analysis-effect-style"]
        reveal(effect, in: app)
        XCTAssertTrue(effect.waitForExistence(timeout: 5))
        XCTAssertTrue(effect.buttons["Aerial"].exists); effect.buttons["Aerial"].tap()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Aerial polygon effect on phone"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].tap()

        // Exercise explicit line pattern and endpoint controls.
        tools.swipeRight()
        app.buttons["analysis-tool-arrow"].tap()
        imagePoint(0.30, 0.48).press(forDuration: 0.1, thenDragTo: imagePoint(0.70, 0.58))
        app.buttons["analysis-drawing-style"].tap()
        let pattern = app.segmentedControls["analysis-line-pattern"]
        reveal(pattern, in: app)
        XCTAssertTrue(pattern.waitForExistence(timeout: 4))
        pattern.buttons["Dashed"].tap()
        app.buttons["analysis-line-start"].tap(); app.buttons["Point"].tap()
        app.buttons["analysis-line-end"].tap(); app.collectionViews.buttons["Circle"].tap()
        app.buttons["Done"].tap()
        let effectWorkspace = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        effectWorkspace.name = "Workspace after aerial polygon and styled line"; effectWorkspace.lifetime = .keepAlways; add(effectWorkspace)

        // Measurement presets prefill dimensions, then Cancel leaves the
        // existing project untouched.
        tools.swipeLeft()
        app.buttons["analysis-tool-measure"].tap()
        let landmark = app.buttons["ground-landmark-picker"]
        XCTAssertTrue(landmark.waitForExistence(timeout: 8)); landmark.tap()
        XCTAssertTrue(app.buttons["Goal width"].waitForExistence(timeout: 3)); app.buttons["Goal width"].tap()
        XCTAssertEqual(app.textFields["ground-length"].value as? String, "7.32")
        landmark.tap(); app.buttons["Penalty area"].tap()
        XCTAssertEqual(app.textFields["ground-length"].value as? String, "40.32")
        XCTAssertEqual(app.textFields["ground-width"].value as? String, "16.5")
        app.buttons["ground-cancel"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testTimelineMovesUnderFixedPlayheadAndPreviewPinchDoesNotDraw() throws {
        let app = try openAnalysis()
        let canvas = app.otherElements["analysis-workspace-canvas"]
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        let playhead = app.descendants(matching: .any).matching(identifier: "analysis-playhead").firstMatch
        let x = playhead.frame.midX
        func seconds() -> Double { Double((ruler.value as? String ?? "").replacingOccurrences(of: " seconds", with: "")) ?? -1 }
        let start = ruler.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: -50, dy: 0)))
        let advanced = seconds()
        XCTAssertGreaterThan(advanced, 1)
        XCTAssertEqual(playhead.frame.midX, x, accuracy: 1)
        let back = ruler.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.5))
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(.init(dx: 25, dy: 0)))
        XCTAssertLessThan(seconds(), advanced)
        XCTAssertEqual(playhead.frame.midX, x, accuracy: 1)

        let bars = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-"))
        let initialCount = bars.count
        app.buttons["analysis-tool-pen"].tap()
        let before = canvas.value as? String
        canvas.pinch(withScale: 1.8, velocity: 1)
        XCTAssertNotEqual(canvas.value as? String, before)
        XCTAssertEqual(bars.count, initialCount, "A pinch must not create a pen layer")
        XCTAssertFalse(app.buttons["analysis-inspect-zoom"].exists)
        XCTAssertFalse(app.buttons["analysis-inspect-zoom-out"].exists)
        XCTAssertTrue(app.buttons["analysis-inspect-fit"].exists)
        app.buttons["analysis-inspect-fit"].tap()
        XCTAssertEqual(canvas.value as? String, before)
        let middle = canvas.coordinate(withNormalizedOffset: .init(dx: 0.4, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(.init(dx: 45, dy: 10)))
        XCTAssertEqual(bars.count, initialCount + 1, "One-finger drawing still works after a pinch")
        app.buttons["analysis-timeline-zoom-in"].tap()
        let bar = bars.firstMatch, timing = bars.firstMatch.value as? String
        let handle = app.descendants(matching: .any).matching(identifier: "analysis-layer-start").firstMatch
        let handlePoint = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        handlePoint.press(forDuration: 0.1, thenDragTo: handlePoint.withOffset(.init(dx: -10, dy: 0)))
        XCTAssertNotEqual(bar.value as? String, timing, "The fixed playhead must not block the In handle")
        let trimmed = bar.value as? String
        app.otherElements["analysis-layer-timeline"].pinch(withScale: 1.4, velocity: 1)
        XCTAssertEqual(bar.value as? String, trimmed, "Pinching the time axis must not edit the layer")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Fixed playhead and gesture-only preview"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.collectionViews["analysis-inspector-form"].swipeUp()
        }
    }
}
