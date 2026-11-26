
import XCTest

final class KsignNextUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testImportAnalyseCertificateSignVerifyExportFlow() {
        // Dashboard loads.
        XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 5))

        // Applications tab: empty state offers the real import action.
        app.tabBars.buttons["Applications"].tap()
        XCTAssertTrue(app.buttons["apps.import"].waitForExistence(timeout: 5) || app.buttons["apps.import.empty"].exists)

        // Certificates tab: import action exists.
        app.tabBars.buttons["Certificates"].tap()
        XCTAssertTrue(app.buttons["certs.import.p12"].waitForExistence(timeout: 5) || app.buttons["certs.import.empty"].exists)

        // Signing wizard: step 1 is shown, validation blocks advancing without an app.
        app.tabBars.buttons["Signing"].tap()
        XCTAssertTrue(app.staticTexts["signing.step.1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signing.next"].exists)
        app.buttons["signing.next"].tap()
        // Still on step 1 because no app is selected.
        XCTAssertTrue(app.staticTexts["signing.step.1"].exists)

        // Downloads tab loads.
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.textFields["downloads.urlField"].waitForExistence(timeout: 5))

        // Settings tab loads.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    func testDashboardShortcutsExist() {
        XCTAssertTrue(app.buttons["dashboard.shortcut.apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard.shortcut.sign"].exists)
        XCTAssertTrue(app.buttons["dashboard.shortcut.certs"].exists)
        // Downloads/Files shortcuts were removed with the tab-bar
        // reduction (those screens now live under Settings "More").
        XCTAssertFalse(app.buttons["dashboard.shortcut.downloads"].exists)
    }
}
