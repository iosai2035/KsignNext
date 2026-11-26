import XCTest
@testable import KsignNext

/// The `EntitlementsValidator` model builders that `SigningEngine.validate`
/// uses: a parsed entitlements plist becomes a typed model, and a
/// provisioning profile's string entitlements become the profile model
/// the validator compares against.
final class EntitlementsValidatorModelTests: XCTestCase {

    func testPlistDictionaryMapsTypedValues() {
        let model = EntitlementsValidator.model(
            fromPlistDictionary: [
                "application-identifier": "TEAMID.com.example.app",
                "get-task-allow": true,
                "keychain-access-groups": ["TEAMID.com.example.app"],
                "com.apple.developer.team-identifier": "TEAMID",
                "aps-environment": "development",
            ],
            source: .custom
        )
        XCTAssertEqual(model.applicationIdentifier, "TEAMID.com.example.app")
        XCTAssertEqual(model.boolValue(forKey: "get-task-allow"), true)
        XCTAssertEqual(model.stringArrayValue(forKey: "keychain-access-groups"), ["TEAMID.com.example.app"])
        XCTAssertEqual(model.teamIdentifier, "TEAMID")
        XCTAssertEqual(model.source, .custom)
    }

    func testStringDictionaryMapsAllValuesToStrings() {
        let model = EntitlementsValidator.model(
            fromStringDictionary: [
                "application-identifier": "TEAMID.com.example.*",
                "get-task-allow": "true",
            ],
            source: .provisioningProfile
        )
        XCTAssertEqual(model.applicationIdentifier, "TEAMID.com.example.*")
        XCTAssertEqual(model["get-task-allow"], .string("true"))
        XCTAssertEqual(model.source, .provisioningProfile)
    }

    func testValidatePassesWhenProfileGrantsEveryKey() throws {
        let app = EntitlementsValidator.model(
            fromPlistDictionary: ["application-identifier": "TEAMID.com.example.app", "get-task-allow": true],
            source: .custom
        )
        let profile = EntitlementsValidator.model(
            fromStringDictionary: ["application-identifier": "TEAMID.com.example.*", "get-task-allow": "true"],
            source: .provisioningProfile
        )
        XCTAssertNoThrow(try EntitlementsValidator.validate(app: app, profile: profile))
    }

    func testValidateThrowsForKeyMissingFromProfile() {
        let app = EntitlementsValidator.model(
            fromPlistDictionary: ["application-identifier": "TEAMID.com.example.app", "com.apple.developer.push-notifications": true],
            source: .custom
        )
        let profile = EntitlementsValidator.model(
            fromStringDictionary: ["application-identifier": "TEAMID.com.example.*"],
            source: .provisioningProfile
        )
        XCTAssertThrowsError(try EntitlementsValidator.validate(app: app, profile: profile)) { error in
            guard case AppError.signing(.unsupportedEntitlement(let key)) = error else {
                return XCTFail("expected unsupportedEntitlement, got \(error)")
            }
            XCTAssertEqual(key, "com.apple.developer.push-notifications")
        }
    }

    func testValidateIdentifiersThrowsOnTeamMismatch() {
        let app = EntitlementsValidator.model(
            fromPlistDictionary: ["com.apple.developer.team-identifier": "TEAMAAA"],
            source: .custom
        )
        let profile = ProvisioningModel(
            name: "Profile",
            uuid: "test-profile-uuid",
            appIdentifier: "TEAMBBB.com.example.*",
            teamIdentifier: "TEAMBBB",
            entitlements: [:]
        )
        XCTAssertThrowsError(try EntitlementsValidator.validateIdentifiers(app: app, profile: profile))
    }
}
