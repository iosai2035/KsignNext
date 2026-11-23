import XCTest
@testable import KsignNext


final class EntitlementsTests: XCTestCase {

    private func entitlementsPlist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func testApplicationIdentifierEntitlement() throws {
        let data = try entitlementsPlist(["application-identifier": "TEAMID.com.example.app", "get-task-allow": true])
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["application-identifier"] as? String, "TEAMID.com.example.app")
        XCTAssertEqual(decoded?["get-task-allow"] as? Bool, true)
    }

    func testEmptyEntitlementsAreValidPlist() throws {
        let data = try entitlementsPlist([:])
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.isEmpty ?? false)
    }

    func testEntitlementsWithArrayValue() throws {
        let data = try entitlementsPlist(["keychain-access-groups": ["TEAMID.com.example.app"]])
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual((decoded?["keychain-access-groups"] as? [String])?.first, "TEAMID.com.example.app")
    }

    func testMalformedEntitlementsRejected() {
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: Data("<plist><dict>".utf8), options: [], format: nil))
    }
}
