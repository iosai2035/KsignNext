import XCTest
@testable import KsignNext

/// Session persistence and the AltLoad backoff rules. Keychain access
/// uses an isolated service name so tests never touch the app's real
/// Apple ID state.
final class AppleIDSessionStoreTests: XCTestCase {

    private var suite: UserDefaults!
    private var store: AppleIDSessionStore!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AppleIDSessionStoreTests")!
        suite.removePersistentDomain(forName: "AppleIDSessionStoreTests")
        store = AppleIDSessionStore(
            keychain: KeychainService(service: "com.ksignnext.app.test-appleid"),
            defaults: suite)
        store.clearSession()
    }

    private func sampleSession() -> AppleIDSession {
        AppleIDSession(
            email: "test@example.com", firstName: "Test", lastName: "User",
            adsid: "adsid-1", serverURL: "https://mac-ani.jkcoxson.com",
            claimPreset: "sideinstaller", signedInAt: Date(), appTokenProven: true)
    }

    func testSaveAndLoadSessionRoundTrip() {
        store.saveSession(sampleSession(), password: "secret123")
        let loaded = store.loadSession()
        XCTAssertEqual(loaded?.email, "test@example.com")
        XCTAssertEqual(loaded?.adsid, "adsid-1")
        XCTAssertEqual(loaded?.claimPreset, "sideinstaller")
        XCTAssertTrue(loaded?.appTokenProven == true)
        XCTAssertEqual(store.loadPassword(email: "test@example.com"), "secret123")
        XCTAssertEqual(store.savedEmail, "test@example.com")
    }

    func testClearSessionRemovesPasswordAndRecord() {
        store.saveSession(sampleSession(), password: "secret123")
        store.clearSession()
        XCTAssertNil(store.loadSession())
        XCTAssertNil(store.loadPassword(email: "test@example.com"))
        // The email stays so the form can pre-fill it.
        XCTAssertEqual(store.savedEmail, "test@example.com")
    }

    func testRejectionCountAndPause() {
        XCTAssertEqual(store.recordRejection(), 1)
        XCTAssertEqual(store.recordRejection(), 2)
        XCTAssertEqual(store.rejectionCount, 2)
        XCTAssertNil(store.pauseUntil())
        store.pause()
        XCTAssertNotNil(store.pauseUntil())
        XCTAssertTrue(store.isPaused)
        store.resetRejections()
        XCTAssertEqual(store.rejectionCount, 0)
    }

    func testExpiredPauseIsNotPaused() {
        store.pause(until: Date().addingTimeInterval(-60))
        XCTAssertNil(store.pauseUntil())
        XCTAssertFalse(store.isPaused)
    }
}
