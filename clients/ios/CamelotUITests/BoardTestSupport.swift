import XCTest

extension XCUIApplication {
    /// Creates a board from the Boards tab's New board menu and returns its canvas.
    /// On a device a tap can land while the menu is still animating and be dropped,
    /// so the menu is reopened up to three times before failing.
    @MainActor
    func openNewBoard(_ field: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let canvas = otherElements["board-canvas"]
        for _ in 0..<3 {
            let menu = buttons["boards-new"].firstMatch
            guard menu.waitForExistence(timeout: 5) else { break }
            menu.tap()
            let item = buttons[field]
            guard item.waitForExistence(timeout: 3) else { continue }
            item.tap()
            if canvas.waitForExistence(timeout: 6) { return canvas }
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 4), "A new \(field) board opens", file: file, line: line)
        return canvas
    }
}
