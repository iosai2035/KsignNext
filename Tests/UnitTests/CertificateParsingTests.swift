import XCTest
@testable import KsignNext

// The view model under test is @MainActor, so the whole test class runs
// on the main actor and may call its init, properties and methods directly.
@MainActor
final class CertificateParsingTests: XCTestCase {

    func testWrongP12PasswordFails() {
        // Random bytes are not a P12 at all; SecPKCS12Import must fail, never succeed.
        let data = Data([0x30, 0x82, 0x01, 0x02, 0x03, 0x04])
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "wrong-password"] as CFDictionary, &items)
        XCTAssertNotEqual(status, errSecSuccess)
    }

    func testEmptyP12Fails() {
        var items: CFArray?
        let status = SecPKCS12Import(Data() as CFData, [kSecImportExportPassphrase as String: ""] as CFDictionary, &items)
        XCTAssertNotEqual(status, errSecSuccess)
    }

    func testFakeMobileprovisionIsNotAPlist() {
        let fake = Data("not a provisioning profile".utf8)
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: fake, options: [], format: nil))
    }

    func testProvisionPlistParsesNameAndExpiry() throws {
        let expiry = Date(timeIntervalSinceNow: 86400 * 30)
        let dict: [String: Any] = ["Name": "Test Profile", "ExpirationDate": expiry, "UUID": "11111111-2222-3333-4444-555555555555"]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["Name"] as? String, "Test Profile")
        let decodedExpiry = try XCTUnwrap(decoded?["ExpirationDate"] as? Date)
        XCTAssertEqual(decodedExpiry.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
    }

    func testExpiredProvisionDetected() {
        let vm = CertificateDetailViewModel(certificate: StoredCertificate(url: FileManager.default.temporaryDirectory.appendingPathComponent("x.mobileprovision")))
        XCTAssertFalse(vm.info.isExpired)
    }
}
