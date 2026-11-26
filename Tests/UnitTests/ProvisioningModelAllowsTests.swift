import XCTest
@testable import KsignNext

/// Wildcard boundary for `ProvisioningModel.allows`: a profile for
/// "TEAM.com.example.*" must allow "com.example.foo" but NOT
/// "com.exampleFoo" — the prefix needs the trailing dot (audit finding
/// 2026-11-26: the old code allowed com.exampleFoo, com.example2).
final class ProvisioningModelAllowsTests: XCTestCase {

    private func profile(appIdentifier: String) -> ProvisioningModel {
        ProvisioningModel(
            name: "Test",
            uuid: "00000000-0000-0000-0000-000000000000",
            appIdentifier: "TEAMID.\(appIdentifier)",
            teamIdentifier: "TEAMID"
        )
    }

    func testWildcardAllowsSubIdentifier() {
        XCTAssertTrue(profile(appIdentifier: "com.example.*").allows(bundleID: "com.example.foo"))
        XCTAssertTrue(profile(appIdentifier: "com.example.*").allows(bundleID: "com.example.foo.bar"))
    }

    func testWildcardRejectsPrefixWithoutDot() {
        let wildcard = profile(appIdentifier: "com.example.*")
        XCTAssertFalse(wildcard.allows(bundleID: "com.exampleFoo"))
        XCTAssertFalse(wildcard.allows(bundleID: "com.example2"))
        XCTAssertFalse(wildcard.allows(bundleID: "com.example"))
    }

    func testExactMatch() {
        XCTAssertTrue(profile(appIdentifier: "com.example.app").allows(bundleID: "com.example.app"))
        XCTAssertFalse(profile(appIdentifier: "com.example.app").allows(bundleID: "com.example.other"))
    }

    func testStarAllowsEverything() {
        XCTAssertTrue(profile(appIdentifier: "*").allows(bundleID: "anything.at.all"))
    }
}
