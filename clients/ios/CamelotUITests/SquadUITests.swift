import XCTest

/// Seeds "UITest …" squad players, edits a number, then on a "UITest Board" places a Home 4-3-3
/// from three squad players plus filled slots, a full Away 4-4-2, and undoes the away team.
/// Teardown relaunches with `-removeUITestSquad -removeUITestBoards`, which delete only those
/// players, photos and boards, so it is safe on a phone with real data.
final class SquadUITests: XCTestCase {
    @MainActor
    override func tearDown() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestSquad", "-removeUITestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Squad"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: player("UITest", in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed, "UITest players are removed after the test")
        app.terminate()
        try await super.tearDown()
    }

    @MainActor
    private func continueOfflineIfNeeded(_ app: XCUIApplication) {
        if app.buttons["Continue offline"].waitForExistence(timeout: 4) { app.buttons["Continue offline"].tap() }
    }

    @MainActor
    private func player(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'squad-player' AND label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(expected), got \(String(describing: element.value))", file: file, line: line)
    }

    /// The board's value carries the selection after the count, so counts are matched as a prefix.
    @MainActor
    private func waitForValue(_ element: XCUIElement, beginsWith prefix: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", prefix), object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected a value starting with \(prefix), got \(String(describing: element.value))", file: file, line: line)
    }

    @MainActor
    private func openLineup(in app: XCUIApplication) {
        let library = app.buttons["board-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let lineup = app.buttons["squad-add-lineup"]
        if !lineup.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(lineup.waitForExistence(timeout: 5), "Add lineup is in the library")
        lineup.tap()
        XCTAssertTrue(app.buttons["squad-lineup-place"].waitForExistence(timeout: 5))
    }

    /// Scrolls a list row until it is fully above `bar` (and below the navigation bar), so taps land on it.
    @MainActor
    private func scrollFullyVisible(_ element: XCUIElement, above bar: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        let top = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<8 {
            let frame = element.frame, limit = bar.exists ? bar.frame.minY : app.frame.maxY
            if frame.maxY <= limit && frame.minY >= top { return }
            if frame.minY < top { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
        }
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected \(expected), got \(element.label)", file: file, line: line)
    }

    @MainActor
    func testSquadPlayersEditAndPlaceOnABoard() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-seedUITestSquad", "-uiTestBoards"]
        app.launch()
        continueOfflineIfNeeded(app)

        app.tabBars.buttons["Squad"].tap()
        XCTAssertTrue(app.navigationBars["Squad"].waitForExistence(timeout: 5))
        XCTAssertTrue(player("UITest Alex Moreno", in: app).waitForExistence(timeout: 10), "Seeded players are listed")
        attachScreenshot("Squad tab")
        // The team chips scroll with the list, so the navigation bar keeps its title.
        app.swipeUp(velocity: .slow)
        XCTAssertTrue(app.navigationBars["Squad"].staticTexts["Squad"].waitForExistence(timeout: 3), "The title stays in the navigation bar when scrolled")
        attachScreenshot("Squad tab scrolled")
        app.swipeDown(velocity: .slow)

        // Search narrows the list (the player is below the fold in portrait).
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("UITest Jonah")
        let jonah = player("UITest Jonah Reed", in: app)
        XCTAssertTrue(jonah.waitForExistence(timeout: 5))

        // Edit a number.
        jonah.tap()
        let number = app.textFields["squad-editor-number"]
        XCTAssertTrue(number.waitForExistence(timeout: 5), "The player editor opens")
        attachScreenshot("Player editor")
        // Select the old number (double-tap) so typing replaces it.
        number.tap()
        number.doubleTap()
        number.typeText("19")
        waitForValue(number, "19")
        app.buttons["squad-editor-save"].tap()
        XCTAssertTrue(player("Number 19, UITest Jonah Reed", in: app).waitForExistence(timeout: 5), "The edited number is shown")

        // A new board: a 4-3-3 for Home with three squad players, filled to eleven.
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        waitForValue(canvas, beginsWith: "0 elements")

        openLineup(in: app)
        let squadRows = app.buttons.matching(identifier: "squad-lineup-player")
        XCTAssertTrue(squadRows.firstMatch.waitForExistence(timeout: 5), "Squad players are listed in the lineup sheet")
        // Rows load lazily, so find each player by name and scroll it clear of the Place button
        // before tapping: a row clipped by the list's bottom edge still reports its full frame, so a
        // tap at its centre would land below the list.
        for name in ["UITest Alex Moreno", "UITest Ben Carter", "UITest Eli Novak"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'squad-lineup-player' AND label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) is listed")
            scrollFullyVisible(row, above: app.buttons["squad-lineup-place"], in: app)
            row.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, "\(name) is selected in the lineup sheet")
        }
        let place = app.buttons["squad-lineup-place"]
        waitForLabel(place, "Place 11 players (3 from squad)")
        attachScreenshot("Lineup sheet home")
        place.tap()
        waitForValue(canvas, beginsWith: "11 elements", timeout: 8)

        // The whole Away team in a 4-4-2 without squad players.
        openLineup(in: app)
        let sides = app.segmentedControls["squad-lineup-side"]
        XCTAssertTrue(sides.waitForExistence(timeout: 3))
        sides.buttons["Away"].tap()
        let formation = app.buttons["squad-formation-4-4-2"]
        XCTAssertTrue(formation.waitForExistence(timeout: 3), "Formation previews are listed")
        formation.tap()
        waitForLabel(place, "Place full team (11)")
        attachScreenshot("Lineup sheet away")
        place.tap()
        waitForValue(canvas, beginsWith: "22 elements", timeout: 8)
        attachScreenshot("Board with both teams")

        app.buttons["board-undo"].tap()
        waitForValue(canvas, beginsWith: "11 elements")

        app.buttons["board-close"].tap()
        // Closing writes the board and its thumbnail before the card appears.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'UITest Board'")).firstMatch.waitForExistence(timeout: 20),
                      "The board is saved and listed in the Boards tab")
    }

    /// Design review in dark mode. `-app.appearance dark` is a launch-argument default, so it is never saved.
    @MainActor
    func testSquadScreensInDarkMode() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-seedUITestSquad", "-uiTestBoards", "-app.appearance", "dark"]
        app.launch()
        continueOfflineIfNeeded(app)
        app.tabBars.buttons["Squad"].tap()
        let keeper = player("UITest Alex Moreno", in: app)
        XCTAssertTrue(keeper.waitForExistence(timeout: 10))
        attachScreenshot("Squad tab dark")
        app.swipeUp(velocity: .slow)
        attachScreenshot("Squad tab scrolled dark")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["Squad"].waitForExistence(timeout: 5))
        attachScreenshot("Squad tab landscape dark")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(keeper.waitForExistence(timeout: 5))
        keeper.tap()
        XCTAssertTrue(app.buttons["squad-editor-save"].waitForExistence(timeout: 5))
        attachScreenshot("Player editor dark")
        app.buttons["Cancel"].firstMatch.tap()

        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        XCTAssertTrue(canvas.exists)
        openLineup(in: app)
        app.segmentedControls["squad-lineup-side"].buttons["Away"].tap()
        attachScreenshot("Lineup sheet dark")
        app.buttons["Cancel"].firstMatch.tap()
    }
}
