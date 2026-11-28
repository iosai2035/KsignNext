import XCTest
@testable import KsignNext

/// ProvisioningEngine: CMS profile parse/import, validatePair,
/// `allows` / `deviceIsProvisioned`, kind heuristic. Fixtures are
/// plain XML plists (the engine scans for the first `<?xml` and the
/// last `</plist>`; no signature verification is attempted).
final class ProvisioningEngineTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: FileSystemManager!
    private var engine: ProvisioningEngine!

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        fileManager = FileSystemManager(workspaceRoot: tempDir)
        try? fileManager.ensureWorkspaceExists()
        engine = ProvisioningEngine(fileManager: fileManager)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL { FixtureBuilder.fixtureURL(named: name) }

    private func certificate(fingerprint: String? = nil) -> CertificateModel {
        FixtureBuilder.makeCertificateModel(
            fingerprint: fingerprint ?? FixtureBuilder.sha256Hex(
                try! FixtureBuilder.fixtureData(named: "valid.cer.der")))
    }

    private func writeProfile(_ data: Data, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testParse_validProfileReturnsAllFields() async throws {
        let model = try await engine.parseProvisioningProfile(at: fixture("development.mobileprovision"))
        XCTAssertEqual(model.name, "Test Development")
        XCTAssertEqual(model.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(model.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(model.appIdentifier, "ABCDE12345.com.example.test")
        XCTAssertEqual(model.bundleIdentifier, "com.example.test")
        XCTAssertEqual(model.kind, .development)
        XCTAssertFalse(model.isExpired)
        XCTAssertEqual(model.provisionedDevices, [String(repeating: "A", count: 40)])
        XCTAssertEqual(model.entitlements["application-identifier"], "ABCDE12345.com.example.test")
        XCTAssertEqual(model.certificates.count, 1)
        XCTAssertEqual(model.dataHash, FixtureBuilder.sha256Hex(
            try FixtureBuilder.fixtureData(named: "development.mobileprovision")))
    }

    func testParse_corruptCMSThrowsProvisioningInvalid() async {
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.parseProvisioningProfile(at: self.fixture("corrupt.mobileprovision")) }
        ) { error in
            guard case AppError.certificate(.provisioningInvalid) = error else {
                return XCTFail("Expected AppError.certificate(.provisioningInvalid), got \(error)")
            }
        }
    }

    func testParse_missingMandatoryFieldsThrows() async throws {
        let cases: [(String, Data)] = [
            ("no-name", FixtureBuilder.syntheticProfileData(name: nil)),
            ("no-uuid", FixtureBuilder.syntheticProfileData(uuid: nil)),
            ("no-team", FixtureBuilder.syntheticProfileData(teamIdentifier: nil)),
            ("no-app-id", FixtureBuilder.syntheticProfileData(appIdentifier: nil)),
        ]
        for (label, data) in cases {
            let url = try writeProfile(data, named: "\(label).mobileprovision")
            await XCTAssertThrowsErrorAsync(
                { try await self.engine.parseProvisioningProfile(at: url) }
            ) { error in
                guard case AppError.certificate(.provisioningInvalid) = error else {
                    return XCTFail("[\(label)] Expected .provisioningInvalid, got \(error)")
                }
            }
        }
    }

    func testParse_expiredProfileSucceeds() async throws {
        // Parse does NOT reject expiry — only import does.
        let model = try await engine.parseProvisioningProfile(at: fixture("expired.mobileprovision"))
        XCTAssertEqual(model.name, "Test Expired")
        XCTAssertTrue(model.isExpired)
    }

    func testImport_expiredProfileThrowsProvisioningExpired() async throws {
        let certificates = try fileManager.folder(.certificates)
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.importProvisioningProfile(at: self.fixture("expired.mobileprovision")) }
        ) { error in
            guard case AppError.certificate(.provisioningExpired) = error else {
                return XCTFail("Expected AppError.certificate(.provisioningExpired), got \(error)")
            }
        }
        // No file was copied.
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: certificates, includingPropertiesForKeys: nil).isEmpty)
    }

    func testValidatePair_teamMismatchThrowsProvisioningMismatch() async throws {
        let cert = FixtureBuilder.makeCertificateModel(teamIdentifier: "TEAMXXXXXX")
        let profile = try await engine.parseProvisioningProfile(at: fixture("development.mobileprovision"))
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.validatePair(certificate: cert, profile: profile) }
        ) { error in
            guard case AppError.certificate(.provisioningMismatch) = error else {
                return XCTFail("Expected .provisioningMismatch, got \(error)")
            }
        }
    }

    func testValidatePair_certNotListedThrowsProvisioningMismatch() async throws {
        let cert = certificate(fingerprint: String(repeating: "0", count: 64))
        let profile = try await engine.parseProvisioningProfile(at: fixture("development.mobileprovision"))
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.validatePair(certificate: cert, profile: profile) }
        ) { error in
            guard case AppError.certificate(.provisioningMismatch) = error else {
                return XCTFail("Expected .provisioningMismatch, got \(error)")
            }
        }
    }

    func testAllows_exactMatch() {
        let profile = FixtureBuilder.makeProvisioningModel(
            appIdentifier: "ABCDE12345.com.example.test",
            bundleIdentifierPrefixes: ["com.example.test"])
        XCTAssertTrue(engine.allows(bundleID: "com.example.test", profile: profile))
        XCTAssertTrue(profile.allows(bundleID: "com.example.test"))
        XCTAssertFalse(engine.allows(bundleID: "com.example.other", profile: profile))
    }

    func testAllows_wildcardMatch() {
        let profile = FixtureBuilder.makeProvisioningModel(
            appIdentifier: "ABCDE12345.com.example.*",
            bundleIdentifierPrefixes: ["com.example.*"])
        XCTAssertTrue(engine.allows(bundleID: "com.example.foo", profile: profile))
        XCTAssertTrue(profile.allows(bundleID: "com.example.foo"))
    }

    func testAllows_wildcardDoesNotMatchPrefixSibling() {
        let profile = FixtureBuilder.makeProvisioningModel(
            appIdentifier: "ABCDE12345.com.example.*",
            bundleIdentifierPrefixes: ["com.example.*"])
        XCTAssertFalse(engine.allows(bundleID: "com.exampleFoo", profile: profile))
        XCTAssertFalse(engine.allows(bundleID: "com.example", profile: profile))
        XCTAssertFalse(profile.allows(bundleID: "com.exampleFoo"))
        XCTAssertFalse(profile.allows(bundleID: "com.example"))
    }

    func testAllows_universalWildcard() {
        let profile = FixtureBuilder.makeProvisioningModel(
            appIdentifier: "ABCDE12345.*",
            bundleIdentifierPrefixes: ["*"])
        XCTAssertTrue(engine.allows(bundleID: "com.anything.at.all", profile: profile))
        XCTAssertTrue(profile.allows(bundleID: "com.anything.at.all"))
    }

    func testDeviceIsProvisioned_listedAndUnlisted() {
        let udid = String(repeating: "A", count: 40)
        let profile = FixtureBuilder.makeProvisioningModel(provisionedDevices: [udid])
        XCTAssertTrue(engine.deviceIsProvisioned(udid, in: profile))
        XCTAssertFalse(engine.deviceIsProvisioned(String(repeating: "B", count: 40), in: profile))
        // An App Store profile has no device list: it covers NO pasted
        // UDID by list (exact `contains` only).
        let appStore = FixtureBuilder.makeProvisioningModel(
            kind: .appStore, provisionedDevices: [])
        XCTAssertFalse(engine.deviceIsProvisioned(udid, in: appStore))
    }

    func testKindHeuristic_matrix() async throws {
        let enterprise = try await engine.parseProvisioningProfile(at: fixture("enterprise.mobileprovision"))
        XCTAssertEqual(enterprise.kind, .enterprise)
        let appStore = try await engine.parseProvisioningProfile(at: fixture("appstore.mobileprovision"))
        XCTAssertEqual(appStore.kind, .appStore)
        let development = try await engine.parseProvisioningProfile(at: fixture("development.mobileprovision"))
        XCTAssertEqual(development.kind, .development)
        let adhocData = FixtureBuilder.syntheticProfileData(
            getTaskAllow: false,
            provisionedDevices: [String(repeating: "A", count: 40)])
        let adhocURL = try writeProfile(adhocData, named: "adhoc.mobileprovision")
        let adhoc = try await engine.parseProvisioningProfile(at: adhocURL)
        XCTAssertEqual(adhoc.kind, .adhoc)
    }

    func testImport_oversizedThrowsProvisioningInvalid() async throws {
        let oversized = tempDir.appendingPathComponent("huge.mobileprovision")
        try FixtureBuilder.oversizedData(bytes: 5 * 1024 * 1024 + 1).write(to: oversized)
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.importProvisioningProfile(at: oversized) }
        ) { error in
            guard case AppError.certificate(.provisioningInvalid) = error else {
                return XCTFail("Expected AppError.certificate(.provisioningInvalid), got \(error)")
            }
        }
    }

    func testParse_plistStringContainingPlistEndTag() async throws {
        // A string value containing the literal `</plist>` must not
        // truncate the document: keys after it (UUID, Version) must
        // still parse. This pins the last-`</plist>` hardening (§B.9).
        let model = try await engine.parseProvisioningProfile(at: fixture("plist-end-tag.mobileprovision"))
        XCTAssertEqual(model.name, "Test End Tag")
        XCTAssertEqual(model.uuid, "55555555-6666-7777-8888-999999999999")
        XCTAssertEqual(model.teamIdentifier, "ABCDE12345")
        XCTAssertFalse(model.isExpired)
    }
}
