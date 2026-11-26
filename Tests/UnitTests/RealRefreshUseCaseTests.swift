import XCTest
@testable import KsignNext

/// The real refresh's gates (Phase 2 + 3): the use case must refuse
/// before touching Apple when the UDID is missing, when there is no
/// sign-in, when the account has no team, when the certificate
/// limit is hit, and when no App ID slot is left — and it must call
/// the developer services in the right order. The happy path (full
/// re-sign + install) is covered by the signing engine tests, the
/// loopback install test, and the live proof on device.
final class RealRefreshUseCaseTests: XCTestCase {

    // MARK: - Doubles

    final class StubSignedRepository: SignedApplicationRepository {
        var results: [SigningResult] = []
        func fetchAll() async throws -> [SigningResult] { results }
        func fetch(id: UUID) async throws -> SigningResult? { results.first { $0.id == id } }
        func save(_ result: SigningResult) async throws { results.append(result) }
        func delete(id: UUID) async throws { results.removeAll { $0.id == id } }
    }

    final class StubCertificateRepository: CertificateRepository {
        var certificates: [CertificateModel] = []
        func fetchAll() async throws -> [CertificateModel] { certificates }
        func fetch(id: UUID) async throws -> CertificateModel? { certificates.first { $0.id == id } }
        func fetch(fingerprint: String) async throws -> CertificateModel? { certificates.first { $0.fingerprint == fingerprint } }
        func save(_ certificate: CertificateModel) async throws { certificates.append(certificate) }
        func delete(id: UUID) async throws { certificates.removeAll { $0.id == id } }
    }

    /// Records the import calls; never touches the disk or Keychain.
    final class FakeCertificateEngine: CertificateEngineProtocol {
        var importedP12: [(url: URL, password: String)] = []
        var importedProfiles: [URL] = []
        var certificateToReturn = CertificateModel(
            name: "KsignNext", fingerprint: "DEADBEEF", teamIdentifier: "TEAM123")
        var profileToReturn = ProvisioningModel(
            name: "iOS Team Provisioning Profile: com.example.app",
            uuid: "11111111-2222-3333-4444-555555555555",
            appIdentifier: "TEAM123.com.example.app",
            teamIdentifier: "TEAM123")

