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

    @MainActor
    private func waitForValue(_ element: XCUIElement, endsWith suffix: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value ENDSWITH %@", suffix)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected …\(suffix), got \(String(describing: element.value))", file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Bar items are not Buttons in the accessibility tree.
    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func waitSelected(_ element: XCUIElement, _ what: String, selected: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "selected == %@", NSNumber(value: selected))
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3)
        XCTAssertEqual(result, .completed, what, file: file, line: line)
    }

    /// Arms one of the bar's everyday items (`home`, `away`, `ball`, `cone`); the mode banner shows until Done.
    @MainActor
    private func arm(_ item: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let slot = element("board-item-\(item)", in: app)
        XCTAssertTrue(slot.waitForExistence(timeout: 3), "\(item) is in the bar", file: file, line: line)
        if !slot.isSelected { slot.tap() }
        // A tap can be dropped right after a rotation or mode change; retry once, never toggling an armed item off.
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: slot)
        if XCTWaiter.wait(for: [armed], timeout: 2) != .completed { slot.tap() }
        waitSelected(slot, "\(item) is armed", file: file, line: line)
        XCTAssertTrue(element("board-mode-banner", in: app).waitForExistence(timeout: 3), "Arming shows the mode banner", file: file, line: line)
    }

    /// Arms an item that is not in the bar by searching the library for it.
    @MainActor
    private func armFromLibrary(_ tool: String, title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        finish(in: app)
        app.buttons["board-library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), file: file, line: line)
        search.tap()
        search.typeText(title)
        let tile = app.buttons["board-library-\(tool)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 3), "\(title) is in the library", file: file, line: line)
        tile.tap()
        XCTAssertTrue(element("board-mode-banner", in: app).waitForExistence(timeout: 3), "Picking from the library arms it", file: file, line: line)
    }

    /// Arms a drawing type from the Draw banner (`pass`, `run`, `dribble`, `polyline`, `zoneRect`, …).
    @MainActor
    private func armDraw(_ item: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chip = app.buttons["board-draw-\(item)"]
        if !chip.exists {
            app.buttons["board-draw"].tap()
            XCTAssertTrue(element("board-mode-banner", in: app).waitForExistence(timeout: 3), "Draw shows the mode banner", file: file, line: line)
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "\(item) is in the Draw banner", file: file, line: line)
        if !chip.isSelected { chip.tap() }
        waitSelected(chip, "\(item) is armed", file: file, line: line)
    }

    /// The banner's Done: back to selecting and moving.
    @MainActor
    private func finish(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["board-disarm"]
        guard done.exists else { return }
        done.tap()
        XCTAssertTrue(waitUntilGone(element("board-mode-banner", in: app)), "Done ends placing", file: file, line: line)
    }

    /// Selecting shows the card straight away; it starts collapsed when it would cover the selection.
    @MainActor
    private func waitForCard(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.otherElements["board-inspector"]
        let expand = app.buttons["board-inspector-expand"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: card)
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: expand)
        _ = XCTWaiter.wait(for: [shown, collapsed], timeout: 3, enforceOrder: false)
        if !card.exists, expand.exists { expand.tap() }
        XCTAssertTrue(card.waitForExistence(timeout: 3), "Selecting shows the card", file: file, line: line)
    }

    @MainActor
    private func assertToolbarFits(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = element("board-toolbar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 3), file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(bar.frame.minX, window.minX - 0.5, "Bar starts on screen (\(name))", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.maxX, window.maxX + 0.5, "Bar fits the width (\(name))", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.maxY, window.maxY + 0.5, "Bar fits the height (\(name))", file: file, line: line)
        XCTAssertEqual(bar.scrollViews.count, 0, "The bar never scrolls (\(name))", file: file, line: line)
        for id in ["board-library", "board-item-home", "board-item-away", "board-item-ball", "board-item-cone", "board-draw", "board-animate"] {
            let slot = element(id, in: app)
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
        XCTAssertTrue(element("board-starter", in: app).waitForExistence(timeout: 3), "An empty board offers a way to start")
        attachScreenshot("Empty board starter")

        // `-uiTestBoards` names the board "UITest Board N" at creation, so teardown always finds it.
        XCTAssertTrue(app.buttons["board-name"].label.hasPrefix(boardPrefix) || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", boardPrefix)).firstMatch.exists,
                      "Test boards are named for cleanup from creation")

        // Two players from the starter card (Add players arms Home), connected by a pass line drawn from one to the other.
        element("board-start-players", in: app).tap()
        waitSelected(element("board-item-home", in: app), "Add players arms Home")
        XCTAssertTrue(element("board-mode-banner", in: app).exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        armDraw("pass", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")
        finish(in: app)

        // Select the line and make it a run from its card.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForCard(in: app)
        XCTAssertTrue(app.buttons["board-line-preset-run"].waitForExistence(timeout: 3), "The line's card has line styles")
        app.buttons["board-line-preset-run"].tap()
        waitForValue(canvas, endsWith: "Run selected")

        app.buttons["board-undo"].tap()
        app.buttons["board-undo"].tap()
        waitForValue(canvas, beginsWith: "2 elements")
        app.buttons["board-redo"].tap()
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")

        // Moving a connected player keeps the line attached (no mode switch needed).
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")
        waitForValue(canvas, endsWith: "Player 2 selected")
        attachScreenshot("Connected players")

        // Rotate and resize the selected player from its card.
        waitForCard(in: app)
        let rotation = app.sliders["board-rotation-slider"]
        XCTAssertTrue(rotation.waitForExistence(timeout: 3), "Dragging selects the player and shows its card")
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

        // The card's close deselects.
        app.buttons["board-card-close"].firstMatch.tap()
        XCTAssertTrue(waitUntilGone(app.otherElements["board-inspector"]), "Closing the card hides it")
        waitForValue(canvas, "3 elements, 2 connected")

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

    /// The board canvas never moves or resizes when floating panels appear: mode banner, selection card,
    /// stage strip and deselection, in portrait and landscape.
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

            arm("home", in: app)
            XCTAssertEqual(canvas.frame, baseline, "The mode banner does not move the board (\(name))")
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            // Tapping the placed player finishes placing and selects it.
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3) || app.buttons["board-inspector-expand"].exists, "Selection shows the card (\(name))")
            XCTAssertFalse(element("board-mode-banner", in: app).exists, "Selecting finished placing (\(name))")
            XCTAssertEqual(canvas.frame, baseline, "The card does not move the board (\(name))")
            attachScreenshot("Card floating \(name)")

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

    /// A ball follows a polyline between two keyframes; dragging mid-transition keeps it on the path.
    /// Also toggles ghosts (onion skin).
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
        arm("ball", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        armDraw("polyline", in: app)
        for point in [CGVector(dx: 0.25, dy: 0.35), CGVector(dx: 0.5, dy: 0.12), CGVector(dx: 0.75, dy: 0.35)] {
            canvas.coordinate(withNormalizedOffset: point).tap()
        }
        app.buttons["board-path-done"].tap()
        waitForValue(canvas, "2 elements")
        XCTAssertTrue(app.buttons["board-draw-polyline"].isSelected, "Path stays armed after drawing one")
        finish(in: app)

        // Three stages, then follow the polyline from stage 1: progress spreads 0%, 50%, 100%.
        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-stage-add"].waitForExistence(timeout: 3))
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-add"].tap()
        XCTAssertTrue(app.buttons["board-stage-3"].waitForExistence(timeout: 3))
        app.buttons["board-stage-1"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        waitForCard(in: app)
        let motion = app.buttons["board-card-tab-motion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 3), "The ball's card has a Motion tab in animation mode")
        motion.tap()
        let follow = app.buttons["board-follow-path"]
        XCTAssertTrue(follow.waitForExistence(timeout: 3), "The selected ball offers Follow path")
        follow.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        let state = element("board-follow-state", in: app)
        waitForValue(state, "0%, 50%, 100%")
        waitForCard(in: app)
        XCTAssertTrue(app.sliders["board-path-progress"].waitForExistence(timeout: 3), "Progress is editable once on the path")
        attachScreenshot("Follow path over stages")

        // Stage 2: drag the ball further along the path; progress follows the finger.
        app.buttons["board-stage-2"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(forDuration: 0.15, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.235)))
        let slid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '0%, ' AND NOT (value == '0%, 50%, 100%') AND value ENDSWITH ', 100%'"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [slid], timeout: 4), .completed, "Dragging along the path changes stage 2's progress, got \(String(describing: state.value))")
        attachScreenshot("Ball dragged along path")

        let onion = app.buttons["board-onion-toggle"]
        XCTAssertEqual(onion.label, "Ghosts")
        onion.tap()
        waitForValue(onion, "On")
        attachScreenshot("Onion skin")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        attachScreenshot("Onion skin landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["board-close"].tap()
    }

    /// Animation mode: the tools give way to the transport; stages can be added, timed, reordered, deleted,
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
        arm("home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        finish(in: app)

        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-animation-done"].waitForExistence(timeout: 3), "Done leaves animation mode")
        XCTAssertTrue(element("board-transport", in: app).buttons["board-animation-done"].exists, "Done is the transport's last slot")
        XCTAssertTrue(app.buttons["board-export"].exists, "Export stays in the top bar while animating")
        // Loop lives in the Speed menu.
        app.buttons["board-speed"].firstMatch.tap()
        let loop = app.descendants(matching: .any)["board-loop"].firstMatch
        XCTAssertTrue(loop.waitForExistence(timeout: 3), "Loop is a toggle in the Speed menu")
        // Tapping outside dismisses the menu without reaching the board.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilGone(loop), "The Speed menu closes")
        // Paired with a positive so renaming an identifier cannot quietly make these vacuous.
        XCTAssertTrue(app.buttons["board-play"].waitForExistence(timeout: 3), "The transport is up")
        XCTAssertFalse(app.buttons["board-library"].exists, "The tools bar gives way to the transport")
        XCTAssertFalse(app.buttons["board-draw"].exists)
        XCTAssertEqual(app.buttons["board-stage-1"].label, "Step 1", "Stages are called steps")
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
        XCTAssertTrue(app.buttons["board-animate"].exists, "…including Animate")
        XCTAssertFalse(app.buttons["board-stage-1"].exists, "The stage strip is gone")
        app.buttons["board-close"].tap()
    }

    /// No Select tool: an armed item places on empty field and stays armed until Done or a second tap,
    /// touching an element selects it, items drag straight from the bar, drawings stay armed and flash
    /// instead of being selected, and the library arms what is picked. The bar fits without scrolling.
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

        // Three cones with three taps; the item stays armed with the banner's Done to finish.
        arm("cone", in: app)
        let cone = element("board-item-cone", in: app)
        XCTAssertTrue(app.buttons["board-disarm"].exists, "Armed items show a way to finish")
        for x in [0.3, 0.5, 0.7] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.3)).tap()
        }
        waitForValue(canvas, "3 elements")
        XCTAssertTrue(cone.isSelected, "Still armed after placing")
        XCTAssertFalse(app.sliders["board-rotation-slider"].exists, "Placed cones are not left selected")
        attachScreenshot("Cones armed")
        // Tapping the armed item again stops placing.
        cone.tap()
        waitSelected(cone, "A second tap disarms", selected: false)
        XCTAssertTrue(waitUntilGone(element("board-mode-banner", in: app)), "The banner goes with it")
        arm("cone", in: app)

        // Tapping an existing cone selects it and finishes placing.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        // A tap right after re-arming is occasionally dropped by the simulator; a second tap on a cone is harmless.
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'selected'"), object: canvas)
        if XCTWaiter.wait(for: [picked], timeout: 2) != .completed, (canvas.value as? String) == "3 elements" {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        waitForValue(canvas, "3 elements, Cone selected")
        waitForCard(in: app)
        XCTAssertTrue(app.sliders["board-rotation-slider"].exists, "The cone's card is up")
        XCTAssertFalse(app.buttons["board-disarm"].exists, "Selecting finished placing")
        XCTAssertFalse(cone.isSelected)
        app.buttons["board-card-close"].firstMatch.tap()
        waitForValue(canvas, "3 elements")

        // A player placed, then finished with Done, then dragged straight away.
        arm("home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        waitForValue(canvas, "4 elements")
        finish(in: app)
        XCTAssertTrue(app.buttons["board-library"].exists, "The bar is still there to place from")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.62)))
        waitForValue(canvas, "4 elements, Player 1 selected")
        XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3) || app.buttons["board-inspector-expand"].exists, "Dragging moves and selects the player")

        // An item dragged straight from the bar is placed where it is dropped, without arming.
        let ball = element("board-item-ball", in: app)
        ball.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.4, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        waitForValue(canvas, beginsWith: "5 elements")
        XCTAssertTrue(app.buttons["board-library"].exists, "The bar is still shown")
        XCTAssertFalse(ball.isSelected, "Dragging from the bar does not arm the item")
        XCTAssertFalse(app.buttons["board-disarm"].exists)

        // Draw arms a pass line; drawing keeps it armed and does not select the line.
        armDraw("pass", in: app)
        XCTAssertTrue(app.buttons["board-draw"].isSelected, "The Draw slot shows drawing is on")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        waitForValue(canvas, "6 elements")
        XCTAssertTrue(app.buttons["board-draw-pass"].isSelected, "Drawing stays armed until Done")
        XCTAssertFalse(app.otherElements["board-inspector"].exists, "The drawn line is not selected")
        attachScreenshot("Line drawn, still armed")
        // The banner's type chips switch what is drawn.
        armDraw("run", in: app)
        XCTAssertFalse(app.buttons["board-draw-pass"].isSelected)
        // Tapping Draw again stops drawing.
        app.buttons["board-draw"].tap()
        XCTAssertTrue(waitUntilGone(element("board-mode-banner", in: app)), "A second tap on Draw stops drawing")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        waitForCard(in: app)
        let title = app.staticTexts["board-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Tapping the line selects it and shows its card")
        XCTAssertEqual(title.label, "Pass")
        // VoiceOver hears what is selected from the board element itself, not only from the card.
        waitForValue(canvas, endsWith: "Pass selected")
        XCTAssertTrue(app.buttons["board-line-preset-run"].waitForExistence(timeout: 3), "Line styles are one tap away")
        attachScreenshot("Line selected")
        app.buttons["board-card-close"].firstMatch.tap()

        // The library opens as a sheet; picking an item arms it.
        app.buttons["board-library"].tap()
        XCTAssertTrue(app.otherElements["board-library-sheet"].waitForExistence(timeout: 3) || app.searchFields.firstMatch.waitForExistence(timeout: 3))
        attachScreenshot("Library medium")
        app.swipeUp()
        attachScreenshot("Library large")
        app.buttons["Done"].firstMatch.tap()
        armFromLibrary("hurdle", title: "Hurdle", in: app)
        let hint = element("board-hint", in: app)
        XCTAssertTrue(hint.label.localizedCaseInsensitiveContains("hurdle"), "The banner says what is armed, got \(hint.label)")
        finish(in: app)

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
        let canvas = app.openNewBoard("Full pitch")
        arm("home", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        finish(in: app)

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
        armFromLibrary("referee", title: "Referee", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        arm("ball", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        finish(in: app)

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
        waitForCard(in: app)
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
        armDraw("pass", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        waitForValue(canvas, beginsWith: "1 element")
        finish(in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        waitForCard(in: app)
        XCTAssertTrue(app.staticTexts["board-card-title"].waitForExistence(timeout: 3), "The line is selected")

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
        XCTAssertTrue(high.isHittable, "The Height presets are reachable in the Look tab")
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
