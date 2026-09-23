import XCTest

final class AnalysisCompactUITests: XCTestCase {
    @MainActor
    func testZoomKeepsLayerStartAlignedWithRulerWithoutSaving() throws {
        let app = try openAnalysis()
        defer { app.closeAnalysisWithoutSaving() }
        if app.buttons["analysis-timeline-fit"].exists { app.buttons["analysis-timeline-fit"].tap() }
        let timeline = app.otherElements["analysis-layer-timeline"]
        let ruler = app.otherElements["analysis-time-ruler"]
        for _ in 0..<3 {
            let origin = ruler.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5))
            origin.press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)))
        }
        XCTAssertEqual(ruler.value as? String, "0.000 seconds")
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists { banner.swipeUp() }
        app.chooseDrawingTool("rectangle")
        let canvas = app.otherElements["analysis-preview-touch-surface"]
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.4)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.6, dy: 0.6)))
        let handle = app.otherElements["analysis-layer-start"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // A new drawing lasts four seconds: four 2× pinches make it wider than the screen.
        for step in 0..<5 {
            XCTAssertEqual(handle.frame.midX, ruler.frame.midX, accuracy: 2,
                           "The layer's start must stay at 0:00 as zoom changes")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Timeline zoom step \(step)"; shot.lifetime = .keepAlways; add(shot)
            if step < 4 { timeline.pinch(withScale: 2, velocity: 1) }
        }
    }

    @MainActor
    func testReviewableAutomaticFieldAlignmentAndFrameChoiceWithoutSaving() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        // Find the pitch / Try again also searches the clip for a clearer frame.
        let find = app.buttons["ground-auto-align"]
        find.tap()
        _ = find.wait(for: \.isEnabled, toEqual: false, timeout: 5)
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        let preview = app.otherElements["ground-preview"]
        let status = app.otherElements.matching(NSPredicate(format: "identifier IN %@", ["ground-status", "ground-circle-status", "ground-line-status"])).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let quality = app.otherElements["ground-quality"]
        if quality.exists {
            // Snapped proposal: numbered handles are editable and nudgeable.
            XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
            XCTAssertTrue(app.buttons["ground-point-0"].exists)
            print("PHONE_SNAP_QUALITY " + (quality.value as? String ?? ""))
        } else {
            // Unsnapped circle proposal keeps the centre-spot workflow.
            XCTAssertTrue(app.buttons["ground-circle-center"].exists)
            XCTAssertTrue((preview.value as? String ?? "").contains("1 points"))
        }
        let proposal = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); proposal.name = "Detected field on iPhone"; proposal.lifetime = .keepAlways; add(proposal)
        app.buttons["ground-fine-tune"].tap()
        XCTAssertTrue(app.buttons["ground-nudge-right"].isHittable)
        app.buttons["ground-nudge-right"].tap()
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled, "A moved reference needs alignment confirmation")
        XCTAssertFalse(quality.exists, "Editing a snapped alignment clears its quality until the next snap")
        XCTAssertTrue(app.buttons["ground-snap"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["ground-snap"].tap()
        XCTAssertTrue(quality.waitForExistence(timeout: 30))
        print("PHONE_RESNAP_QUALITY " + (quality.value as? String ?? ""))
        XCTAssertTrue(app.buttons["ground-apply"].isEnabled)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Snapped field alignment on iPhone"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["ground-snap"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "Field setup in landscape"; image.lifetime = .keepAlways; add(image)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["ground-cancel"].tap(); app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testVerticalLayerScrollingFrameStepsAndFullWidthFilmstripWithoutSaving() throws {
        let app = try openAnalysis()
        defer { app.closeAnalysisWithoutSaving() }
        let timeline = app.otherElements["analysis-layer-timeline"]
        let ruler = app.otherElements["analysis-time-ruler"]
        func seconds() throws -> Double {
            try XCTUnwrap(Double((ruler.value as? String ?? "").replacingOccurrences(of: " seconds", with: "")))
        }
        let initial = try seconds()
        let next = app.buttons["analysis-next-frame"], previous = app.buttons["analysis-previous-frame"]
        XCTAssertTrue(next.isHittable); XCTAssertTrue(previous.isHittable)
        next.tap()
        XCTAssertEqual(try seconds(), initial + 1 / 30, accuracy: 0.002)
        previous.tap()
        XCTAssertEqual(try seconds(), initial, accuracy: 0.002)

        ruler.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)).tap()
        timeline.pinch(withScale: 2, velocity: 1)
        let filmstrip = app.otherElements["analysis-source-filmstrip"]
        XCTAssertEqual(filmstrip.frame.minX, timeline.frame.minX, accuracy: 1)
        XCTAssertEqual(filmstrip.frame.maxX, timeline.frame.maxX, accuracy: 1)
        let layers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-"))
        let initialCount = layers.count
        let surface = app.otherElements["analysis-preview-touch-surface"]
        for index in 0..<8 {
            app.chooseDrawingTool("pen")
            let bounds = surface.frame, height = min(bounds.height, bounds.width * 9 / 16)
            let y = (bounds.height - height) / 2 + height * (0.25 + Double(index) * 0.06)
            let start = surface.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: bounds.width * 0.2, dy: y))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: bounds.width * 0.45, dy: height * 0.04)))
        }
        XCTAssertEqual(layers.count, initialCount + 8)
        let timings = Dictionary(uniqueKeysWithValues: layers.allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") })
        let timeBefore = timeline.value as? String
        let firstLayer = layers.firstMatch
        let originalY = firstLayer.frame.minY
        let tracks = app.scrollViews["analysis-vertical-tracks"]
        // Start on a selected drawing, not just empty padding.
        let selectedRow = try XCTUnwrap(layers.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY > tracks.frame.minY + 20 }))
        let rowPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: timeline.frame.midX + 35, dy: selectedRow.frame.midY))
        rowPoint.press(forDuration: 0.1, thenDragTo: rowPoint.withOffset(.init(dx: 2, dy: -110)))
        XCTAssertLessThan(firstLayer.frame.minY, originalY - 40, "Vertical drags over drawings must scroll tracks")
        XCTAssertEqual(timeline.value as? String, timeBefore, "Vertical scrolling must not scrub time")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: layers.allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") }), timings,
                       "Vertical scrolling must not move or trim drawings")
        tracks.swipeUp()
        let last = layers.element(boundBy: layers.count - 1)
        XCTAssertTrue(last.isHittable, "The oldest layer must remain reachable")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Analysis vertically scrolled drawing layers on iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        tracks.swipeDown(); tracks.swipeDown()
        XCTAssertTrue(filmstrip.isHittable)
        let top = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        top.name = "Analysis full-width thumbnails and frame controls on iPhone"; top.lifetime = .keepAlways; add(top)
        let scrubStart = timeline.value as? String
        let filmPoint = filmstrip.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5))
        filmPoint.press(forDuration: 0.1, thenDragTo: filmPoint.withOffset(.init(dx: -35, dy: 1)))
        XCTAssertNotEqual(timeline.value as? String, scrubStart, "Filmstrip horizontal scrubbing remains available")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: layers.allElementsBoundByIndex.map { ($0.identifier, $0.value as? String ?? "") }), timings)
        let lastScrollTime = timeline.value as? String
        let filmY = filmstrip.frame.minY
        filmstrip.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: filmstrip.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).withOffset(.init(dx: 1, dy: -90)))
        XCTAssertLessThan(filmstrip.frame.minY, filmY - 30, "A vertical drag starting on thumbnails scrolls layers")
        XCTAssertEqual(timeline.value as? String, lastScrollTime)
    }

    @MainActor
    func testShortTrimsKeyframesAndLandscapeTimelineWithoutSaving() throws {
        let app = try openAnalysis()
        let ruler = app.otherElements["analysis-time-ruler"]
        let timeline = app.otherElements["analysis-layer-timeline"]
        ruler.coordinate(withNormalizedOffset: .init(dx: 0.65, dy: 0.5)).tap()
        app.chooseDrawingTool("arrow")
        let canvas = app.otherElements["analysis-preview-touch-surface"]
        let size = canvas.frame.size, height = min(size.height, size.width * 9 / 16)
        let start = canvas.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: size.width * 0.3, dy: (size.height - height) / 2 + height * 0.45))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: size.width * 0.35, dy: height * 0.2)))
        let layer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        let initial = layer.value as? String
        let handle = app.otherElements["analysis-layer-start"]
        let trim = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.3))
        trim.press(forDuration: 0.1, thenDragTo: trim.withOffset(.init(dx: -9, dy: 0)))
        XCTAssertNotEqual(layer.value as? String, initial, "Small horizontal handle adjustments still work")
        app.buttons["analysis-motion-mode"].tap(); app.buttons["Animate by hand"].tap()
        timeline.pinch(withScale: 4, velocity: 1)
        let keyframe = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-keyframe-")).firstMatch
        let keyTime = keyframe.value as? String
        let timing = layer.value as? String
        let diamond = keyframe.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        diamond.press(forDuration: 0.1, thenDragTo: diamond.withOffset(.init(dx: 18, dy: 0)))
        XCTAssertNotEqual(keyframe.value as? String, keyTime)
        XCTAssertEqual(layer.value as? String, timing)
        let span = app.visibleTimelineSpan
        timeline.pinch(withScale: 1.4, velocity: 1)
        XCTAssertNotEqual(app.visibleTimelineSpan, span)
        XCTAssertEqual(layer.value as? String, timing, "Pinching must not move the selected layer")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let filmstrip = app.otherElements["analysis-source-filmstrip"]
        XCTAssertTrue(filmstrip.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["analysis-next-frame"].isHittable)
        XCTAssertTrue(app.buttons["analysis-previous-frame"].isHittable)
        XCTAssertEqual(filmstrip.frame.minX, timeline.frame.minX, accuracy: 1)
        // Landscape backgrounds extend behind the safe area; the time ruler
        // identifies the actual usable viewport, with 24pt handle clearance.
        XCTAssertEqual(filmstrip.frame.maxX, ruler.frame.maxX + 24, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Analysis frame controls and full-width filmstrip in landscape"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testEditorLayoutAndFieldFrameSelectionWithoutSaving() throws {
        let app = try openAnalysis(captureEditor: true)
        XCTAssertTrue(app.buttons["analysis-task-pitch"].exists)
        XCTAssertFalse(app.segmentedControls["analysis-workspace-switch"].exists)
        XCTAssertTrue(app.otherElements["analysis-source-filmstrip"].exists)
        let canvas = app.otherElements["analysis-workspace-canvas"]
        let divider = try XCTUnwrap(app.otherElements.matching(identifier: "resize-workspace")
            .allElementsBoundByIndex.last(where: \.isHittable))
        XCTAssertTrue(divider.exists)
        let beforeSize = divider.value as? String
        let grip = divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.3, thenDragTo: grip.withOffset(.init(dx: 0, dy: -55)))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Analyze uses editor preview and filmstrip workspace"; portrait.lifetime = .keepAlways; add(portrait)
        XCTAssertNotEqual(divider.value as? String, beforeSize)
        app.openPitchSetup()
        app.waitForPitchDetection()
        let clock = app.staticTexts["ground-frame-time"]
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        let initial = try XCTUnwrap(Double(clock.value as? String ?? ""))
        app.buttons["ground-second-forward"].tap()
        XCTAssertEqual(try XCTUnwrap(Double(clock.value as? String ?? "")), initial + 1, accuracy: 0.04)
        app.buttons["ground-frame-forward"].tap()
        XCTAssertEqual(try XCTUnwrap(Double(clock.value as? String ?? "")), initial + 1 + 1 / 30, accuracy: 0.01)
        app.sliders["ground-frame-scrubber"].adjust(toNormalizedSliderPosition: 0.5)
        let chosen = try XCTUnwrap(Double(clock.value as? String ?? ""))
        XCTAssertGreaterThan(chosen, initial + 10)
        app.openGroundAdjustments()
        XCTAssertTrue(app.buttons["ground-nudge-right"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled)
        app.buttons["ground-nudge-right"].tap()
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); frame.name = "Choose field reference frame inside placement"; frame.lifetime = .keepAlways; add(frame)
        app.buttons["ground-apply"].tap()
        app.openPitchSetup()
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(Double(clock.value as? String ?? "")), chosen, accuracy: 0.04)
        app.buttons["ground-cancel"].tap()
        app.chooseDrawingTool("pen")
        let bounds = canvas.frame, imageHeight = min(bounds.height, bounds.width * 9 / 16)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: bounds.width * x, dy: (bounds.height - imageHeight) / 2 + imageHeight * y))
        }
        point(0.25, 0.55).press(forDuration: 0.1, thenDragTo: point(0.65, 0.65))
        XCTAssertTrue(app.buttons["analysis-motion-mode"].waitForExistence(timeout: 5))
        app.otherElements["analysis-layer-timeline"].pinch(withScale: 2, velocity: 1)
        let zoom = app.visibleTimelineSpan
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); selected.name = "Analysis selected layer matches editor timeline"; selected.lifetime = .keepAlways; add(selected)
        let layer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5)); layer.tap()
        XCTAssertGreaterThanOrEqual(layer.frame.minY, app.otherElements["analysis-source-filmstrip"].frame.maxY)
        XCTAssertFalse(app.segmentedControls["analysis-workspace-switch"].exists)
        XCTAssertEqual(app.visibleTimelineSpan, zoom, accuracy: 0.01)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.otherElements["analysis-source-filmstrip"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(divider.frame.height, divider.frame.width)
        XCTAssertTrue(app.buttons["analysis-play-pause"].isHittable)
        let endHandle = app.otherElements["analysis-layer-end"]
        XCTAssertTrue(endHandle.isHittable)
        XCTAssertLessThanOrEqual(endHandle.frame.maxY, app.otherElements["analysis-layer-timeline"].frame.maxY + 1)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Analyze editor-style landscape sidebar"; landscape.lifetime = .keepAlways; add(landscape)
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testFieldAndLayersShareOneFullClipCameraWithoutSaving() throws {
        let app = try openAnalysis()
        let timeline = app.otherElements["analysis-layer-timeline"]
        timeline.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: timeline.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.45)))
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String == "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap(); app.buttons["ground-apply"].tap()
        // A moving camera starts the one full-clip camera pass; Done waits for it.
        XCTAssertTrue(app.buttons["save-analysis-workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 90))
        if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        app.showPitchLines()
        XCTAssertTrue(app.otherElements["analysis-field-preview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["analysis-field-preview-status"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Field uses shared full clip camera on iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testFieldPixelNudgesMoveOnlySelectedPointAndWorkWhenZoomed() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        let preview = app.otherElements["ground-preview"]
        func points() throws -> [CGPoint] {
            let value = try XCTUnwrap(preview.value as? String)
            return try value.components(separatedBy: "; ").dropFirst(2).map { pair in
                let values = pair.split(separator: ",").compactMap { Double($0) }
                XCTAssertEqual(values.count, 2)
                return CGPoint(x: try XCTUnwrap(values.first), y: try XCTUnwrap(values.last))
            }
        }
        let original = try points(); XCTAssertEqual(original.count, 4)
        app.buttons["ground-point-1"].tap()
        let right = app.buttons["ground-nudge-right"], down = app.buttons["ground-nudge-down"]
        for direction in ["left", "up", "down", "right"] {
            let button = app.buttons["ground-nudge-\(direction)"]
            XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        right.tap(); down.tap()
        let moved = try points()
        XCTAssertEqual(moved[1].x - original[1].x, 1 / 1920, accuracy: 0.00011)
        XCTAssertEqual(moved[1].y - original[1].y, 1 / 1080, accuracy: 0.00011)
        for i in [0, 2, 3] { XCTAssertEqual(moved[i], original[i]) }
        XCTAssertTrue(app.otherElements["ground-point-loupe"].exists)
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled, "A moved reference needs alignment confirmation")
        preview.pinch(withScale: 2, velocity: 1)
        app.buttons["ground-nudge-left"].tap(); app.buttons["ground-nudge-up"].tap()
        let restored = try points()
        for i in original.indices {
            XCTAssertEqual(restored[i].x, original[i].x, accuracy: 0.00011)
            XCTAssertEqual(restored[i].y, original[i].y, accuracy: 0.00011)
        }
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Pixel nudge controls and loupe on zoomed iPhone field preview"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(right.waitForExistence(timeout: 5)); XCTAssertTrue(right.isHittable); right.tap()
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Field point fine tuning in landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["ground-cancel"].tap(); app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testGroundedRectangleCanBeResizedOnPhoneWithoutSaving() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        app.buttons["ground-apply"].tap()
        app.chooseDrawingTool("rectangle")
        let surface = app.otherElements["analysis-preview-touch-surface"]
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let bounds = surface.frame, height = min(bounds.height, bounds.width * 9 / 16)
            return surface.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: bounds.width * x, dy: (bounds.height - height) / 2 + height * y))
        }
        point(0.35, 0.55).press(forDuration: 0.1, thenDragTo: point(0.65, 0.8))
        app.buttons["analysis-drawing-style"].tap()
        let ground = app.switches["analysis-ground-effect"]
        reveal(ground, in: app); XCTAssertTrue(ground.isEnabled)
        ground.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(ground.value as? String, "1")
        app.buttons["Done"].tap()
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "Grounded rectangle and four projected handles before resize"; before.lifetime = .keepAlways; add(before)
        point(0.35, 0.55).press(forDuration: 0.1, thenDragTo: point(0.28, 0.60))
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "Grounded rectangle after resizing first corner"; after.lifetime = .keepAlways; add(after)
        app.buttons["analysis-drawing-style"].tap(); reveal(ground, in: app)
        XCTAssertEqual(ground.value as? String, "1")
        app.buttons["Done"].tap(); app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testFieldPreviewCanBeComparedWhileScrubbingWithoutSaving() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(fixed.value as? String, "1")
        app.buttons["Done"].tap()
        app.buttons["ground-apply"].tap()
        app.showPitchLines()
        let preview = app.otherElements["analysis-field-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Draft field overlay preview on iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        let timeline = app.otherElements["analysis-layer-timeline"]
        timeline.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: timeline.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.45)))
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(app.otherElements["analysis-field-preview-status"].exists, "Fixed-camera draft remains available while scrubbing")
        app.togglePitchLines(); XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        app.togglePitchLines(); XCTAssertTrue(preview.waitForExistence(timeout: 3))
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testGroundedWallOptionMetricHeightAndPreviewOnPhone() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        // Draft-only approximate reference for UI verification; never saved to
        // the user's project and not a claim that this is a calibrated pitch.
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(fixed.value as? String, "1")
        app.buttons["Done"].tap()
        app.buttons["ground-apply"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        app.showAnalysisTasks()
        app.buttons["analysis-task-draw"].tap()
        let line = app.buttons["analysis-tool-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 5)); XCTAssertTrue(line.isEnabled); line.tap()
        let surface = app.otherElements["analysis-preview-touch-surface"]
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let bounds = surface.frame, height = min(bounds.height, bounds.width * 9 / 16)
            return surface.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: bounds.width * x, dy: (bounds.height - height) / 2 + height * y))
        }
        point(0.25, 0.88).press(forDuration: 0.1, thenDragTo: point(0.45, 0.52))
        app.buttons["analysis-drawing-style"].tap()
        let effect = app.segmentedControls["analysis-effect-style"]
        reveal(effect, in: app); effect.buttons["Wall"].tap()
        let ground = app.switches["analysis-ground-effect"]
        XCTAssertTrue(ground.waitForExistence(timeout: 5)); XCTAssertTrue(ground.isEnabled)
        ground.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        let height = app.sliders["analysis-wall-height-meters"]
        XCTAssertTrue(height.waitForExistence(timeout: 5)); reveal(height, in: app)
        XCTAssertTrue(height.isHittable); height.adjust(toNormalizedSliderPosition: 0.35)
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Ground to field and metric wall height on iPhone"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["Done"].tap()
        let rendered = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); rendered.name = "Grounded near-to-far wall in phone preview"; rendered.lifetime = .keepAlways; add(rendered)
        app.buttons["analysis-drawing-style"].tap()
        reveal(ground, in: app)
        XCTAssertEqual(ground.value as? String, "1")
        ground.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["analysis-wall-height"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.closeAnalysisWithoutSaving()
    }

    private var recordingID: String { ProcessInfo.processInfo.environment["CAMELOT_ANALYSIS_RECORDING_ID"] ?? "EBB12192-62DB-495B-A6CE-218F0C420A74" }

    @MainActor
    private func openAnalysis(captureEditor: Bool = false) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else {
            throw XCTSkip("Opt in on the fixture device")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let source = app.buttons["source-\(recordingID)"]
        for _ in 0..<8 {
            if source.exists && source.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10))
        if captureEditor {
            let baseline = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); baseline.name = "Main editor layout reference"; baseline.lifetime = .keepAlways; add(baseline)
        }
        app.buttons["open-analysis"].tap()
        app.buttons["open-video-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        if app.alerts["Analysis"].waitForExistence(timeout: 3) { app.alerts["Analysis"].buttons["OK"].tap() }
        return app
    }

    @MainActor
    func testCompactHeaderAndLoupeInspectorStayUsableOnPhone() throws {
        let app = try openAnalysis()
        let header = app.buttons["save-analysis-workspace"]
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
        app.chooseDrawingTool("loupe")
        // Empty frame area intentionally creates a static, timed loupe without
        // selecting or changing a saved player track.
        imagePoint(0.50, 0.90).tap()
        app.buttons["analysis-drawing-style"].tap()
        let magnification = app.sliders["analysis-loupe-magnification"]
        let size = app.sliders["analysis-loupe-size"]
        XCTAssertTrue(magnification.waitForExistence(timeout: 5)); XCTAssertTrue(size.exists)
        reveal(size, in: app)
        magnification.adjust(toNormalizedSliderPosition: 0.65)
        size.adjust(toNormalizedSliderPosition: 0.55)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Compact phone loupe inspector"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].tap()
        let workspace = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        workspace.name = "Workspace after loupe inspector"; workspace.lifetime = .keepAlways; add(workspace)
        app.closeAnalysisWithoutSaving()
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
        app.chooseDrawingTool("zone")
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
        app.chooseDrawingTool("arrow")
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
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        let landmark = app.buttons["ground-landmark-picker"]
        XCTAssertTrue(landmark.waitForExistence(timeout: 8)); landmark.tap()
        XCTAssertTrue(app.buttons["Goal width · local scale"].waitForExistence(timeout: 3)); app.buttons["Goal width · local scale"].tap()
        app.buttons["ground-settings"].tap()
        XCTAssertEqual(app.textFields["ground-length"].value as? String, "7.32")
        app.buttons["Done"].tap()
        landmark.tap(); app.buttons["Penalty area"].tap()
        app.buttons["ground-settings"].tap()
        XCTAssertEqual(app.textFields["ground-length"].value as? String, "40.32")
        XCTAssertEqual(app.textFields["ground-width"].value as? String, "16.5")
        app.buttons["Done"].tap()
        app.buttons["ground-cancel"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testLiveFieldOverlayCanBeAlignedComparedAndCancelled() throws {
        let app = try openAnalysis()
        app.openPitchSetup()
        app.waitForPitchDetection()
        app.openGroundAdjustments()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue((preview.value as? String ?? "").contains("Overlay visible; 4 points"))
        for index in 0..<4 {
            let button = app.buttons["ground-point-\(index)"]
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let before = preview.value as? String
        app.buttons["ground-point-0"].tap()
        let corner = preview.coordinate(withNormalizedOffset: .init(dx: 0.65, dy: 0.45))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(.init(dx: -22, dy: 10)))
        XCTAssertNotEqual(preview.value as? String, before)
        let aligned = preview.value as? String
        preview.pinch(withScale: 1.4, velocity: 1)
        XCTAssertEqual(preview.value as? String, aligned, "Pinching must not move alignment points")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Live field overlay with numbered alignment handles"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["ground-overlay-toggle"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("Overlay hidden"))
        app.buttons["ground-overlay-toggle"].tap()
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Centre circle"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
        app.buttons["ground-settings"].tap()
        XCTAssertEqual(app.textFields["ground-length"].value as? String, "18.3")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["ground-apply"].isEnabled)
        app.buttons["ground-cancel"].tap()
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    func testTimelineMovesUnderFixedPlayheadAndPreviewPinchDoesNotDraw() throws {
        let app = try openAnalysis()
        let canvas = app.otherElements["analysis-workspace-canvas"]
        let ruler = app.descendants(matching: .any).matching(identifier: "analysis-time-ruler").firstMatch
        let playhead = app.descendants(matching: .any).matching(identifier: "analysis-playhead").firstMatch
        let x = playhead.frame.midX
        XCTAssertGreaterThanOrEqual(ruler.frame.width, canvas.frame.width - 50, "Names belong inside clips, not in a separate column")
        XCTAssertEqual(app.buttons["analysis-play-pause"].frame.height, 44, accuracy: 1)
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
        app.chooseDrawingTool("pen")
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
        let timeline = app.otherElements["analysis-layer-timeline"]
        timeline.pinch(withScale: 2, velocity: 1)
        let bar = bars.firstMatch, timing = bars.firstMatch.value as? String
        let handle = app.descendants(matching: .any).matching(identifier: "analysis-layer-start").firstMatch
        let handlePoint = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        handlePoint.press(forDuration: 0.1, thenDragTo: handlePoint.withOffset(.init(dx: -10, dy: 0)))
        XCTAssertNotEqual(bar.value as? String, timing, "The fixed playhead must not block the In handle")
        let trimmed = bar.value as? String
        timeline.pinch(withScale: 1.4, velocity: 1)
        XCTAssertEqual(bar.value as? String, trimmed, "Pinching the time axis must not edit the layer")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Fixed playhead and gesture-only preview"; attachment.lifetime = .keepAlways; add(attachment)
        app.closeAnalysisWithoutSaving()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.collectionViews["analysis-inspector-form"].swipeUp()
        }
    }
}