        func parseP12(at url: URL, password: String) async throws -> CertificateModel { certificateToReturn }
        func parseCertificate(at url: URL) async throws -> CertificateModel { certificateToReturn }
        func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel { profileToReturn }
        func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws {}
        func status(of certificate: CertificateModel) async -> CertificateStatus { .valid }
        func importP12(at url: URL, password: String) async throws -> CertificateModel {
            importedP12.append((url, password))
            return certificateToReturn
        }
        func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
            importedProfiles.append(url)
            return profileToReturn
        }
    }

    private static let login = AppleIDLoginResult(
        email: "test@example.com", firstName: "Test", lastName: "User", adsid: "adsid-1")
    private static let token = AppleRefreshAppToken(
        app: "com.apple.gs.xcode.auth", hasToken: true, tokenLength: 42)
    private static let team = DeveloperTeam(
        teamID: "TEAM123", name: "Test", type: "Individual", status: "active")
    private static let device = DeveloperDevice(
        deviceID: "DEV1", deviceNumber: "0000802000112233445566778899AABBCCDDEEFF",
        name: "iPhone", status: "active")
    private static let udid = "0000802000112233445566778899AABBCCDDEEFF"
    private static let ipaURL = URL(fileURLWithPath: "/Documents/SignedApps/App.ipa")

    private var suite: UserDefaults!
    private var store: AppleIDSessionStore!
    private var fake: FakeAppleRefreshClient!
    private var signInUseCase: AppleIDSignInUseCase!
    private var certRepo: StubCertificateRepository!
    private var fakeEngine: FakeCertificateEngine!
    private var realRefresh: RealRefreshUseCase!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "RealRefreshUseCaseTests")!
        suite.removePersistentDomain(forName: "RealRefreshUseCaseTests")
        store = AppleIDSessionStore(
            keychain: KeychainService(service: "com.ksignnext.app.test-realrefresh"),
            defaults: suite)
        store.clearSession()
        let fakeClient = FakeAppleRefreshClient()
        fake = fakeClient
        signInUseCase = AppleIDSignInUseCase(
            store: store,
            servers: AnisetteServerProvider(defaults: suite),
            clientFactory: { fakeClient })
        certRepo = StubCertificateRepository()
        fakeEngine = FakeCertificateEngine()
        let signedRepo = StubSignedRepository()
        let refreshUseCase = RefreshApplicationUseCase(
            signedRepository: signedRepo,
            certificateRepository: certRepo,
            provisioningEngine: ProvisioningEngine(),
            ipaEngine: IPAEngine())
        let signUseCase = SignApplicationUseCase(
            signingEngine: SigningEngine(),
            certificateRepository: certRepo,
            signedRepository: signedRepo)
        realRefresh = RealRefreshUseCase(
            signInUseCase: signInUseCase,
            developerService: DeveloperServiceUseCase(signInUseCase: signInUseCase),
            certificateEngine: fakeEngine,
            certificateRepository: certRepo,
            refreshUseCase: refreshUseCase,
            signUseCase: signUseCase)
    }

    private func execute(udid: String = Self.udid) async throws -> RealRefreshResult {
        try await realRefresh.execute(
            signedIPAURL: Self.ipaURL,
            bundleID: "com.example.app",
            appName: "Example",
            udid: udid,
            deviceName: "iPhone",
            twoFactorHandler: { _ in .abort },
            onProgress: { _ in })
    }

    /// Signs in through the fake so the refresh starts with a live
    /// client (the path a signed-in user takes).
    private func signIn() async throws {
        fake.loginQueue = [.success(Self.login)]
        fake.tokenQueue = [.success(Self.token)]
        _ = try await signInUseCase.signIn(
            email: "test@example.com", password: "pw", twoFactorHandler: { _ in .abort })
    }

    func testMissingUDIDThrowsBeforeAnyDevCall() async {
        do {
            _ = try await execute(udid: "not-a-udid")
            XCTFail("Expected missingUDID")
        } catch let error as RealRefreshError {
            XCTAssertEqual(error, .missingUDID)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertTrue(fake.devCalls.isEmpty, "No Apple call may happen without a UDID")
    }

    func testSignInRequiredWithoutSavedPassword() async {
        // No live client and no saved password: the refresh cannot
        // sign in silently, so it must ask the user to sign in.
        do {
            _ = try await execute()
            XCTFail("Expected signInRequired")
        } catch let error as RealRefreshError {
            XCTAssertEqual(error, .signInRequired)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertTrue(fake.devCalls.isEmpty)
    }

    func testNoTeamsThrows() async throws {
        try await signIn()
        fake.teamsResult = .success([])
        do {
            _ = try await execute()
            XCTFail("Expected noTeams")
        } catch let error as RealRefreshError {
            XCTAssertEqual(error, .noTeams)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(fake.devCalls, ["listTeams"])
    }

    func testCertificateLimitMapsToTypedError() async throws {
        try await signIn()
        fake.teamsResult = .success([Self.team])
        fake.ensureDeviceResult = .success(Self.device)
        fake.createCertificateResult = .failure(
            .developerError(appleEC: 7460, appleEM: "limit", message: "max certs"))
        do {
            _ = try await execute()
            XCTFail("Expected certificateLimit")
        } catch let error as RealRefreshError {
            XCTAssertEqual(error, .certificateLimit(teamID: "TEAM123"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(fake.devCalls, ["listTeams", "ensureDevice", "createCertificate"])
        XCTAssertTrue(fakeEngine.importedP12.isEmpty, "No .p12 may be imported after a 7460")
    }

    func testAppIDQuotaThrows() async throws {
        try await signIn()
        fake.teamsResult = .success([Self.team])
        fake.ensureDeviceResult = .success(Self.device)
        fake.createCertificateResult = .success(CreatedCertificate(
            reused: false, machineID: "M1", machineName: "KsignNext",
            serialNumber: "A1B2C3", notAfter: nil,
            p12Data: Data([0x30, 0x82]), p12Password: "pw"))
        fake.appIDsResult = .success(DeveloperAppIDList(
            appIDs: [], maxQuantity: 10, availableQuantity: 0))
        do {
            _ = try await execute()
            XCTFail("Expected appIDQuota")
        } catch let error as RealRefreshError {
            XCTAssertEqual(error, .appIDQuota(available: 0))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(fake.devCalls, ["listTeams", "ensureDevice", "createCertificate", "listAppIDs"])
        XCTAssertEqual(fakeEngine.importedP12.count, 1, "The certificate is imported before the App ID check")
        XCTAssertEqual(certRepo.certificates.count, 1, "The imported certificate is saved for signing")
    }
}
