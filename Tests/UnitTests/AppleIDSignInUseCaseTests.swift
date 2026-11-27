import XCTest
@testable import KsignNext

/// The sign-in retry + backoff policy, driven against a fake client.
/// No network, no Rust: the fake returns canned envelopes in the
/// order the use case asks for them.
final class FakeAppleRefreshClient: AppleRefreshClientProtocol, @unchecked Sendable {
    var claimsTried: [String] = []
    var loginQueue: [Result<AppleIDLoginResult, AppleRefreshError>] = []
    var tokenQueue: [Result<AppleRefreshAppToken, AppleRefreshError>] = []
    var createSessionCalls = 0
    var provisionCalls = 0
    var cancelCalls = 0
    var closeCalls = 0
    var promptToDeliver: TwoFactorPrompt?

    func createSession(config: AppleRefreshSessionConfig) async throws {
        createSessionCalls += 1
        claimsTried.append(config.signInClaim.presetName)
    }

    func provisionAnisette(forceReset: Bool) async throws {
        provisionCalls += 1
    }

    func login(email: String, password: String,
               twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse,
               timeout: TimeInterval) async throws -> AppleIDLoginResult {
        if let prompt = promptToDeliver {
            let response = await twoFactorHandler(prompt)
            XCTAssertEqual(response, .code("123456"))
        }
        guard !loginQueue.isEmpty else {
            throw AppleRefreshError.internalError(reason: "Fake ran out of login results.")
        }
        return try loginQueue.removeFirst().get()
    }

    func getAppToken(app: String, claim: AppleRefreshClaim?) async throws -> AppleRefreshAppToken {
        guard !tokenQueue.isEmpty else {
            throw AppleRefreshError.internalError(reason: "Fake ran out of token results.")
        }
        return try tokenQueue.removeFirst().get()
    }

    func sessionInfo() throws -> AppleRefreshSessionInfo {
        AppleRefreshSessionInfo(email: nil, firstName: nil, lastName: nil,
                                adsid: nil, loggedIn: false, server: nil, signInClaim: nil)
    }

    func resetAnisette() throws {}
    func cancel() throws { cancelCalls += 1 }
    func close() { closeCalls += 1 }

    // MARK: - Developer services (Phase 2)

    var devCalls: [String] = []
    var teamsResult: Result<[DeveloperTeam], AppleRefreshError> = .success([])
    var devicesResult: Result<[DeveloperDevice], AppleRefreshError> = .success([])
    var ensureDeviceResult: Result<DeveloperDevice, AppleRefreshError> =
        .failure(.internalError(reason: "Fake has no device."))
    var appIDsResult: Result<DeveloperAppIDList, AppleRefreshError> =
        .success(DeveloperAppIDList(appIDs: [], maxQuantity: 10, availableQuantity: 10))
    var addAppIDResult: Result<DeveloperAppID, AppleRefreshError> =
        .failure(.internalError(reason: "Fake has no App ID."))
    var certificatesResult: Result<[DevelopmentCertificate], AppleRefreshError> = .success([])
    var createCertificateResult: Result<CreatedCertificate, AppleRefreshError> =
        .failure(.internalError(reason: "Fake has no certificate."))
    var revokeCertificateError: AppleRefreshError?
    var profileResult: Result<DeveloperProfile, AppleRefreshError> =
        .failure(.internalError(reason: "Fake has no profile."))

    func listTeams() async throws -> [DeveloperTeam] {
        devCalls.append("listTeams")
        return try teamsResult.get()
    }

    func listDevices(teamID: String) async throws -> [DeveloperDevice] {
        devCalls.append("listDevices")
        return try devicesResult.get()
    }

    func ensureDevice(teamID: String, name: String, udid: String) async throws -> DeveloperDevice {
        devCalls.append("ensureDevice")
        return try ensureDeviceResult.get()
    }

    func listAppIDs(teamID: String) async throws -> DeveloperAppIDList {
        devCalls.append("listAppIDs")
        return try appIDsResult.get()
    }

    func addAppID(teamID: String, name: String, identifier: String) async throws -> DeveloperAppID {
        devCalls.append("addAppID")
        return try addAppIDResult.get()
    }

    func listCertificates(teamID: String) async throws -> [DevelopmentCertificate] {
        devCalls.append("listCertificates")
        return try certificatesResult.get()
    }

    func createCertificate(teamID: String, machineName: String, email: String) async throws -> CreatedCertificate {
        devCalls.append("createCertificate")
        return try createCertificateResult.get()
    }

    func revokeCertificate(teamID: String, serialNumber: String) async throws {
        devCalls.append("revokeCertificate")
        if let error = revokeCertificateError { throw error }
    }

    func downloadProfile(teamID: String, appID: String) async throws -> DeveloperProfile {
        devCalls.append("downloadProfile")
        return try profileResult.get()
    }
}

final class AppleIDSignInUseCaseTests: XCTestCase {

    private var suite: UserDefaults!
    private var store: AppleIDSessionStore!
    private var fake: FakeAppleRefreshClient!
    private var useCase: AppleIDSignInUseCase!

