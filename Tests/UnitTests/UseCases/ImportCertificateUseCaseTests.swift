import XCTest
@testable import KsignNext

/// ImportCertificateUseCase: parse → copy → Keychain → save record,
/// with rollback in reverse on failure. No orphan file, Keychain
/// item, or record may remain after a failure.
final class ImportCertificateUseCaseTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: FileSystemManager!
    private var certificatesFolder: URL!
    private var keychain: KeychainService!
    private var repository: FakeCertificateRepository!
    private var logger: AppLogger!
    private var keychainAccounts: [String] = []

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        fileManager = FileSystemManager(workspaceRoot: tempDir)
        try? fileManager.ensureWorkspaceExists()
        certificatesFolder = try? fileManager.folder(.certificates)
        keychain = KeychainTestService.make()
        repository = FakeCertificateRepository()
        logger = AppLogger(fileURL: tempDir.appendingPathComponent("logs.jsonl"))
        keychainAccounts = []
    }

    override func tearDown() {
        for account in keychainAccounts { try? keychain.delete(account: account) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func certificatesContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: certificatesFolder, includingPropertiesForKeys: nil)
    }

    func testExecute_successCopiesFileWritesKeychainSavesRecord() async throws {
        let engine = FakeCertificateEngine()
        engine.copyDestinationFolder = certificatesFolder
        engine.realKeychain = keychain
        let model = FixtureBuilder.makeCertificateModel()
        engine.importModel = model
        keychainAccounts.append(FakeCertificateEngine.passwordAccount(for: model.id))
        let useCase = ImportCertificateUseCase(engine: engine, repository: repository, keychain: keychain, fileSystem: fileManager, logger: logger)
        let source = FixtureBuilder.fixtureURL(named: "valid.p12")
        let result = try await useCase.execute(fileURL: source, password: "test123")
        XCTAssertEqual(result.id, model.id)
        XCTAssertEqual(try certificatesContents().count, 1)
        XCTAssertEqual(try keychain.readPassword(account: result.keychainAccount ?? ""), "test123")
        XCTAssertNotNil(try await repository.fetch(id: model.id))
    }

    func testExecute_wrongPasswordWritesNothing() async throws {
        let engine = CertificateEngine(keychain: keychain, fileManager: fileManager)
        let useCase = ImportCertificateUseCase(engine: engine, repository: repository, keychain: keychain, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"), password: "wrong-password") }
        ) { error in
            XCTAssertEqual(error as? AppError, AppError.certificate(.wrongPassword))
        }
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_keychainFailureRemovesCopiedFileAndRecord() async throws {
        let engine = FakeCertificateEngine()
        engine.copyDestinationFolder = certificatesFolder
        engine.importError = AppError.certificate(.keychainFailure(reason: "test injected failure"))
        let useCase = ImportCertificateUseCase(engine: engine, repository: repository, keychain: keychain, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"), password: "test123") }
        ) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.certificate(.keychainFailure(reason: "test injected failure")))
        }
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_repositoryFailureRemovesKeychainAndFile() async throws {
        let engine = FakeCertificateEngine()
        engine.copyDestinationFolder = certificatesFolder
        engine.realKeychain = keychain
        let model = FixtureBuilder.makeCertificateModel()
        engine.importModel = model
        let account = FakeCertificateEngine.passwordAccount(for: model.id)
        keychainAccounts.append(account)
        repository.errorToThrow = AppError.storage(.saveFailed(reason: "test injected failure"))
        let useCase = ImportCertificateUseCase(engine: engine, repository: repository, keychain: keychain, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"), password: "test123") }
        ) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.storage(.saveFailed(reason: "test injected failure")))
        }
        // Rollback in reverse: no orphan file, no orphan Keychain
        // item, no orphan record.
        repository.errorToThrow = nil
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertNil(try keychain.readPassword(account: account))
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_passwordlessRegisters() async throws {
        // W-3: an empty password still registers — the empty password
        // is stored and the record is saved unconditionally.
        let engine = CertificateEngine(keychain: keychain, fileManager: fileManager)
        let useCase = ImportCertificateUseCase(engine: engine, repository: repository, keychain: keychain, fileSystem: fileManager, logger: logger)
        let result = try await useCase.execute(
            fileURL: FixtureBuilder.fixtureURL(named: "passwordless.p12"), password: "")
        XCTAssertNotNil(result.keychainAccount)
        XCTAssertTrue(result.isStoredInKeychain)
        keychainAccounts.append(result.keychainAccount ?? "")
        XCTAssertEqual(try keychain.readPassword(account: result.keychainAccount ?? ""), "")
        XCTAssertNotNil(try await repository.fetch(id: result.id))
        XCTAssertEqual(try certificatesContents().count, 1)
    }
}
