import XCTest
@testable import KsignNext

/// ImportProvisioningProfileUseCase: parse → validate (expired
/// rejected before any copy) → copy → save record, with rollback.
/// No orphan file or record may remain after a failure.
final class ImportProvisioningProfileUseCaseTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: FileSystemManager!
    private var certificatesFolder: URL!
    private var repository: FakeProvisioningProfileRepository!
    private var logger: AppLogger!

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        fileManager = FileSystemManager(workspaceRoot: tempDir)
        try? fileManager.ensureWorkspaceExists()
        certificatesFolder = try? fileManager.folder(.certificates)
        repository = FakeProvisioningProfileRepository()
        logger = AppLogger(fileURL: tempDir.appendingPathComponent("logs.jsonl"))
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func certificatesContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: certificatesFolder, includingPropertiesForKeys: nil)
    }

    func testExecute_successCopiesFileAndSavesRecord() async throws {
        let engine = ProvisioningEngine(fileManager: fileManager)
        let useCase = ImportProvisioningProfileUseCase(engine: engine, repository: repository, fileSystem: fileManager, logger: logger)
        let result = try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "development.mobileprovision"))
        XCTAssertEqual(result.name, "Test Development")
        XCTAssertEqual(try certificatesContents().count, 1)
        XCTAssertNotNil(try await repository.fetch(id: result.id))
        XCTAssertNotNil(try await repository.fetch(uuid: "11111111-2222-3333-4444-555555555555"))
    }

    func testExecute_expiredRejectsBeforeAnyCopy() async throws {
        let engine = ProvisioningEngine(fileManager: fileManager)
        let useCase = ImportProvisioningProfileUseCase(engine: engine, repository: repository, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "expired.mobileprovision")) }
        ) { error in
            guard case AppError.certificate(.provisioningExpired) = error else {
                return XCTFail("Expected AppError.certificate(.provisioningExpired), got \(error)")
            }
        }
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_corruptWritesNothing() async throws {
        let engine = ProvisioningEngine(fileManager: fileManager)
        let useCase = ImportProvisioningProfileUseCase(engine: engine, repository: repository, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "corrupt.mobileprovision")) }
        ) { error in
            guard case AppError.certificate(.provisioningInvalid) = error else {
                return XCTFail("Expected AppError.certificate(.provisioningInvalid), got \(error)")
            }
        }
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_repositoryFailureRemovesFile() async throws {
        let engine = ProvisioningEngine(fileManager: fileManager)
        repository.errorToThrow = AppError.storage(.saveFailed(reason: "test injected failure"))
        let useCase = ImportProvisioningProfileUseCase(engine: engine, repository: repository, fileSystem: fileManager, logger: logger)
        await XCTAssertThrowsErrorAsync(
            { try await useCase.execute(fileURL: FixtureBuilder.fixtureURL(named: "development.mobileprovision")) }
        ) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.storage(.saveFailed(reason: "test injected failure")))
        }
        repository.errorToThrow = nil
        XCTAssertTrue(try certificatesContents().isEmpty)
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testExecute_reimportSameUUIDUpserts() async throws {
        let engine = ProvisioningEngine(fileManager: fileManager)
        let useCase = ImportProvisioningProfileUseCase(engine: engine, repository: repository, fileSystem: fileManager, logger: logger)
        let source = FixtureBuilder.fixtureURL(named: "development.mobileprovision")
        let first = try await useCase.execute(fileURL: source)
        let second = try await useCase.execute(fileURL: source)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try await repository.fetchAll().count, 1)
        XCTAssertNotNil(try await repository.fetch(uuid: "11111111-2222-3333-4444-555555555555"))
    }
}
