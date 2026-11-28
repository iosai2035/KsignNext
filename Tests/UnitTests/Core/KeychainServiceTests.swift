import XCTest
@testable import KsignNext

/// KeychainService tests run against the isolated test service
/// `com.ksignnext.app.tests` — never the production namespace.
/// Every item written here is deleted in `tearDown`.
final class KeychainServiceTests: XCTestCase {

    private var keychain: KeychainService!
    private var accounts: [String] = []

    override func setUp() {
        super.setUp()
        keychain = KeychainTestService.make()
        accounts = []
    }

    override func tearDown() {
        for account in accounts { try? keychain.delete(account: account) }
        accounts = []
        keychain = nil
        super.tearDown()
    }

    private func uniqueAccount() -> String {
        let account = "test-\(UUID().uuidString)"
        accounts.append(account)
        return account
    }

    func testSaveReadDeletePassword_roundTrip() throws {
        let account = uniqueAccount()
        try keychain.savePassword("s3cret-pw", account: account)
        XCTAssertEqual(try keychain.readPassword(account: account), "s3cret-pw")
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.readPassword(account: account))
    }

    func testReadPassword_missingReturnsNil() throws {
        XCTAssertNil(try keychain.readPassword(account: uniqueAccount()))
    }

    func testDelete_missingSucceeds() throws {
        // Deleting a missing item is success, not an error.
        XCTAssertNoThrow(try keychain.delete(account: uniqueAccount()))
    }

    func testSave_overwritesExisting() throws {
        let account = uniqueAccount()
        try keychain.savePassword("first", account: account)
        try keychain.savePassword("second", account: account)
        XCTAssertEqual(try keychain.readPassword(account: account), "second")
    }

    func testSaveReadDeleteData_roundTrip() throws {
        let account = uniqueAccount()
        let data = Data([0x01, 0x02, 0x03, 0xFF])
        try keychain.save(data, account: account)
        XCTAssertEqual(try keychain.read(account: account), data)
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
    }

    func testRead_missingDataReturnsNil() throws {
        XCTAssertNil(try keychain.read(account: uniqueAccount()))
    }

    func testExists_trueAfterSaveFalseAfterDelete() throws {
        let account = uniqueAccount()
        XCTAssertFalse(keychain.exists(account: account))
        try keychain.savePassword("pw", account: account)
        XCTAssertTrue(keychain.exists(account: account))
        try keychain.delete(account: account)
        XCTAssertFalse(keychain.exists(account: account))
    }

    func testIsolatedService_doesNotTouchProductionService() throws {
        let account = uniqueAccount()
        try keychain.savePassword("test-only", account: account)
        // The same account in the production namespace must be empty:
        // the test service never writes there.
        let production = KeychainService()
        XCTAssertNil(try production.readPassword(account: account))
        XCTAssertFalse(production.exists(account: account))
        XCTAssertEqual(try keychain.readPassword(account: account), "test-only")
    }
}
