import XCTest
@testable import KsignNext

/// DashboardViewModel: expiry comes from the engine via
/// FetchExpiringProfilesUseCase (W-2), activity from AppLogger, the
/// single log source (W-4). Errors are surfaced, never swallowed.
@MainActor
final class DashboardViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var logger: AppLogger!

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        logger = AppLogger(fileURL: tempDir.appendingPathComponent("logs.jsonl"))
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    @MainActor
    private func makeViewModel(
        profileRepository: ProvisioningProfileRepository,
        certificateRepository: CertificateRepository = FakeCertificateRepository(),
        engine: ProvisioningEngineProtocol = FakeProvisioningEngine()
    ) -> DashboardViewModel {
        let useCase = FetchExpiringProfilesUseCase(repository: profileRepository, engine: engine)
        return DashboardViewModel(
            expiringProfilesUseCase: useCase,
            logger: logger,
            certificateRepository: certificateRepository,
            profileRepository: profileRepository)
    }

    @MainActor
    func testExpiringProfiles_sortedNearestFirstViaEngine() async throws {
        let repository = FakeProvisioningProfileRepository()
        let expired = FixtureBuilder.makeProvisioningModel(
            name: "Expired", expirationDate: Date().addingTimeInterval(-86_400))
        let soon = FixtureBuilder.makeProvisioningModel(
            name: "Soon", uuid: "22222222-3333-4444-5555-666666666666",
            expirationDate: Date().addingTimeInterval(2 * 86_400))
        let later = FixtureBuilder.makeProvisioningModel(
            name: "Later", uuid: "33333333-4444-5555-6666-777777777777",
            expirationDate: Date().addingTimeInterval(5 * 86_400))
        try await repository.save(later)
        try await repository.save(expired)
        try await repository.save(soon)
        let viewModel = makeViewModel(profileRepository: repository)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.expiringProfiles.map(\.name), ["Expired", "Soon", "Later"])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testActivity_readsFromAppLoggerSingleSource() async {
        await logger.info("import finished")
        await logger.warning("profile expires soon")
        let viewModel = makeViewModel(profileRepository: FakeProvisioningProfileRepository())
        await viewModel.refresh()
        XCTAssertTrue(viewModel.recentActivity.contains { $0.message == "import finished" })
        XCTAssertTrue(viewModel.recentActivity.contains { $0.message == "profile expires soon" })
        // The activity list is exactly the logger's entries (W-4:
        // one source, no second log file read).
        XCTAssertEqual(viewModel.recentActivity.count, await logger.allEntries().count)
    }

    @MainActor
    func testRefresh_surfacesReadError() async {
        let repository = FakeProvisioningProfileRepository()
        repository.errorToThrow = AppError.storage(.loadFailed(reason: "test injected failure"))
        let viewModel = makeViewModel(profileRepository: repository)
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage?.contains("test injected failure") ?? false)
    }

    @MainActor
    func testEmptyState_reportsZeroCounts() async {
        let viewModel = makeViewModel(profileRepository: FakeProvisioningProfileRepository())
        await viewModel.refresh()
        XCTAssertEqual(viewModel.certificateCount, 0)
        XCTAssertEqual(viewModel.profileCount, 0)
        XCTAssertTrue(viewModel.expiringProfiles.isEmpty)
        XCTAssertTrue(viewModel.recentActivity.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
}
