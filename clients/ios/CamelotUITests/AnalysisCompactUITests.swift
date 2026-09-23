import XCTest

final class AnalysisCompactUITests: XCTestCase {
    @MainActor
    func testZoomKeepsLayerStartAlignedWithRulerWithoutSaving() throws {
        let app = try openAnalysis()
        defer { app.buttons["cancel-analysis-workspace"].tap() }
        app.buttons["analysis-timeline-fit"].tap()
        let ruler = app.otherElements["analysis-time-ruler"]
        for _ in 0..<3 {
            let origin = ruler.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5))
            origin.press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)))
        }
        XCTAssertEqual(ruler.value as? String, "0.000 seconds")
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists { banner.swipeUp() }
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-rectangle"].tap()
        let canvas = app.otherElements["analysis-preview-touch-surface"]
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.4)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.6, dy: 0.6)))
        let handle = app.otherElements["analysis-layer-start"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // A new drawing lasts four seconds: 16× makes it wider than the screen.
        for step in 0..<5 {
            XCTAssertEqual(handle.frame.midX, ruler.frame.midX, accuracy: 2,
                           "The layer's start must stay at 0:00 as zoom changes")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Timeline zoom step \(step)"; shot.lifetime = .keepAlways; add(shot)
            if step < 4 { app.buttons["analysis-timeline-zoom-in"].tap() }
        }
    }

    @MainActor
    func testSavedPlayerPickerRebindsExistingLayerWithoutProcessingOrSaving() throws {
        let app = try openAnalysis()
        let tracks = app.buttons["analysis-clip-tracks"]
        let ruler = app.otherElements["analysis-time-ruler"]
        func seekStart() {
            for _ in 0..<10 {
                let current = Double((ruler.value as? String ?? "0").replacingOccurrences(of: " seconds", with: "")) ?? 0
                let position = 0.5 + (3-current)/33
                if position >= 0.05 && position <= 0.95 {
                    ruler.coordinate(withNormalizedOffset: .init(dx: position, dy: 0.5)).tap(); return
                }
                let origin = ruler.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
                origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(.init(dx: min(0.35, max(-0.35, (current-3)/33)) * ruler.frame.width, dy: 0)))
            }
            XCTFail("Could not reach player reference time")
        }
        let canvas = app.otherElements["analysis-workspace-canvas"]
        for x in [0.394, 0.609] {
            seekStart()
            tracks.tap(); app.buttons["analysis-track-new-player"].tap()
            let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-detected-player-"))
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20))
            let target = CGPoint(x: canvas.frame.minX + canvas.frame.width * x, y: canvas.frame.midY)
            let player = try XCTUnwrap(candidates.allElementsBoundByIndex.min {
                hypot($0.frame.midX-target.x, $0.frame.midY-target.y) < hypot($1.frame.midX-target.x, $1.frame.midY-target.y)
            })
            player.tap()
            XCTAssertTrue(tracks.wait(for: \.isEnabled, toEqual: true, timeout: 90))
            if app.alerts["Analysis"].exists { app.alerts["Analysis"].buttons["OK"].tap() }
        }
        tracks.tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "analysis-saved-player-", "Player 1")).firstMatch.tap()
        app.buttons["analysis-player-effects"].tap()
        XCTAssertTrue(app.buttons["analysis-apply-player-effects"].waitForExistence(timeout: 5))
        let effects = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); effects.name = "Compact player effects panel"; effects.lifetime = .keepAlways; add(effects)
        app.buttons["analysis-apply-player-effects"].tap()
        let followed = app.buttons["analysis-followed-player"]
        XCTAssertTrue(followed.waitForExistence(timeout: 10)); followed.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-use-player-"))
        XCTAssertEqual(saved.count, 2)
        let picker = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); picker.name = "Choose another saved player for this layer"; picker.lifetime = .keepAlways; add(picker)
        let second = saved.matching(NSPredicate(format: "label CONTAINS %@", "Player 2")).firstMatch
        XCTAssertTrue(second.isHittable); second.tap()
        XCTAssertTrue(followed.waitForExistence(timeout: 5))
        XCTAssertTrue(followed.label.contains("Player 2")); XCTAssertTrue(tracks.isEnabled)
        let result = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); result.name = "Existing halo rebound to Player 2 without processing"; result.lifetime = .keepAlways; add(result)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testReviewableAutomaticFieldAlignmentAndFrameChoiceWithoutSaving() throws {
        let app = try openAnalysis()
        app.buttons["analysis-clip-tracks"].tap(); app.buttons["Measurements & ground"].tap()
        XCTAssertTrue(app.buttons["ground-auto-align"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ground-auto-align"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        app.buttons["ground-alignment-options"].tap()
        app.buttons["ground-find-clear-frame"].tap()
        XCTAssertTrue(app.buttons["ground-apply"].wait(for: \.isEnabled, toEqual: true, timeout: 60))
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled, "Automatic proposal still requires review")
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
        app.buttons["ground-cancel"].tap(); app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testVerticalLayerScrollingFrameStepsAndFullWidthFilmstripWithoutSaving() throws {
        let app = try openAnalysis()
        defer { app.buttons["cancel-analysis-workspace"].tap() }
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
        app.buttons["analysis-timeline-zoom-in"].tap()
        let filmstrip = app.otherElements["analysis-source-filmstrip"]
        XCTAssertEqual(filmstrip.frame.minX, timeline.frame.minX, accuracy: 1)
        XCTAssertEqual(filmstrip.frame.maxX, timeline.frame.maxX, accuracy: 1)
        let layers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-"))
        let initialCount = layers.count
        let surface = app.otherElements["analysis-preview-touch-surface"]
        for index in 0..<8 {
            app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-pen"].tap()
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
        ruler.coordinate(withNormalizedOffset: .init(dx: 0.65, dy: 0.5)).tap()
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-arrow"].tap()
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
        app.buttons["analysis-motion-mode"].tap(); app.buttons["Keyframes"].tap()
        app.buttons["analysis-timeline-zoom-in"].tap(); app.buttons["analysis-timeline-zoom-in"].tap()
        let keyframe = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-keyframe-")).firstMatch
        let keyTime = keyframe.value as? String
        let timing = layer.value as? String
        let diamond = keyframe.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        diamond.press(forDuration: 0.1, thenDragTo: diamond.withOffset(.init(dx: 18, dy: 0)))
        XCTAssertNotEqual(keyframe.value as? String, keyTime)
        XCTAssertEqual(layer.value as? String, timing)
        let timeline = app.otherElements["analysis-layer-timeline"]
        let scale = app.staticTexts["analysis-timeline-scale"].label
        timeline.pinch(withScale: 1.4, velocity: 1)
        XCTAssertNotEqual(app.staticTexts["analysis-timeline-scale"].label, scale)
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
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testEditorLayoutAndFieldFrameSelectionWithoutSaving() throws {
        let app = try openAnalysis(captureEditor: true)
        XCTAssertTrue(app.buttons["analysis-clip-tracks"].exists)
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
        app.buttons["analysis-clip-tracks"].tap(); app.buttons["Measurements & ground"].tap()
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
        XCTAssertTrue(app.buttons["ground-nudge-right"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled)
        app.buttons["ground-nudge-right"].tap()
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); frame.name = "Choose field reference frame inside placement"; frame.lifetime = .keepAlways; add(frame)
        app.buttons["ground-apply"].tap()
        app.buttons["analysis-clip-tracks"].tap(); app.buttons["Measurements & ground"].tap()
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(Double(clock.value as? String ?? "")), chosen, accuracy: 0.04)
        app.buttons["ground-cancel"].tap()
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-pen"].tap()
        let bounds = canvas.frame, imageHeight = min(bounds.height, bounds.width * 9 / 16)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: bounds.width * x, dy: (bounds.height - imageHeight) / 2 + imageHeight * y))
        }
        point(0.25, 0.55).press(forDuration: 0.1, thenDragTo: point(0.65, 0.65))
        XCTAssertTrue(app.buttons["analysis-motion-mode"].waitForExistence(timeout: 5))
        app.buttons["analysis-timeline-zoom-in"].tap()
        let zoom = app.staticTexts["analysis-timeline-scale"].label
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); selected.name = "Analysis selected layer matches editor timeline"; selected.lifetime = .keepAlways; add(selected)
        let layer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis-layer-bar-")).firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5)); layer.tap()
        XCTAssertGreaterThanOrEqual(layer.frame.minY, app.otherElements["analysis-source-filmstrip"].frame.maxY)
        XCTAssertFalse(app.segmentedControls["analysis-workspace-switch"].exists)
        XCTAssertEqual(app.staticTexts["analysis-timeline-scale"].label, zoom)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.otherElements["analysis-source-filmstrip"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(divider.frame.height, divider.frame.width)
        XCTAssertTrue(app.buttons["analysis-play-pause"].isHittable)
        let endHandle = app.otherElements["analysis-layer-end"]
        XCTAssertTrue(endHandle.isHittable)
        XCTAssertLessThanOrEqual(endHandle.frame.maxY, app.otherElements["analysis-layer-timeline"].frame.maxY + 1)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Analyze editor-style landscape sidebar"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testFieldAndLayersShareOneFullClipCameraWithoutSaving() throws {
        let app = try openAnalysis()
        app.buttons["analysis-clip-tracks"].tap()
        let track = app.buttons["analysis-track-clip-camera"]
        XCTAssertTrue(track.waitForExistence(timeout: 5)); track.tap()
        let menu = app.buttons["analysis-clip-tracks"]
        XCTAssertTrue(NSPredicate(format: "enabled == true").evaluate(with: menu) ||
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: menu)], timeout: 30) == .completed)
        menu.tap()
        XCTAssertTrue(app.buttons["Re-track entire clip"].waitForExistence(timeout: 5))
        // Dismiss outside the menu; tapping the app centre can activate one
        // of the menu's commands instead.
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.18)).tap()
        let timeline = app.otherElements["analysis-layer-timeline"]
        timeline.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: timeline.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.45)))
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        XCTAssertTrue(app.otherElements["ground-preview"].waitForExistence(timeout: 10))
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String == "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap(); app.buttons["ground-apply"].tap()
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-field-preview"].tap()
        XCTAssertTrue(app.otherElements["analysis-field-preview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["analysis-field-preview-status"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Field uses shared full clip camera on iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testFieldPixelNudgesMoveOnlySelectedPointAndWorkWhenZoomed() throws {
        let app = try openAnalysis()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-field-preview"].tap()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
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
        app.buttons["ground-cancel"].tap(); app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testGroundedRectangleCanBeResizedOnPhoneWithoutSaving() throws {
        let app = try openAnalysis()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-field-preview"].tap()
        XCTAssertTrue(app.otherElements["ground-preview"].waitForExistence(timeout: 10))
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        app.buttons["ground-apply"].tap()
        app.buttons["analysis-tools"].tap()
        let rectangle = app.buttons["analysis-tool-rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 5)); rectangle.tap()
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
        app.buttons["Done"].tap(); app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testFieldPreviewCanBeComparedWhileScrubbingWithoutSaving() throws {
        let app = try openAnalysis()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-field-preview"].tap()
        XCTAssertTrue(app.otherElements["ground-preview"].waitForExistence(timeout: 10))
        app.buttons["ground-settings"].tap()
        let fixed = app.switches["Camera stays fixed"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(fixed.value as? String, "1")
        app.buttons["Done"].tap()
        app.buttons["ground-apply"].tap()
        let preview = app.otherElements["analysis-field-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Draft field overlay preview on iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        let timeline = app.otherElements["analysis-layer-timeline"]
        timeline.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: timeline.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.45)))
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(app.otherElements["analysis-field-preview-status"].exists, "Fixed-camera draft remains available while scrubbing")
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-field-preview"].tap(); XCTAssertFalse(preview.exists)
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-field-preview"].tap(); XCTAssertTrue(preview.exists)
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testGroundedWallOptionMetricHeightAndPreviewOnPhone() throws {
        let app = try openAnalysis()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        XCTAssertTrue(app.otherElements["ground-preview"].waitForExistence(timeout: 10))
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
        app.buttons["analysis-tools"].tap()
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
        app.buttons["cancel-analysis-workspace"].tap()
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
        let header = app.buttons["analysis-clip-tracks"]
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
        app.buttons["analysis-tools"].tap()
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
        app.buttons["analysis-tools"].tap()
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
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-arrow"].tap()
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
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-measure"].tap()
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
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testLiveFieldOverlayCanBeAlignedComparedAndCancelled() throws {
        let app = try openAnalysis()
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue((preview.value as? String ?? "").contains("Overlay visible; 4 points"))
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled)
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
        app.buttons["cancel-analysis-workspace"].tap()
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
        app.buttons["analysis-tools"].tap(); app.buttons["analysis-tool-pen"].tap()
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
