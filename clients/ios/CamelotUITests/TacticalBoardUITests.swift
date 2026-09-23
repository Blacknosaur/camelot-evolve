import XCTest

/// Creates a board from the Boards tab, connects two players with a line, rotates and resizes a player,
/// switches style and view angle, exports and checks the board is listed. Boards it creates are named
/// "UITest …" and removed with `-removeUITestBoards`, so it is safe on a phone with real data: it never
/// resets onboarding and never touches other boards or projects.
final class TacticalBoardUITests: XCTestCase {
    private let boardPrefix = "UITest Board"

    @MainActor
    override func tearDown() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let card = testCard(in: app)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed, "UITest boards are removed after the test")
        app.terminate()
        try await super.tearDown()
    }

    @MainActor
    private func continueOfflineIfNeeded(_ app: XCUIApplication) {
        if app.buttons["Continue offline"].waitForExistence(timeout: 4) { app.buttons["Continue offline"].tap() }
    }

    @MainActor
    private func testCard(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", boardPrefix)).firstMatch
    }

    /// Accessibility values update after SwiftUI re-renders; wait instead of reading immediately.
    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected \(expected), got \(String(describing: element.value))", file: file, line: line)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, notEqual unexpected: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value != %@", unexpected)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected a value other than \(unexpected)", file: file, line: line)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, beginsWith prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", prefix)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected \(prefix)…, got \(String(describing: element.value))", file: file, line: line)
    }

    /// Arms an item from the bottom bar's recents, or from the library (search) when it is not recent on this device.
    @MainActor
    private func arm(_ tool: String, title: String, in app: XCUIApplication) {
        let slot = app.descendants(matching: .any)["board-recent-\(tool)"]
        if slot.waitForExistence(timeout: 2) {
            slot.tap()
            return
        }
        app.buttons["board-library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(title)
        let tile = app.buttons["board-library-\(tool)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 3), "\(title) is in the library")
        tile.tap()
    }

    /// Chooses a drawing tool from the Draw slot's menu (long press) and checks it is armed before drawing.
    @MainActor
    private func armDraw(_ tool: String, title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let draw = app.buttons["board-draw"]
        draw.press(forDuration: 1.0)
        let item = app.buttons["board-draw-\(tool)"]
        if item.waitForExistence(timeout: 3) {
            item.tap()
        } else {
            // A long press can already pick or dismiss the menu on some devices; the library always works.
            if app.buttons["board-disarm"].exists { app.buttons["board-disarm"].tap() }
            arm(tool, title: title, in: app)
        }
        waitForValue(draw, title, file: file, line: line)
        XCTAssertTrue(app.buttons["board-disarm"].exists, "\(title) is armed", file: file, line: line)
    }

    @MainActor
    private func assertToolbarFits(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.otherElements["board-toolbar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3), file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(bar.frame.minX, window.minX - 0.5, "Bar starts on screen (\(name))", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.maxX, window.maxX + 0.5, "Bar fits the width (\(name))", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.maxY, window.maxY + 0.5, "Bar fits the height (\(name))", file: file, line: line)
        XCTAssertEqual(bar.scrollViews.count, 0, "The bar never scrolls (\(name))", file: file, line: line)
        for id in ["board-library", "board-draw", "board-animate"] {
            let slot = app.buttons[id]
            XCTAssertTrue(slot.isHittable, "\(id) is reachable without scrolling (\(name))", file: file, line: line)
            XCTAssertGreaterThanOrEqual(min(slot.frame.width, slot.frame.height), 44, "\(id) has a 44 pt target (\(name))", file: file, line: line)
        }
    }

    @MainActor
    private func chooseFromViewMenu(_ item: String, in app: XCUIApplication) {
        // A tap that lands while the previous menu is still dismissing is ignored on device; retry opening.
        let button = app.buttons[item].firstMatch
        for _ in 0..<3 where !button.exists {
            app.buttons["board-view"].tap()
            if button.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(button.exists, "\(item) is in the field and view menu")
        button.tap()
    }


    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCreatesConnectsTransformsAndExportsABoardFromTheBoardsTab() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)

        app.tabBars.buttons["Boards"].tap()
        XCTAssertTrue(app.navigationBars["Boards"].waitForExistence(timeout: 5))
        attachScreenshot("Boards tab")
        let canvas = app.openNewBoard("Full pitch")
        waitForValue(canvas, beginsWith: "0 elements")
        attachScreenshot("Empty board hint")

        // `-uiTestBoards` names the board "UITest Board N" at creation, so teardown always finds it.
        XCTAssertTrue(app.buttons["board-name"].label.hasPrefix(boardPrefix) || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", boardPrefix)).firstMatch.exists,
                      "Test boards are named for cleanup from creation")

        // Two players connected by a line.
        arm("home", title: "Home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        armDraw("line", title: "Line", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")
        XCTAssertTrue(app.buttons["board-line-preset-run"].waitForExistence(timeout: 3), "The new line is selected with line styles in the inspector")
        app.buttons["board-line-preset-run"].tap()

        app.buttons["board-undo"].tap()
        app.buttons["board-undo"].tap()
        waitForValue(canvas, beginsWith: "2 elements")
        app.buttons["board-redo"].tap()
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")

        // Moving a connected player keeps the line attached (no mode switch needed).
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")
        attachScreenshot("Connected players")

        // Rotate and resize the selected player from the inspector.
        let rotation = app.sliders["board-rotation-slider"]
        XCTAssertTrue(rotation.waitForExistence(timeout: 3), "Dragging selects the player and shows its inspector")
        // Synthesised slider drags land imprecisely, so check the value changed rather than an exact angle.
        // A real finger drag on the track, like on a phone: the panel must not steal it.
        rotation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: rotation.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        waitForValue(rotation, notEqual: "0°")
        let size = app.sliders["board-size-slider"]
        size.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.05, thenDragTo: size.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        waitForValue(size, notEqual: "1.0×")
        attachScreenshot("Rotated and resized player")
        app.buttons["board-undo"].tap()
        waitForValue(size, "1.0×")
        app.buttons["board-rotation-reset"].tap()
        waitForValue(rotation, "0°")

        // Style and real 3D.
        chooseFromViewMenu("Chalkboard", in: app)
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        attachScreenshot("Chalkboard style")
        chooseFromViewMenu("Tilted", in: app)
        XCTAssertTrue(app.otherElements["board-3d-view"].waitForExistence(timeout: 10), "Tilted shows the 3D view")
        attachScreenshot("Tilted 3D")
        chooseFromViewMenu("Top", in: app)
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        app.buttons["board-export"].tap()
        XCTAssertTrue(app.buttons["board-export-run"].waitForExistence(timeout: 5))
        app.buttons["board-export-run"].tap()
        XCTAssertTrue(app.buttons["board-export-share"].waitForExistence(timeout: 20), "PNG export finishes and offers sharing")
        app.buttons["Done"].tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 5))
        attachScreenshot("Board in landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["board-close"].tap()
        XCTAssertTrue(testCard(in: app).waitForExistence(timeout: 5), "The board is saved and listed in the Boards tab")
        attachScreenshot("Board listed")
    }

    /// The board canvas never moves or resizes when floating panels appear: selection inspector,
    /// keyframe bar and deselection, in portrait and landscape.
    @MainActor
    func testBoardFrameStaysStableWhenPanelsAppear() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Half pitch")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: canvas)
            _ = XCTWaiter.wait(for: [settled], timeout: 3)
            let baseline = canvas.frame
            let name = orientation == .portrait ? "portrait" : "landscape"

            arm("home", title: "Home", in: app)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            // Tapping the placed player finishes placing and selects it.
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3) || app.buttons["board-inspector-expand"].exists, "Selection shows the inspector (\(name))")
            XCTAssertEqual(canvas.frame, baseline, "Inspector does not move the board (\(name))")
            attachScreenshot("Inspector floating \(name)")

            app.buttons["board-animate"].tap()
            XCTAssertTrue(app.buttons["board-stage-1"].waitForExistence(timeout: 3))
            XCTAssertEqual(canvas.frame, baseline, "Animation mode does not move the board (\(name))")
            app.buttons["board-stage-add"].tap()
            XCTAssertTrue(app.buttons["board-stage-2"].waitForExistence(timeout: 3))
            XCTAssertEqual(canvas.frame, baseline, "Adding stages does not move the board (\(name))")
            attachScreenshot("Animation dock \(name)")
            app.buttons["board-animation-done"].tap()
            XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 3))
            XCTAssertEqual(canvas.frame, baseline, "Leaving animation mode does not move the board (\(name))")

            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sliders["board-rotation-slider"])
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "Tapping empty ground deselects (\(name))")
            XCTAssertEqual(canvas.frame, baseline, "Deselecting does not move the board (\(name))")
        }
        XCUIDevice.shared.orientation = .portrait
        app.buttons["board-close"].tap()
    }

    /// A ball follows a polyline between two keyframes; scrubbing mid-transition keeps it on the path.
    /// Also toggles onion skin.
    @MainActor
    func testBallFollowsPolylineAndOnionSkinToggles() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")

        // Ball first (away from the polyline start so the polyline does not connect to it).
        arm("ball", title: "Ball", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        armDraw("polyline", title: "Polyline", in: app)
        for point in [CGVector(dx: 0.25, dy: 0.35), CGVector(dx: 0.5, dy: 0.12), CGVector(dx: 0.75, dy: 0.35)] {
            canvas.coordinate(withNormalizedOffset: point).tap()
        }
        app.buttons["board-path-done"].tap()
        waitForValue(canvas, beginsWith: "2 elements")

        // Three stages, then follow the polyline from stage 1: progress spreads 0%, 50%, 100%.
        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-stage-add"].waitForExistence(timeout: 3))
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-add"].tap()
        XCTAssertTrue(app.buttons["board-stage-3"].waitForExistence(timeout: 3))
        app.buttons["board-stage-1"].tap()
        // Close the polyline's card first: it floats over the lower board.
        app.buttons["board-card-close"].firstMatch.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        if app.buttons["board-inspector-expand"].exists { app.buttons["board-inspector-expand"].tap() }
        let motion = app.buttons["board-card-tab-motion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 3), "The ball's card has a Motion tab in animation mode")
        motion.tap()
        let follow = app.buttons["board-follow-path"]
        XCTAssertTrue(follow.waitForExistence(timeout: 3), "The selected ball offers Follow path")
        follow.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        let state = app.otherElements["board-follow-state"].exists ? app.otherElements["board-follow-state"] : app.descendants(matching: .any)["board-follow-state"]
        waitForValue(state, "0%, 50%, 100%")
        XCTAssertTrue(app.sliders["board-path-progress"].waitForExistence(timeout: 3), "Progress is editable once on the path")
        attachScreenshot("Follow path over stages")

        // Stage 2: drag the ball further along the path; progress follows the finger.
        app.buttons["board-stage-2"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(forDuration: 0.15, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.235)))
        let slid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '0%, ' AND NOT (value == '0%, 50%, 100%') AND value ENDSWITH ', 100%'"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [slid], timeout: 4), .completed, "Dragging along the path changes stage 2's progress, got \(String(describing: state.value))")
        attachScreenshot("Ball dragged along path")

        let onion = app.buttons["board-onion-toggle"]
        onion.tap()
        waitForValue(onion, "On")
        attachScreenshot("Onion skin")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        attachScreenshot("Onion skin landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["board-close"].tap()
    }

    /// Animation mode: tools give way to the stage dock; stages can be added, timed, reordered, deleted,
    /// played and scrubbed; Done brings the tools back.
    @MainActor
    func testAnimationModeStagesAndTransport() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        arm("home", title: "Home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        app.buttons["board-disarm"].tap()

        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-animation-done"].waitForExistence(timeout: 3), "Done leaves animation mode")
        // Paired with a positive so renaming an identifier cannot quietly make these vacuous.
        XCTAssertTrue(app.buttons["board-play"].waitForExistence(timeout: 3), "The animation dock is up")
        XCTAssertFalse(app.buttons["board-library"].exists, "The tools bar gives way to the animation dock")
        XCTAssertFalse(app.buttons["board-draw"].exists)
        app.buttons["board-stage-add"].tap()
        // Move the player in stage 2 so there is motion.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
        app.buttons["board-stage-add"].tap()
        XCTAssertTrue(app.buttons["board-stage-3"].waitForExistence(timeout: 3))
        attachScreenshot("Animation dock with stages")

        let transition = app.buttons["board-transition-1"]
        XCTAssertTrue(transition.waitForExistence(timeout: 3))
        transition.tap()
        let twoSeconds = app.buttons["2.0s"].firstMatch
        XCTAssertTrue(twoSeconds.waitForExistence(timeout: 3), "Durations are offered in a compact picker")
        twoSeconds.tap()
        waitForValue(transition, "2.0s")

        app.buttons["board-stage-3"].press(forDuration: 1.0)
        let moveLeft = app.buttons["board-stage-move-left"]
        XCTAssertTrue(moveLeft.waitForExistence(timeout: 3))
        moveLeft.tap()
        XCTAssertTrue(app.buttons["board-stage-2"].isSelected, "The moved stage is now stage 2 and selected")
        app.buttons["board-stage-3"].press(forDuration: 1.0)
        let delete = app.buttons["board-stage-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.buttons["board-stage-2"].waitForExistence(timeout: 3), "Two stages are left")
        XCTAssertFalse(app.buttons["board-stage-3"].waitForExistence(timeout: 2), "A stage was deleted")

        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot("Playing")
        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))

        let scrubber = app.sliders["board-scrubber"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).press(forDuration: 0.05, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertNotEqual(scrubber.value as? String, "0%", "Scrubbing moves the playhead")

        app.buttons["board-animation-done"].tap()
        XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 3), "Tools come back after Done")
        XCTAssertTrue(app.buttons["board-animate"].exists, "…including the Animate slot")
        XCTAssertFalse(app.buttons["board-stage-1"].exists, "The stage strip is gone")
        app.buttons["board-close"].tap()
    }

    /// No Select tool: an armed item places on empty field and stays armed, touching an element selects or
    /// moves it, and drawn shapes finish drawing with the shape selected. The bar fits without scrolling.
    @MainActor
    func testArmedPlacementAndInferredSelection() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 3), "The bottom bar is up")
        XCTAssertFalse(app.buttons["board-tool-select"].exists, "There is no Select tool")
        assertToolbarFits(app, "portrait")
        attachScreenshot("Bottom bar")

        // Three cones with three taps; the tool stays armed with a ✕ to finish.
        arm("cone", title: "Cone", in: app)
        XCTAssertTrue(app.buttons["board-disarm"].waitForExistence(timeout: 3), "Armed items show a way to finish")
        for x in [0.3, 0.5, 0.7] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.3)).tap()
        }
        waitForValue(canvas, beginsWith: "3 elements")
        XCTAssertTrue(app.buttons["board-disarm"].exists, "Still armed after placing")
        XCTAssertFalse(app.sliders["board-rotation-slider"].exists, "Placed cones are not left selected")
        attachScreenshot("Cones armed")
        // Tapping an existing cone selects it and finishes placing.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3), "The tapped cone is selected")
        waitForValue(canvas, beginsWith: "3 elements")
        XCTAssertTrue(app.sliders["board-rotation-slider"].exists, "The cone's card is up")
        XCTAssertFalse(app.buttons["board-disarm"].exists, "Selecting finished placing")

        // A player placed, then finished with ✕, then dragged straight away.
        arm("home", title: "Home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        waitForValue(canvas, beginsWith: "4 elements")
        app.buttons["board-disarm"].tap()
        XCTAssertTrue(app.buttons["board-library"].exists, "The bar is still there to place from")
        XCTAssertFalse(app.buttons["board-disarm"].waitForExistence(timeout: 1), "✕ finished placing")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.62)))
        waitForValue(canvas, beginsWith: "4 elements")
        XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3), "Dragging moves and selects the player")

        // A recent item dragged straight from the bar is placed where it is dropped, without arming.
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "board-recent-")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 3))
        recent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.4, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        waitForValue(canvas, beginsWith: "5 elements")
        XCTAssertTrue(app.buttons["board-library"].exists, "The bar is still shown")
        XCTAssertFalse(app.buttons["board-disarm"].exists, "Dragging from the bar does not arm the item")

        // Line from Draw: dragging creates it, then drawing finishes with the line selected.
        armDraw("line", title: "Line", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        waitForValue(canvas, beginsWith: "6 elements")
        let title = app.staticTexts["board-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), "The new line is selected and its card is shown")
        XCTAssertEqual(title.label, "Line")
        // VoiceOver hears what is selected from the board element itself, not only from the card.
        XCTAssertTrue((canvas.value as? String ?? "").hasSuffix("Line selected"), "The board announces the selection, got \(String(describing: canvas.value))")
        XCTAssertTrue(app.buttons["board-line-preset-run"].waitForExistence(timeout: 3), "Line styles are one tap away")
        XCTAssertTrue(app.buttons["board-draw"].exists, "The Draw slot is back to its resting state")
        XCTAssertFalse(app.buttons["board-disarm"].exists, "Drawing finished after one line")
        attachScreenshot("Line drawn and selected")

        app.buttons["board-library"].tap()
        XCTAssertTrue(app.otherElements["board-library-sheet"].waitForExistence(timeout: 3) || app.searchFields.firstMatch.waitForExistence(timeout: 3))
        attachScreenshot("Library medium")
        app.swipeUp()
        attachScreenshot("Library large")
        app.buttons["Done"].firstMatch.tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        assertToolbarFits(app, "landscape")
        attachScreenshot("Bottom rail landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["board-close"].tap()
    }

    /// Animate the 3D camera: keys on stages 1 and 2 show a badge, and playback runs.
    @MainActor
    func testCameraKeysAnimateThe3DView() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        app.buttons["boards-new"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Full pitch"].waitForExistence(timeout: 3))
        app.buttons["Full pitch"].tap()
        let canvas = app.otherElements["board-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        arm("home", title: "Home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        app.buttons["board-disarm"].tap()

        app.buttons["board-animate"].tap()
        let camera = app.descendants(matching: .any)["board-camera-key"]
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        waitForValue(camera, "Top view")
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-add"].tap()
        XCTAssertTrue(app.buttons["board-stage-3"].waitForExistence(timeout: 3))
        chooseFromViewMenu("Tilted", in: app)
        let view3D = app.otherElements["board-3d-view"]
        XCTAssertTrue(view3D.waitForExistence(timeout: 10))

        app.buttons["board-stage-1"].tap()
        waitForValue(camera, "No key")
        camera.tap()
        waitForValue(camera, "Stage 1 key")
        waitForValue(app.buttons["board-stage-1"], "Camera key")
        attachScreenshot("Camera key on stage 1")

        app.buttons["board-stage-2"].tap()
        waitForValue(camera, "No key")
        view3D.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)).press(forDuration: 0.1, thenDragTo: view3D.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        camera.tap()
        waitForValue(camera, "Stage 2 key")
        waitForValue(app.buttons["board-stage-1"], "Camera key")
        waitForValue(app.buttons["board-stage-2"], "Camera key")
        waitForValue(app.buttons["board-stage-3"], "No camera key")
        attachScreenshot("Camera keys on stages 1 and 2")

        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot("Camera animation playing")
        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        XCTAssertTrue(view3D.exists, "The 3D view survives playback")
        app.buttons["board-animation-done"].tap()
        app.buttons["board-close"].tap()
    }

    /// Point of view: look through a referee's eyes in 3D, key it on stage 1, key an orbit on stage 2, play.
    @MainActor
    func testViewFromRefereeAndCameraModeKeys() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        arm("referee", title: "Referee", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        app.buttons["board-disarm"].tap()
        arm("ball", title: "Ball", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        app.buttons["board-disarm"].tap()

        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-stage-add"].waitForExistence(timeout: 3))
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-1"].tap()
        chooseFromViewMenu("Tilted", in: app)
        let view3D = app.otherElements["board-3d-view"]
        XCTAssertTrue(view3D.waitForExistence(timeout: 10))
        waitForValue(app.buttons["board-view"], "Tilted, Orbit")

        // Select the referee from the top view layout, then look through its eyes.
        chooseFromViewMenu("Top", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        let viewFrom = app.buttons["board-view-from"]
        XCTAssertTrue(viewFrom.waitForExistence(timeout: 3), "People have View from here")
        viewFrom.tap()
        XCTAssertTrue(view3D.waitForExistence(timeout: 10), "View from here switches Top to 3D")
        waitForValue(app.buttons["board-view"], "Tilted, POV")
        attachScreenshot("Referee point of view")

        let camera = app.descendants(matching: .any)["board-camera-key"]
        camera.tap()
        waitForValue(camera, "Stage 1 key")
        waitForValue(app.buttons["board-stage-1"], "Camera key")

        app.buttons["board-stage-2"].tap()
        chooseFromViewMenu("board-camera-orbit", in: app)
        waitForValue(app.buttons["board-view"], "Tilted, Orbit")
        camera.tap()
        waitForValue(camera, "Stage 2 key")
        waitForValue(app.buttons["board-stage-2"], "Camera key")
        attachScreenshot("POV and orbit keys")

        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot("Playing POV to orbit")
        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        XCTAssertTrue(view3D.exists, "The 3D view survives playback")
        app.buttons["board-animation-done"].tap()
        app.buttons["board-close"].tap()
    }

    /// A lofted line: Height presets set the arc, and the slider reports it.
    @MainActor
    func testLineHeightPresets() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        armDraw("line", title: "Line", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        waitForValue(canvas, beginsWith: "1 element")
        XCTAssertTrue(app.staticTexts["board-card-title"].waitForExistence(timeout: 3), "The new line is selected")

        let high = app.buttons["board-height-high"]
        let styleRow = app.otherElements["board-inspector"].scrollViews.firstMatch
        for _ in 0..<8 where !high.isHittable {
            if styleRow.exists {
                styleRow.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: styleRow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.1)
            } else {
                app.otherElements["board-inspector"].swipeLeft(velocity: .slow)
            }
        }
        XCTAssertTrue(high.isHittable, "The Height presets are reachable in the Style tab")
        high.tap()
        let slider = app.sliders["board-height-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        waitForValue(slider, "8.0 m")
        attachScreenshot("Aerial line high")
        app.buttons["board-height-ground"].tap()
        XCTAssertTrue(app.buttons["board-height-high"].waitForExistence(timeout: 3), "The presets are still shown")
        XCTAssertFalse(app.sliders["board-height-slider"].waitForExistence(timeout: 2), "Ground lines have no height slider")
        app.buttons["board-close"].tap()
    }
}
