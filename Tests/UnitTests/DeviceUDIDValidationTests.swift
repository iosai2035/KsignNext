import XCTest
@testable import KsignNext

/// UDID validation (40 hex chars, either case) and the UserDefaults
/// store behind the manual paste fallback. The store is exercised
/// against an isolated suite so tests never touch the app's defaults.
@MainActor
final class DeviceUDIDValidationTests: XCTestCase {

    private static let validUpper = "00008030001A2B3C4D5E6F7890ABCDEF12345678"
    private static let validLower = "00008030001a2b3c4d5e6f7890abcdef12345678"

    func testValidUDIDs() {
        XCTAssertTrue(DeviceUDIDValidator.isValid(Self.validUpper))
        XCTAssertTrue(DeviceUDIDValidator.isValid(Self.validLower))
        XCTAssertTrue(DeviceUDIDValidator.isValid("  \(Self.validLower)  "),
                      "Surrounding whitespace is ignored")
    }

    func testNormalizedUppercases() {
        XCTAssertEqual(DeviceUDIDValidator.normalized(Self.validLower), Self.validUpper)
    }

    func testInvalidUDIDs() {
        XCTAssertFalse(DeviceUDIDValidator.isValid(""), "Empty is invalid")
        XCTAssertFalse(DeviceUDIDValidator.isValid(Self.validUpper.dropLast()),
                       "39 characters is invalid")
        XCTAssertFalse(DeviceUDIDValidator.isValid(Self.validUpper + "A"),
                       "41 characters is invalid")
        XCTAssertFalse(DeviceUDIDValidator.isValid("00008030001A2B3C4D5E6F7890ABCDEF1234567G"),
                       "G is not a hex digit")
        XCTAssertFalse(DeviceUDIDValidator.isValid("00008030-001A-2B3C-4D5E-6F7890ABCDEF"),
                       "Hyphens are not part of the UDID format")
    }

    func testValidateThrowsTypedError() {
        XCTAssertThrowsError(try DeviceUDIDValidator.validate("too short")) { error in
            XCTAssertEqual(error as? AppError,
                           AppError.validation(.invalidDeviceUDID("too short")))
        }
        XCTAssertThrowsError(try DeviceUDIDValidator.validate("   ")) { error in
            XCTAssertEqual(error as? AppError,
                           AppError.validation(.emptyValue(field: "UDID")))
        }
    }

    func testStoreRoundTrip() throws {
        let suite = UserDefaults(suiteName: "DeviceUDIDValidationTests")!
        suite.removePersistentDomain(forName: "DeviceUDIDValidationTests")
        let store = DeviceUDIDStore(defaults: suite)
        XCTAssertNil(store.savedUDID)

        let stored = try store.save(Self.validLower)
        XCTAssertEqual(stored, Self.validUpper)
        XCTAssertEqual(store.savedUDID, Self.validUpper)
        XCTAssertEqual(suite.string(forKey: DeviceUDIDStore.storageKey), Self.validUpper)

        // A fresh store over the same defaults sees the saved value.
        XCTAssertEqual(DeviceUDIDStore(defaults: suite).savedUDID, Self.validUpper)

        XCTAssertThrowsError(try store.save("not-a-udid"))
        XCTAssertEqual(store.savedUDID, Self.validUpper, "A failed save keeps the old value")

        store.clear()
        XCTAssertNil(store.savedUDID)
        XCTAssertNil(suite.string(forKey: DeviceUDIDStore.storageKey))
        suite.removePersistentDomain(forName: "DeviceUDIDValidationTests")
    }
}
