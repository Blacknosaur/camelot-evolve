import XCTest

final class OnboardingUITests: XCTestCase {
    @MainActor
    func testCreatesAccountAndOrganization() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()

        let suffix = String(Int(Date().timeIntervalSince1970))
        app.textFields["Your name"].tap()
        app.textFields["Your name"].typeText("Phone Test")
        app.textFields["Club or organization"].tap()
        app.textFields["Club or organization"].typeText("Camelot Test \(suffix)")
        app.textFields["Email"].tap()
        app.textFields["Email"].typeText("phone-\(suffix)@camelot.local")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("camelot-test-123")
        app.swipeDown()
        app.buttons["onboarding-submit"].tap()

        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["New project"].exists)

        let emptyStateCreate = app.buttons["Create project"]
        if emptyStateCreate.waitForExistence(timeout: 3) {
            emptyStateCreate.tap()
        } else {
            app.buttons["New project"].tap()
        }
        app.textFields["Project name"].tap()
        app.textFields["Project name"].typeText("Weekend Match")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Weekend Match"].waitForExistence(timeout: 5))
    }
}
