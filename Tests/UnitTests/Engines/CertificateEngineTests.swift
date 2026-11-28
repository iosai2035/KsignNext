import XCTest
@testable import KsignNext

/// CertificateEngine: P12 parse/import, DER walk (R-M1), status().
/// Fixtures: `Tests/Fixtures/` (openssl self-signed test identity,
/// throwaway password `test123`; see `Fixtures/README.md`).
final class CertificateEngineTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: FileSystemManager!
    private var keychain: KeychainService!
    private var engine: CertificateEngine!
    private var keychainAccounts: [String] = []

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        fileManager = FileSystemManager(workspaceRoot: tempDir)
        try? fileManager.ensureWorkspaceExists()
        keychain = KeychainTestService.make()
        engine = CertificateEngine(keychain: keychain, fileManager: fileManager)
        keychainAccounts = []
    }

    override func tearDown() {
        for account in keychainAccounts { try? keychain.delete(account: account) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL { FixtureBuilder.fixtureURL(named: name) }

    func testParseP12_validReturnsModelWithFingerprintAndTeam() async throws {
        let model = try await engine.parseP12(at: fixture("valid.p12"), password: "test123")
        let der = try FixtureBuilder.fixtureData(named: "valid.cer.der")
        XCTAssertEqual(model.fingerprint, FixtureBuilder.sha256Hex(der))
        XCTAssertEqual(model.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(model.kind, .development)
        XCTAssertTrue(model.commonName?.contains("Apple Development") ?? false)
        XCTAssertFalse(model.isExpired)
    }

    func testParseP12_wrongPasswordThrowsWrongPassword() async {
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.parseP12(at: self.fixture("valid.p12"), password: "wrong-password") }
        ) { error in
            XCTAssertEqual(error as? AppError, AppError.certificate(.wrongPassword))
        }
    }

    func testParseP12_corruptThrowsInvalidFormat() async {
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.parseP12(at: self.fixture("corrupt.p12"), password: "test123") }
        ) { error in
            guard case AppError.certificate(.invalidFormat) = error else {
                return XCTFail("Expected AppError.certificate(.invalidFormat), got \(error)")
            }
        }
    }

    func testParseP12_passwordlessSucceedsAndRegisters() async throws {
        let model = try await engine.importP12(at: fixture("passwordless.p12"), password: "")
        XCTAssertNotNil(model.keychainAccount)
        XCTAssertTrue(model.isStoredInKeychain)
        XCTAssertEqual(model.keychainAccount, CertificateEngine.passwordAccount(for: model.id))
        keychainAccounts.append(model.keychainAccount ?? "")
        // The empty password is stored, and the record registers.
        XCTAssertEqual(try keychain.readPassword(account: model.keychainAccount ?? ""), "")
        let repository = FakeCertificateRepository()
        try await repository.save(model)
        XCTAssertNotNil(try await repository.fetch(id: model.id))
    }

    func testParseP12_missingPrivateKeyThrows() async {
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.parseP12(at: self.fixture("noprivatekey.p12"), password: "test123") }
        ) { error in
            XCTAssertEqual(error as? AppError, AppError.certificate(.missingPrivateKey))
        }
    }

    func testParseP12_oversizedThrowsInvalidFormat() async throws {
        let oversized = tempDir.appendingPathComponent("huge.p12")
        try FixtureBuilder.oversizedData(bytes: 10 * 1024 * 1024 + 1).write(to: oversized)
        await XCTAssertThrowsErrorAsync(
            { try await self.engine.parseP12(at: oversized, password: "test123") }
        ) { error in
            guard case AppError.certificate(.invalidFormat) = error else {
                return XCTFail("Expected AppError.certificate(.invalidFormat), got \(error)")
            }
        }
    }

    func testParseCertificate_pemParses() async throws {
        let model = try await engine.parseCertificate(at: fixture("distribution.cer.pem"))
        XCTAssertEqual(model.kind, .distribution)
        XCTAssertEqual(model.teamIdentifier, "ABCDE12345")
        let der = try FixtureBuilder.fixtureData(named: "distribution.cer.der")
        XCTAssertEqual(model.fingerprint, FixtureBuilder.sha256Hex(der))
    }

    func testDerOID_largeArcDoesNotTrap() async throws {
        // Synthetic DER cert whose subject holds an OID arc of
        // 2^70 - 1 (R-M1). The parse must survive: the oversized arc
        // yields nil for that attribute, never a trap.
        let derURL = tempDir.appendingPathComponent("large-arc.cer")
        try FixtureBuilder.derCertificateWithLargeArcOID().write(to: derURL)
        do {
            let model = try await engine.parseCertificate(at: derURL)
            XCTAssertEqual(model.commonName, "Apple Development: Test User")
            XCTAssertEqual(model.teamIdentifier, "ABCDE12345")
        } catch {
            // A strict parser may reject the synthetic cert outright;
            // that is acceptable only as a typed invalid-format error.
            guard case AppError.certificate(.invalidFormat) = error else {
                return XCTFail("Expected .invalidFormat (or a parsed model), got \(error)")
            }
        }
    }

    func testStatus_valid() async {
        let model = FixtureBuilder.makeCertificateModel(
            notBefore: Date().addingTimeInterval(-86_400),
            expirationDate: Date().addingTimeInterval(365 * 86_400))
        XCTAssertEqual(await engine.status(of: model), .valid)
    }

    func testStatus_expired() async {
        let model = FixtureBuilder.makeCertificateModel(
            notBefore: Date().addingTimeInterval(-2 * 365 * 86_400),
            expirationDate: Date().addingTimeInterval(-86_400))
        XCTAssertEqual(await engine.status(of: model), .expired)
    }

    func testStatus_notYetValidReturnsInvalid() async {
        // Future notBefore -> .invalid, NOT .notYetValid (verified
        // status() contract; the .notYetValid error case is not used
        // by status()).
        let model = FixtureBuilder.makeCertificateModel(
            notBefore: Date().addingTimeInterval(86_400),
            expirationDate: Date().addingTimeInterval(365 * 86_400))
        XCTAssertEqual(await engine.status(of: model), .invalid)
    }

    func testStatus_neverReturnsRevoked() async {
        let models = [
            FixtureBuilder.makeCertificateModel(),
            FixtureBuilder.makeCertificateModel(expirationDate: Date().addingTimeInterval(-1)),
            FixtureBuilder.makeCertificateModel(notBefore: Date().addingTimeInterval(86_400)),
            FixtureBuilder.makeCertificateModel(expirationDate: nil, notBefore: nil),
            FixtureBuilder.makeCertificateModel(fingerprint: ""),
        ]
        for model in models {
            XCTAssertNotEqual(await engine.status(of: model), .revoked)
        }
    }
}
