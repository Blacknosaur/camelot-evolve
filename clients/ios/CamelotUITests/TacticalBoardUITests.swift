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

    /// Bar slots and palette chips are not always Buttons in the accessibility tree.
    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Opens a palette from the task tiles (`board-palette-players`, `board-palette-equipment`, `board-draw`),
    /// first finishing any open palette or selection so the tiles are showing.
    @MainActor
    private func openPalette(_ tile: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        finishPalette(in: app)
        if app.buttons["deselect"].exists { app.buttons["deselect"].tap() }
        let button = element(tile, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 3), "\(tile) is in the task tiles", file: file, line: line)
        button.tap()
        XCTAssertTrue(element("board-palette", in: app).waitForExistence(timeout: 3), "\(tile) opens its palette", file: file, line: line)
    }

    /// Arms a palette item (`board-item-<item>`), opening `palette` when the item is not on screen,
    /// and checks it is armed before placing.
    @MainActor
    private func arm(_ item: String, from palette: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chip = element("board-item-\(item)", in: app)
        if !chip.exists { openPalette(palette, in: app, file: file, line: line) }
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "\(item) is in the palette", file: file, line: line)
        if !chip.isSelected { chip.tap() }
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [armed], timeout: 3), .completed, "\(item) is armed", file: file, line: line)
    }

    /// Arms a drawing item from the Draw palette (`line-pass`, `line-run`, `polyline`, `zoneRect`, …).
    @MainActor
    private func armDraw(_ item: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        arm(item, from: "board-draw", in: app, file: file, line: line)
    }

    /// Done on the open palette: back to the task tiles (or the selection bar when something is selected).
    @MainActor
    private func finishPalette(in app: XCUIApplication) {
        let done = app.buttons["board-disarm"]
        guard done.exists else { return }
        done.tap()
        XCTAssertTrue(waitUntilGone(done), "Done closes the palette")
    }

    /// Opens the selection's detail card from the selection bar's Edit.
    @MainActor
    private func openDetails(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let edit = element("board-selection-edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "The selection bar offers Edit", file: file, line: line)
        edit.tap()
        // The card starts collapsed when it would cover the selection.
        let expand = app.buttons["board-inspector-expand"]
        if expand.waitForExistence(timeout: 1) { expand.tap() }
        XCTAssertTrue(app.otherElements["board-inspector"].waitForExistence(timeout: 3), "Edit shows the detail card", file: file, line: line)
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
        for id in ["board-palette-players", "board-palette-equipment", "board-draw", "board-animate", "board-library"] {
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
        XCTAssertTrue(element("board-starter", in: app).waitForExistence(timeout: 3), "An empty board offers a way to start")
        attachScreenshot("Empty board starter")

        // `-uiTestBoards` names the board "UITest Board N" at creation, so teardown always finds it.
        XCTAssertTrue(app.buttons["board-name"].label.hasPrefix(boardPrefix) || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", boardPrefix)).firstMatch.exists,
                      "Test boards are named for cleanup from creation")

        // Two players from the starter card (Players opens with Home armed), connected by a pass line.
        element("board-start-players", in: app).tap()
        XCTAssertTrue(element("board-item-home", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("board-item-home", in: app).isSelected, "The Players palette opens with Home armed")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        armDraw("line-pass", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        waitForValue(canvas, beginsWith: "3 elements, 2 connected")
        finishPalette(in: app)

        // Select the line and make it a run from the selection bar.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let lineType = element("board-selection-line-type", in: app)
        XCTAssertTrue(lineType.waitForExistence(timeout: 3), "A selected line offers its type in the selection bar")
        waitForValue(lineType, "Pass")
        lineType.tap()
        let run = app.buttons["Run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 3), "Line types are offered in a menu")
        run.tap()
        waitForValue(lineType, "Run")

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

        // Rotate and resize the selected player from its detail card (Edit).
        XCTAssertFalse(app.otherElements["board-inspector"].exists, "Selecting does not open the card by itself")
        openDetails(in: app)
        let rotation = app.sliders["board-rotation-slider"]
        XCTAssertTrue(rotation.waitForExistence(timeout: 3), "The player's card has rotation")
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

        // Deselecting hides the card and brings back the task tiles.
        app.buttons["deselect"].tap()
        XCTAssertTrue(waitUntilGone(app.otherElements["board-inspector"]), "Deselecting hides the card")
        XCTAssertTrue(element("board-toolbar", in: app).waitForExistence(timeout: 3))

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

    /// The board canvas never moves or resizes when floating panels or bars change: selection bar,
    /// detail card, stage strip and deselection, in portrait and landscape.
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

            arm("home", from: "board-palette-players", in: app)
            XCTAssertEqual(canvas.frame, baseline, "The palette does not move the board (\(name))")
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            // Tapping the placed player selects it; Done then shows the selection bar.
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            waitForValue(canvas, endsWith: " selected")
            finishPalette(in: app)
            XCTAssertTrue(element("board-selection", in: app).waitForExistence(timeout: 3), "Selection shows the selection bar (\(name))")
            XCTAssertEqual(canvas.frame, baseline, "The selection bar does not move the board (\(name))")
            openDetails(in: app)
            XCTAssertEqual(canvas.frame, baseline, "The detail card does not move the board (\(name))")
            attachScreenshot("Card floating \(name)")

            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).tap()
            XCTAssertTrue(waitUntilGone(app.otherElements["board-inspector"]), "Tapping empty ground deselects and hides the card (\(name))")
            XCTAssertTrue(element("board-toolbar", in: app).waitForExistence(timeout: 3))
            XCTAssertEqual(canvas.frame, baseline, "Deselecting does not move the board (\(name))")

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
        arm("ball", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        armDraw("polyline", in: app)
        for point in [CGVector(dx: 0.25, dy: 0.35), CGVector(dx: 0.5, dy: 0.12), CGVector(dx: 0.75, dy: 0.35)] {
            canvas.coordinate(withNormalizedOffset: point).tap()
        }
        app.buttons["board-path-done"].tap()
        waitForValue(canvas, beginsWith: "2 elements")
        finishPalette(in: app)

        // Three stages, then follow the polyline from stage 1: progress spreads 0%, 50%, 100%.
        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-stage-add"].waitForExistence(timeout: 3))
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-add"].tap()
        XCTAssertTrue(app.buttons["board-stage-3"].waitForExistence(timeout: 3))
        app.buttons["board-stage-1"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        openDetails(in: app)
        let motion = app.buttons["board-card-tab-motion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 3), "The ball's card has a Motion tab in animation mode")
        motion.tap()
        let follow = app.buttons["board-follow-path"]
        XCTAssertTrue(follow.waitForExistence(timeout: 3), "The selected ball offers Follow path")
        follow.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        let progress = app.sliders["board-path-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "Progress is editable once on the path")
        // The transport's follow state is hidden while the selection bar shows, so read each stage's progress.
        waitForValue(progress, "0%")
        app.buttons["board-stage-2"].tap()
        waitForValue(progress, "50%")
        app.buttons["board-stage-3"].tap()
        waitForValue(progress, "100%")
        attachScreenshot("Follow path over stages")

        // Stage 2: drag the ball further along the path; progress follows the finger.
        app.buttons["board-stage-2"].tap()
        waitForValue(progress, "50%")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(forDuration: 0.15, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.235)))
        let slid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value IN {'0%', '50%', '100%'})"), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [slid], timeout: 4), .completed, "Dragging along the path changes stage 2's progress, got \(String(describing: progress.value))")
        attachScreenshot("Ball dragged along path")
        app.buttons["board-stage-1"].tap()
        waitForValue(progress, "0%")
        app.buttons["board-stage-3"].tap()
        waitForValue(progress, "100%")

        // Ghosts live in the transport, which shows once nothing is selected.
        app.buttons["deselect"].tap()
        let onion = app.buttons["board-onion-toggle"]
        XCTAssertTrue(onion.waitForExistence(timeout: 3), "The transport is back after deselecting")
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

    /// Animation mode: the task tiles give way to the transport; stages can be added, timed, reordered,
    /// deleted, played and scrubbed; Done brings the tiles back.
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
        arm("home", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        finishPalette(in: app)

        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-animation-done"].waitForExistence(timeout: 3), "Done leaves animation mode")
        // Paired with a positive so renaming an identifier cannot quietly make these vacuous.
        XCTAssertTrue(app.buttons["board-play"].waitForExistence(timeout: 3), "The transport is up")
        XCTAssertFalse(app.buttons["board-library"].exists, "The task tiles give way to the transport")
        XCTAssertFalse(app.buttons["board-draw"].exists)
        XCTAssertEqual(app.buttons["board-stage-1"].label, "Step 1", "Stages are called steps")
        app.buttons["board-stage-add"].tap()
        // Move the player in stage 2 so there is motion.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
        XCTAssertTrue(element("board-selection", in: app).waitForExistence(timeout: 3), "The moved player is selected")
        XCTAssertFalse(app.buttons["board-play"].exists, "The selection bar takes the transport's place")
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

        // The transport shows once nothing is selected.
        if app.buttons["deselect"].exists { app.buttons["deselect"].tap() }
        XCTAssertTrue(app.buttons["board-play"].waitForExistence(timeout: 3))
        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot("Playing")
        app.buttons["board-play"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))

        let scrubber = app.sliders["board-scrubber"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).press(forDuration: 0.05, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertNotEqual(scrubber.value as? String, "0%", "Scrubbing moves the playhead")

        app.buttons["board-animation-done"].tap()
        XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 3), "Tiles come back after Done")
        XCTAssertTrue(app.buttons["board-animate"].exists, "…including the Animate tile")
        XCTAssertFalse(app.buttons["board-stage-1"].exists, "The stage strip is gone")
        app.buttons["board-close"].tap()
    }

    /// No Select tool: an armed palette item places on empty field and stays armed until Done, touching an
    /// element selects it, drawn lines stay armed and flash instead of being selected, and picking from the
    /// library opens the matching palette. The task tiles fit without scrolling.
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
        XCTAssertTrue(app.buttons["board-library"].waitForExistence(timeout: 3), "The task tiles are up")
        XCTAssertFalse(app.buttons["board-tool-select"].exists, "There is no Select tool")
        assertToolbarFits(app, "portrait")
        attachScreenshot("Task tiles")

        // Equipment opens with Cone armed: three cones with three taps, still armed after.
        openPalette("board-palette-equipment", in: app)
        let cone = element("board-item-cone", in: app)
        XCTAssertTrue(cone.isSelected, "Equipment opens with Cone armed")
        XCTAssertTrue(app.buttons["board-disarm"].exists, "The palette has Done to finish")
        for x in [0.3, 0.5, 0.7] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.3)).tap()
        }
        waitForValue(canvas, "3 elements")
        XCTAssertTrue(cone.isSelected, "Still armed after placing")
        XCTAssertTrue(app.buttons["board-disarm"].exists)
        attachScreenshot("Cones armed")
        // Tapping the armed chip again keeps it armed.
        cone.tap()
        XCTAssertTrue(cone.isSelected, "Tapping a chip arms it, never toggles it off")

        // Tapping an existing cone selects it instead of placing another.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        waitForValue(canvas, "3 elements, Cone selected")
        finishPalette(in: app)
        XCTAssertTrue(element("board-selection", in: app).waitForExistence(timeout: 3), "Done shows the selection's bar")
        XCTAssertEqual(element("board-selection-title", in: app).label, "Cone")
        XCTAssertFalse(app.otherElements["board-inspector"].exists, "Selecting does not open the card")
        openDetails(in: app)
        XCTAssertTrue(app.sliders["board-rotation-slider"].waitForExistence(timeout: 3), "Edit shows the cone's card")
        app.buttons["board-card-close"].firstMatch.tap()
        XCTAssertTrue(waitUntilGone(app.otherElements["board-inspector"]), "Close hides the card")
        XCTAssertTrue(element("board-selection", in: app).exists, "…and keeps the selection")
        waitForValue(canvas, endsWith: "Cone selected")
        app.buttons["deselect"].tap()
        XCTAssertTrue(element("board-toolbar", in: app).waitForExistence(timeout: 3), "Deselecting returns to the task tiles")

        // A player placed, then finished with Done, then dragged straight away.
        arm("home", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        waitForValue(canvas, "4 elements")
        finishPalette(in: app)
        XCTAssertTrue(app.buttons["board-library"].exists, "The task tiles are back")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.62)))
        waitForValue(canvas, beginsWith: "4 elements")
        waitForValue(canvas, endsWith: "Player 1 selected")
        XCTAssertTrue(element("board-selection", in: app).waitForExistence(timeout: 3), "Dragging moves and selects the player")

        // A palette item dragged straight onto the pitch is placed where it is dropped, without arming it.
        openPalette("board-palette-players", in: app)
        // Away is next to Home, on screen without scrolling the palette.
        let away = element("board-item-away", in: app)
        XCTAssertTrue(away.waitForExistence(timeout: 3) && away.isHittable)
        away.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.4, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        waitForValue(canvas, beginsWith: "5 elements")
        XCTAssertTrue(element("board-item-home", in: app).isSelected, "Home stays armed")
        XCTAssertFalse(away.isSelected, "Dragging from the palette does not arm the item")

        // Pass line from Draw: dragging draws it; it flashes instead of being selected and Draw stays armed.
        armDraw("line-pass", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        waitForValue(canvas, beginsWith: "6 elements")
        XCTAssertFalse((canvas.value as? String ?? "").hasSuffix("selected"), "The drawn line flashes instead of being selected")
        XCTAssertTrue(element("board-item-line-pass", in: app).isSelected, "Drawing stays armed until Done")
        XCTAssertTrue(app.buttons["board-disarm"].exists)
        attachScreenshot("Line drawn, still armed")
        finishPalette(in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let title = element("board-selection-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Tapping the line selects it")
        XCTAssertEqual(title.label, "Pass")
        // VoiceOver hears what is selected from the board element itself, not only from the bar.
        waitForValue(canvas, endsWith: "Pass selected")
        XCTAssertTrue(element("board-selection-line-type", in: app).exists, "Line types are one tap away")
        attachScreenshot("Line selected")
        app.buttons["deselect"].tap()

        // More opens the library; picking an item opens its palette with it armed.
        app.buttons["board-library"].tap()
        XCTAssertTrue(app.otherElements["board-library-sheet"].waitForExistence(timeout: 3) || app.searchFields.firstMatch.waitForExistence(timeout: 3))
        attachScreenshot("Library medium")
        app.swipeUp()
        attachScreenshot("Library large")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Hurdle")
        let hurdle = app.buttons["board-library-hurdle"]
        XCTAssertTrue(hurdle.waitForExistence(timeout: 3), "Hurdle is in the library")
        hurdle.tap()
        XCTAssertTrue(element("board-palette", in: app).waitForExistence(timeout: 3), "Picking from the library opens a palette")
        let hurdleChip = element("board-item-hurdle", in: app)
        XCTAssertTrue(hurdleChip.waitForExistence(timeout: 3) && hurdleChip.isSelected, "…with the picked item armed")
        finishPalette(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        assertToolbarFits(app, "landscape")
        attachScreenshot("Task rail landscape")
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
        arm("home", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        finishPalette(in: app)

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
        XCTAssertTrue(camera.waitForExistence(timeout: 3), "Orbiting leaves nothing selected, so the transport stays")
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
        arm("referee", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        waitForValue(canvas, beginsWith: "1 element")
        arm("ball", from: "board-palette-players", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)).tap()
        waitForValue(canvas, beginsWith: "2 elements")
        finishPalette(in: app)

        app.buttons["board-animate"].tap()
        XCTAssertTrue(app.buttons["board-stage-add"].waitForExistence(timeout: 3))
        app.buttons["board-stage-add"].tap()
        app.buttons["board-stage-1"].tap()
        chooseFromViewMenu("Tilted", in: app)
        let view3D = app.otherElements["board-3d-view"]
        XCTAssertTrue(view3D.waitForExistence(timeout: 10))
        waitForValue(app.buttons["board-view"], "Tilted, Orbit")

        // Select the referee from the top view layout, then look through its eyes from the Edit card.
        chooseFromViewMenu("Top", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
        XCTAssertTrue(element("board-selection", in: app).waitForExistence(timeout: 3), "The referee is selected")
        openDetails(in: app)
        let viewFrom = app.buttons["board-view-from"]
        XCTAssertTrue(viewFrom.waitForExistence(timeout: 3), "People have View from here")
        viewFrom.tap()
        XCTAssertTrue(view3D.waitForExistence(timeout: 10), "View from here switches Top to 3D")
        waitForValue(app.buttons["board-view"], "Tilted, POV")
        attachScreenshot("Referee point of view")

        // Camera keys live in the transport, which shows once nothing is selected.
        app.buttons["deselect"].tap()
        let camera = app.descendants(matching: .any)["board-camera-key"]
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        waitForValue(app.buttons["board-view"], "Tilted, POV")
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
        armDraw("line-pass", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        waitForValue(canvas, beginsWith: "1 element")
        finishPalette(in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(element("board-selection-line-type", in: app).waitForExistence(timeout: 3), "The line is selected")
        openDetails(in: app)

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
