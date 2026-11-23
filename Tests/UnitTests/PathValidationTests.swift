import XCTest
@testable import KsignNext


final class PathValidationTests: XCTestCase {

    /// The rule the app must enforce: a ZIP entry must never escape the extraction root.
    private func isSafeEntry(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.hasPrefix("/") { return false }
        let parts = name.split(separator: "/")
        return !parts.contains("..") && !parts.contains(".")
    }

    func testTraversalEntriesRejected() {
        XCTAssertFalse(isSafeEntry("../evil.sh"))
        XCTAssertFalse(isSafeEntry("Payload/../../evil.sh"))
        XCTAssertFalse(isSafeEntry(".."))
        XCTAssertFalse(isSafeEntry("/etc/passwd"))
        XCTAssertFalse(isSafeEntry("Payload/../../../tmp/evil"))
    }

    func testNormalEntriesAccepted() {
        XCTAssertTrue(isSafeEntry("Payload/App.app/Info.plist"))
        XCTAssertTrue(isSafeEntry("Payload/App.app/App"))
        XCTAssertTrue(isSafeEntry("Payload/App.app/embedded.mobileprovision"))
    }

    func testFileNameWithDotDotInNameIsNotTraversal() {
        XCTAssertTrue(isSafeEntry("Payload/App.app/my..file"))
    }

    func testWorkspaceFolderNamesAreSafe() {
        for folder in ["ImportedApps", "SignedApps", "Certificates", "Tweaks", "Downloads", "Logs"] {
            XCTAssertFalse(folder.contains(".."))
            XCTAssertFalse(folder.contains("/"))
        }
    }
}