    private static let login = AppleIDLoginResult(
        email: "test@example.com", firstName: "Test", lastName: "User", adsid: "adsid-1")
    private static let token = AppleRefreshAppToken(
        app: "com.apple.gs.xcode.auth", hasToken: true, tokenLength: 42)

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AppleIDSignInUseCaseTests")!
        suite.removePersistentDomain(forName: "AppleIDSignInUseCaseTests")
        store = AppleIDSessionStore(
            keychain: KeychainService(service: "com.ksignnext.app.test-appleid-usecase"),
            defaults: suite)
        store.clearSession()
        let fakeClient = FakeAppleRefreshClient()
        fake = fakeClient
        useCase = AppleIDSignInUseCase(
            store: store,
            servers: AnisetteServerProvider(defaults: suite),
            clientFactory: { fakeClient })
    }

    func testSignInSuccessSavesSession() async throws {
        fake.loginQueue = [.success(Self.login)]
        fake.tokenQueue = [.success(Self.token)]
        let session = try await useCase.signIn(
            email: "test@example.com", password: "pw", twoFactorHandler: { _ in .abort })
        XCTAssertEqual(session.email, "test@example.com")
        XCTAssertEqual(session.claimPreset, "sideinstaller")
        XCTAssertTrue(session.appTokenProven)
        XCTAssertEqual(store.loadSession()?.email, "test@example.com")
        XCTAssertEqual(store.loadPassword(email: "test@example.com"), "pw")
        XCTAssertEqual(store.rejectionCount, 0)
        // The live client is retained for the Phase 2 developer
        // services (closing it here would kill the real refresh).
        XCTAssertNotNil(useCase.signedInClient)
        useCase.signOut()
        XCTAssertNil(useCase.signedInClient)
        XCTAssertNil(useCase.currentSession)
    }

    func testFallsBackToApparitionOn22410() async throws {
        fake.loginQueue = [
            .failure(.appleAuth(appleEC: -22410, appleEM: nil, message: "blocked")),
            .success(Self.login),
        ]
        fake.tokenQueue = [.success(Self.token)]
        let session = try await useCase.signIn(
            email: "test@example.com", password: "pw", twoFactorHandler: { _ in .abort })
        XCTAssertEqual(session.claimPreset, "apparition")
        XCTAssertEqual(fake.claimsTried, ["sideinstaller", "apparition"])
    }

    func testWrongPasswordStopsImmediately() async {
        fake.loginQueue = [.failure(.wrongPassword)]
        fake.tokenQueue = []
        do {
            _ = try await useCase.signIn(
                email: "test@example.com", password: "wrong", twoFactorHandler: { _ in .abort })
            XCTFail("Expected wrongPassword")
        } catch let error as AppleRefreshError {
            XCTAssertEqual(error, .wrongPassword)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(fake.createSessionCalls, 1, "A rejected password is never retried")
        XCTAssertEqual(store.rejectionCount, 1)
        XCTAssertNil(store.loadPassword(email: "test@example.com"))
    }

    func testSecondRejectionPauses() async {
        _ = store.recordRejection()
        fake.loginQueue = [.failure(.wrongPassword)]
        do {
            _ = try await useCase.signIn(
                email: "test@example.com", password: "wrong", twoFactorHandler: { _ in .abort })
            XCTFail("Expected wrongPassword")
        } catch let error as AppleRefreshError {
            XCTAssertEqual(error, .wrongPassword)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertNotNil(store.pauseUntil(), "Second consecutive rejection pauses sign-ins")
    }

    func testPausedSignInThrowsWithoutTrying() async {
        store.pause()
        fake.loginQueue = [.success(Self.login)]
        do {
            _ = try await useCase.signIn(
                email: "test@example.com", password: "pw", twoFactorHandler: { _ in .abort })
            XCTFail("Expected paused")
        } catch let error as AppleRefreshError {
            guard case .paused = error else {
                return XCTFail("Expected paused, got \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(fake.createSessionCalls, 0)
    }

    func testAppTokenRetriesOtherClaim() async throws {
        fake.loginQueue = [.success(Self.login)]
        fake.tokenQueue = [
            .failure(.appleAuth(appleEC: -80046, appleEM: nil, message: "wrong claim")),
            .success(Self.token),
        ]
        let session = try await useCase.signIn(
            email: "test@example.com", password: "pw", twoFactorHandler: { _ in .abort })
        XCTAssertTrue(session.appTokenProven)
    }

    func testTwoFactorHandlerIsInvoked() async throws {
        fake.promptToDeliver = TwoFactorPrompt(
            unknown: false, sms: false, lastError: nil, numbers: [], selectedNumberID: nil)
        fake.loginQueue = [.success(Self.login)]
        fake.tokenQueue = [.success(Self.token)]
        let session = try await useCase.signIn(
            email: "test@example.com", password: "pw") { _ in .code("123456") }
        XCTAssertEqual(session.email, "test@example.com")
    }

    func testAttemptProgressReportedPerClaim() async throws {
        // The first claim times out (the live stall: the password is
        // accepted but no 2FA prompt arrives), the second succeeds.
        // The UI must see both attempts — a silent spinner hides
        // exactly this.
        fake.loginQueue = [.failure(.timeout), .success(Self.login)]
        fake.tokenQueue = [.success(Self.token)]
        // The progress closure is @Sendable, so collect through a
        // box rather than a captured var.
        final class ProgressBox: @unchecked Sendable {
            var items: [SignInAttemptProgress] = []
        }
        let box = ProgressBox()
        let session = try await useCase.signIn(
            email: "test@example.com", password: "pw",
            twoFactorHandler: { _ in .abort },
            onAttempt: { box.items.append($0) })
        XCTAssertEqual(session.claimPreset, "apparition")
        let seen = box.items
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].attempt, 1)
        XCTAssertEqual(seen[1].attempt, 2)
        XCTAssertEqual(seen[0].totalAttempts, seen[1].totalAttempts)
        XCTAssertGreaterThanOrEqual(seen[0].totalAttempts, 2)
        XCTAssertEqual(seen[0].claimPreset, "sideinstaller")
        XCTAssertEqual(seen[1].claimPreset, "apparition")
        XCTAssertFalse(seen[0].serverHost.isEmpty)
    }
}