// MARK: - Analyse workspace steps shared with EditorAnalysisUITests and FieldSetupUITests

extension XCUIApplication {
    /// Ends the task in progress and clears the selection so the task tiles show.
    @MainActor
    func showAnalysisTasks() {
        for id in ["analysis-prompt-cancel", "analysis-player-prompt-cancel", "analysis-text-prompt-cancel",
                   "analysis-zoom-prompt-cancel", "analysis-correct-tracking-cancel", "analysis-draw-done"] where buttons[id].exists {
            buttons[id].tap()
        }
        let draw = buttons["analysis-task-draw"]
        // Tap an empty corner of the video to deselect.
        if !draw.exists { otherElements["analysis-preview-touch-surface"].coordinate(withNormalizedOffset: .init(dx: 0.96, dy: 0.08)).tap() }
        XCTAssertTrue(draw.waitForExistence(timeout: 3), "The task tiles show once nothing is selected")
    }

    /// Draw, then one shape from the palette (`arrow`, `pen`, `zone`, …).
    @MainActor
    func chooseDrawingTool(_ shape: String) {
        showAnalysisTasks()
        buttons["analysis-task-draw"].tap()
        let tool = buttons["analysis-tool-\(shape)"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5)); tool.tap()
    }

    /// Pitch opens "Line up the pitch" directly for a new setup; with a saved
    /// one it asks first, and "Line up the pitch again" opens it.
    @MainActor
    func openPitchSetup() {
        showAnalysisTasks()
        buttons["analysis-task-pitch"].tap()
        let again = buttons["analysis-tool-measure"]
        if again.waitForExistence(timeout: 2) { again.tap() }
        XCTAssertTrue(otherElements["ground-preview"].waitForExistence(timeout: 10))
    }

    /// Show or hide the pitch lines once the pitch is lined up.
    @MainActor
    func togglePitchLines() {
        showAnalysisTasks()
        buttons["analysis-task-pitch"].tap()
        let toggle = buttons["analysis-tool-field-preview"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3)); toggle.tap()
    }

    @MainActor
    func showPitchLines() {
        if !otherElements["analysis-field-preview"].exists { togglePitchLines() }
    }

    /// A new setup starts finding the pitch on open; Find the pitch is
    /// enabled again once that (or any later search) has finished.
    @MainActor
    func waitForPitchDetection(timeout: TimeInterval = 60) {
        XCTAssertTrue(buttons["ground-auto-align"].wait(for: \.isEnabled, toEqual: true, timeout: timeout))
    }

    /// Adjust by hand: method, goal side, snap, overlay, loupe, settings, handles and nudges.
    @MainActor
    func openGroundAdjustments() {
        if !buttons["ground-snap"].exists { buttons["ground-adjustments"].tap() }
        XCTAssertTrue(buttons["ground-snap"].waitForExistence(timeout: 5))
    }

    /// Close without saving, confirming the discard when something was edited.
    @MainActor
    func closeAnalysisWithoutSaving() {
        buttons["cancel-analysis-workspace"].tap()
        let discard = buttons["Discard changes"]
        if discard.waitForExistence(timeout: 3) { discard.tap() }
    }

    /// Seconds shown across the timeline; pinching in makes it shorter.
    @MainActor
    var visibleTimelineSpan: Double {
        // "Visible 1.00 to 12.00 seconds"
        let bounds = (otherElements["analysis-layer-timeline"].value as? String ?? "").split(separator: " ").compactMap { Double($0) }
        return bounds.count == 2 ? bounds[1] - bounds[0] : 0
    }
}
