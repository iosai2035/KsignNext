import XCTest
@testable import KsignNext

/// Developer-service JSON parsing (Phase 2): the Rust core emits
/// camelCase keys for teams/devices/App IDs/certificates and the
/// profile's binary blob base64-encoded. Missing fields degrade to
/// nil/empty, never a crash — the server omits nulls.
final class DeveloperServiceModelsTests: XCTestCase {

    func testTeamParsing() {
        let team = DeveloperTeam.from(json: [
            "team_id": "TEAM123", "name": "Mohammed",
            "type": "Individual", "status": "active",
        ])
        XCTAssertEqual(team.teamID, "TEAM123")
        XCTAssertEqual(team.name, "Mohammed")
        XCTAssertEqual(team.type, "Individual")
        XCTAssertEqual(team.status, "active")
        XCTAssertEqual(DeveloperTeam.from(json: [:]).teamID, "")
    }

    func testDeviceParsingKeepsUDID() {
        let device = DeveloperDevice.from(json: [
            "device_id": "DEV1",
            "device_number": "0000802000112233445566778899AABBCCDDEEFF",
            "name": "iPhone", "status": "active",
        ])
        XCTAssertEqual(device.deviceNumber, "0000802000112233445566778899AABBCCDDEEFF")
        XCTAssertEqual(device.name, "iPhone")
    }

    func testAppIDListParsingWithQuota() {
        let list = DeveloperAppIDList.from(json: [
            "app_ids": [[
                "app_id_id": "APP1", "identifier": "com.example.app",
                "name": "Example", "expiration_date": "2026-12-03T13:00:00Z",
            ]],
            "max_quantity": 10, "available_quantity": 9,
        ])
        XCTAssertEqual(list.appIDs.count, 1)
        XCTAssertEqual(list.appIDs[0].identifier, "com.example.app")
        XCTAssertEqual(list.maxQuantity, 10)
        XCTAssertEqual(list.availableQuantity, 9)
        let expected = ISO8601DateFormatter().date(from: "2026-12-03T13:00:00Z")
        XCTAssertEqual(list.appIDs[0].expirationDate, expected)
    }

    func testCertificateParsingKeepsSerialAndExpiry() {
        let cert = DevelopmentCertificate.from(json: [
            "certificate_id": "CERT1", "name": "iPhone Developer",
            "serial_number": "A1B2C3", "machine_id": "MACHINE1",
            "machine_name": "KsignNext", "status": "Issued",
            "status_code": 0, "expiration_date": "2027-11-26T00:00:00Z",
        ])
        XCTAssertEqual(cert.serialNumber, "A1B2C3")
        XCTAssertEqual(cert.machineName, "KsignNext")
        XCTAssertEqual(cert.statusCode, 0)
        XCTAssertNotNil(cert.expirationDate)
    }

    func testCreatedCertificateDecodesP12() throws {
        let created = try CreatedCertificate.from(json: [
            "reused": false, "machine_id": "M1", "machine_name": "KsignNext",
            "serial_number": "A1B2C3", "not_after": "2027-11-26T00:00:00Z",
            "p12_base64": Data([0x30, 0x82, 0x01, 0x00]).base64EncodedString(),
            "p12_password": "deadbeef",
        ])
        XCTAssertFalse(created.reused)
        XCTAssertEqual(created.p12Data, Data([0x30, 0x82, 0x01, 0x00]))
        XCTAssertEqual(created.p12Password, "deadbeef")
        XCTAssertNotNil(created.notAfter)
    }

    func testCreatedCertificateRejectsMissingP12() {
        XCTAssertThrowsError(try CreatedCertificate.from(json: [
            "reused": true, "serial_number": "A1B2C3",
        ]))
    }

    func testProfileParsingDecodesRawProfile() throws {
        let profile = try DeveloperProfile.from(json: [
            "provisioning_profile_id": "PROF1",
            "name": "iOS Team Provisioning Profile: com.example.app",
            "status": "Active", "type": "Development",
            "distribution_method": "adhoc",
            "uuid": "11111111-2222-3333-4444-555555555555",
            "date_expire": "2026-12-03T13:00:00Z",
            "app_id_id": "APP1", "filename": "profile.mobileprovision",
            "is_free_provisioning_profile": true,
            "encoded_profile_base64": Data([0x30, 0x82, 0x01, 0x00]).base64EncodedString(),
        ])
        XCTAssertEqual(profile.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(profile.encodedProfile, Data([0x30, 0x82, 0x01, 0x00]))
        XCTAssertEqual(profile.isFreeProvisioningProfile, true)
        XCTAssertNotNil(profile.dateExpire)
    }

    func testProfileParsingRejectsMissingBlob() {
        XCTAssertThrowsError(try DeveloperProfile.from(json: [
            "provisioning_profile_id": "PROF1",
        ]))
    }

    // MARK: - Error mapping for the new codes

    func testDeveloperErrorMapsWithAppleCode() {
        let error = AppleRefreshError.from(json: [
            "error": ["code": "developer_error", "message": "limit", "apple_ec": 7460],
        ], step: "create_certificate")
        guard case .developerError(let ec, _, _) = error else {
            return XCTFail("Expected developerError, got \(error)")
        }
        XCTAssertEqual(ec, 7460)
        XCTAssertTrue(error.localizedDescription.contains("7460"))
    }

    func testNotSignedInMaps() {
        let error = AppleRefreshError.from(json: [
            "error": ["code": "not_signed_in", "message": "Sign in first"],
        ], step: "list_teams")
        XCTAssertEqual(error, .notSignedIn)
    }
}
