import Foundation

/// Dependency injection container.
///
/// Repositories are built here (concrete Core Data implementations).
/// Engines are constructed here by default (coordinator integration —
/// the builders delivered the real engines, so the container wires
/// them up); an engine can still be overridden through the initialiser
/// for tests. The signing engine's certificate resolver reads the
/// certificate repository; its provisioning resolver re-parses the
/// `.mobileprovision` files in the workspace Certificates folder and
/// matches the profile's stable id (derived from the profile UUID by
/// `ProvisioningEngine`, so the same profile resolves to the same id
/// at import time and at signing time).
public final class DependencyContainer {
    public let configuration: AppConfiguration
    public let persistence: PersistenceController
    public let logs: LogsManager
    public let keychain: KeychainService
    public let files: SecureFileManager
    public let httpClient: HTTPClient
    public let taskManager: TaskManager

    // Engines (constructed by default; injectable for tests).
    public var ipaEngine: IPAEngineProtocol
    public var signingEngine: SigningEngineProtocol
    public var certificateEngine: CertificateEngineProtocol
    public var machOEngine: MachOEngineProtocol
    public var downloadEngine: DownloadEngine
    public var verificationEngine: VerificationEngine
    public var installationEngine: InstallationEngine

    public init(
        configuration: AppConfiguration = .fromBundle(),
        persistence: PersistenceController = .shared,
        logs: LogsManager = .shared,
        keychain: KeychainService = .shared,
        files: SecureFileManager = .shared,
        httpClient: HTTPClient = .shared,
        taskManager: TaskManager = .shared,
        ipaEngine: IPAEngineProtocol? = nil,
        signingEngine: SigningEngineProtocol? = nil,
        certificateEngine: CertificateEngineProtocol? = nil,
        machOEngine: MachOEngineProtocol? = nil,
        downloadEngine: DownloadEngine? = nil,
        verificationEngine: VerificationEngine? = nil,
        installationEngine: InstallationEngine? = nil
    ) {
        self.configuration = configuration
        self.persistence = persistence
        self.logs = logs
        self.keychain = keychain
        self.files = files
        self.httpClient = httpClient
        self.taskManager = taskManager
        self.ipaEngine = ipaEngine ?? IPAEngine()
        self.certificateEngine = certificateEngine ?? CertificateEngine(keychain: keychain, fileManager: files)
        self.machOEngine = machOEngine ?? MachOEngine()
        self.downloadEngine = downloadEngine ?? DownloadEngine()
        self.verificationEngine = verificationEngine ?? VerificationEngine()
        self.installationEngine = installationEngine ?? InstallationEngine(server: NIOInstallationServer())
        if let signingEngine {
            self.signingEngine = signingEngine
        } else {
            let certificateRepository = CoreDataCertificateRepository(persistence: persistence)
            let provisioningEngine = ProvisioningEngine(keychain: keychain, fileManager: files)
            // Capture only Sendable values in the @Sendable resolvers:
            // the certificates directory URL, not `self` or SecureFileManager.
            let certificatesDir = try? files.folder(.certificates)
            self.signingEngine = SigningEngine(
                certificateResolver: { id in try? await certificateRepository.fetch(id: id) },
                provisioningResolver: { id in
                    guard let certificatesDir else { return nil }
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: certificatesDir, includingPropertiesForKeys: nil)) ?? []
                    for url in urls where url.pathExtension.lowercased() == "mobileprovision" {
                        if let profile = try? await provisioningEngine.parseProvisioningProfile(at: url),
                           profile.id == id {
                            return profile
                        }
                    }
                    return nil
                },
                passwordResolver: { [keychain] id in
                    try? keychain.readPassword(account: CertificateEngine.passwordAccount(for: id))
                }
            )
        }
    }

    // MARK: - Repositories (lazy, concrete Core Data)

    public lazy var importedApplicationRepository: ImportedApplicationRepository =
        CoreDataImportedApplicationRepository(persistence: persistence)

    public lazy var signedApplicationRepository: SignedApplicationRepository =
        CoreDataSignedApplicationRepository(persistence: persistence)

    public lazy var certificateRepository: CertificateRepository =
        CoreDataCertificateRepository(persistence: persistence)

    public lazy var sourceRepository: SourceRepository =
        CoreDataSourceRepository(persistence: persistence)

    public lazy var downloadTaskRepository: DownloadTaskRepository =
        CoreDataDownloadTaskRepository(persistence: persistence)

    public lazy var logRepository: LogRepository =
        LogsManagerLogRepository(logs: logs)

    // MARK: - Engine accessors

    public func requireIPAEngine() -> IPAEngineProtocol { ipaEngine }
    public func requireSigningEngine() -> SigningEngineProtocol { signingEngine }
    public func requireCertificateEngine() -> CertificateEngineProtocol { certificateEngine }
    public func requireMachOEngine() -> MachOEngineProtocol { machOEngine }
    public func requireDownloadEngine() -> DownloadEngine { downloadEngine }
    public func requireVerificationEngine() -> VerificationEngine { verificationEngine }
    public func requireInstallationEngine() -> InstallationEngine { installationEngine }

    // MARK: - Use-case factories

    public func makeImportIPAUseCase() -> ImportIPAUseCase {
        ImportIPAUseCase(ipaEngine: requireIPAEngine(), repository: importedApplicationRepository, logs: logs)
    }

    public func makeSignApplicationUseCase() -> SignApplicationUseCase {
        SignApplicationUseCase(
            signingEngine: requireSigningEngine(),
            certificateRepository: certificateRepository,
            signedRepository: signedApplicationRepository,
            logs: logs,
            taskManager: taskManager
        )
    }

    public func makeVerifySignatureUseCase() -> VerifySignatureUseCase {
        VerifySignatureUseCase(signingEngine: requireSigningEngine(), logs: logs)
    }

    public lazy var appleIDSessionStore: AppleIDSessionStore =
        AppleIDSessionStore(keychain: keychain)

    public func makeAppleIDSignInUseCase() -> AppleIDSignInUseCase {
        AppleIDSignInUseCase(store: appleIDSessionStore)
    }

    @MainActor
    public func makeAppState() -> AppState {
        AppState(configuration: configuration)
    }

    /// Kept for the AppCoordinator builder: returns the shared app
    /// state for the root view. The coordinator itself is that
    /// builder's job.
    @MainActor
    public func makeRootViewModel() -> AppState {
        makeAppState()
    }
}
