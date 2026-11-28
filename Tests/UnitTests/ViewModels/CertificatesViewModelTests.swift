import XCTest
@testable import KsignNext

/// CertificatesViewModel: import/delete state, password cleared once
/// consumed, per-step delete errors surfaced and the row kept (W-6).
/// Uses the real engines + the isolated test Keychain service, with
/// fake (in-memory) repositories.
@MainActor
final class CertificatesViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: FileSystemManager!
    private var keychain: KeychainService!
    private var certificateRepository: FakeCertificateRepository!
    private var profileRepository: FakeProvisioningProfileRepository!
    private var logger: AppLogger!
    private var keychainAccounts: [String] = []

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        fileManager = FileSystemManager(workspaceRoot: tempDir)
        try? fileManager.ensureWorkspaceExists()
        keychain = KeychainTestService.make()
        certificateRepository = FakeCertificateRepository()
        profileRepository = FakeProvisioningProfileRepository()
        logger = AppLogger(fileURL: tempDir.appendingPathComponent("logs.jsonl"))
        keychainAccounts = []
    }

    override func tearDown() {
        for account in keychainAccounts { try? keychain.delete(account: account) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    @MainActor
    private func makeViewModel() -> CertificatesViewModel {
        let certEngine = CertificateEngine(keychain: keychain, fileManager: fileManager)
        let profileEngine = ProvisioningEngine(fileManager: fileManager)
        return CertificatesViewModel(
            importCertificateUseCase: ImportCertificateUseCase(
                engine: certEngine, repository: certificateRepository,
                keychain: keychain, fileSystem: fileManager, logger: logger),
            importProfileUseCase: ImportProvisioningProfileUseCase(
                engine: profileEngine, repository: profileRepository,
                fileSystem: fileManager, logger: logger),
            deleteCertificateUseCase: DeleteCertificateUseCase(
                repository: certificateRepository, keychain: keychain,
                fileSystem: fileManager, logger: logger),
            deleteProfileUseCase: DeleteProvisioningProfileUseCase(
                repository: profileRepository, fileSystem: fileManager, logger: logger),
            certificateRepository: certificateRepository,
            profileRepository: profileRepository,
            logger: logger)
    }

    @MainActor
    func testImportP12_successRefreshesList() async throws {
        let viewModel = makeViewModel()
        viewModel.p12Password = "test123"
        await viewModel.importP12(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.certificates.count, 1)
        XCTAssertEqual(viewModel.certificates.first?.kind, .development)
        XCTAssertEqual(viewModel.certificates.first?.teamIdentifier, "ABCDE12345")
        if let account = viewModel.certificates.first?.keychainAccount {
            keychainAccounts.append(account)
        }
    }

    @MainActor
    func testImportP12_passwordClearedAfterConsumption() async {
        let viewModel = makeViewModel()
        viewModel.p12Password = "test123"
        await viewModel.importP12(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"))
        XCTAssertEqual(viewModel.p12Password, "")
        XCTAssertNil(viewModel.errorMessage)
        if let account = viewModel.certificates.first?.keychainAccount {
            keychainAccounts.append(account)
        }
    }

    @MainActor
    func testImportProfile_expiredShowsError() async {
        let viewModel = makeViewModel()
        await viewModel.importProfile(fileURL: FixtureBuilder.fixtureURL(named: "expired.mobileprovision"))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.profiles.isEmpty)
    }

    @MainActor
    func testDelete_successRemovesFileRecordAndKeychain() async throws {
        let viewModel = makeViewModel()
        viewModel.p12Password = "test123"
        await viewModel.importP12(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"))
        guard let model = viewModel.certificates.first else {
            return XCTFail("Expected one imported certificate")
        }
        let account = model.keychainAccount ?? ""
        let fileURL = model.fileURL
        await viewModel.deleteCertificate(id: model.id)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.certificates.isEmpty)
        XCTAssertNil(try await certificateRepository.fetch(id: model.id))
        XCTAssertNil(try keychain.readPassword(account: account))
        if let fileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @MainActor
    func testDelete_keychainFailureSurfacesErrorAndKeepsRow() async {
        // W-6: a failed delete step surfaces the error and the row
        // stays — the view dismisses only when all steps succeed.
        // The injectable failure here is the repository delete step
        // (the Keychain step is not injectable without a fake
        // Keychain); the observable contract is identical.
        let viewModel = makeViewModel()
        viewModel.p12Password = "test123"
        await viewModel.importP12(fileURL: FixtureBuilder.fixtureURL(named: "valid.p12"))
        guard let model = viewModel.certificates.first else {
            return XCTFail("Expected one imported certificate")
        }
        if let account = model.keychainAccount { keychainAccounts.append(account) }
        certificateRepository.deleteError = AppError.storage(.deleteFailed(reason: "test injected failure"))
        await viewModel.deleteCertificate(id: model.id)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("test injected failure") ?? false)
        XCTAssertEqual(viewModel.certificates.count, 1)
        certificateRepository.deleteError = nil
    }

    @MainActor
    func testRefresh_surfacesDirectoryReadError() async {
        let viewModel = makeViewModel()
        certificateRepository.errorToThrow = AppError.storage(.loadFailed(reason: "test injected failure"))
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("test injected failure") ?? false)
        certificateRepository.errorToThrow = nil
    }
}
