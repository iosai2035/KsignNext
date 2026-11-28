import Foundation

/// Dependency injection container for the Phase 1 rebuild.
///
/// Wiring only — no business logic lives here. Every resolver throws
/// (W-5): callers handle failure explicitly instead of silently
/// receiving `nil`. There are no login / session objects
/// anywhere in this container (the sign-in stack was deleted in the
/// rebuild; see `Documentation/Rebuild-2026-11-28.md` §10).
///
/// Engines and repositories are built once, in `init`, and shared by
/// every tab through the `AppCoordinator`. Tests override them through
/// the initialiser.
public final class DependencyContainer {

    // MARK: - Core services (built once)

    public let persistence: PersistenceController
    public let keychain: KeychainService
    public let files: FileSystemManager
    public let httpClient: HTTPClient
    public let taskRegistry: TaskRegistry

    // MARK: - Engines (constructed by default; injectable for tests)

    public var certificateEngine: CertificateEngineProtocol
    public var provisioningEngine: ProvisioningEngineProtocol

    public init(
        persistence: PersistenceController = .shared,
        keychain: KeychainService = .shared,
        files: FileSystemManager = .shared,
        httpClient: HTTPClient = .shared,
        taskRegistry: TaskRegistry = TaskRegistry(),
        certificateEngine: CertificateEngineProtocol? = nil,
        provisioningEngine: ProvisioningEngineProtocol? = nil
    ) {
        self.persistence = persistence
        self.keychain = keychain
        self.files = files
        self.httpClient = httpClient
        self.taskRegistry = taskRegistry
        self.certificateEngine = certificateEngine ?? CertificateEngine(keychain: keychain, fileManager: files)
        self.provisioningEngine = provisioningEngine ?? ProvisioningEngine(keychain: keychain, fileManager: files)
    }

    // MARK: - Repositories (lazy, concrete Core Data)

    public lazy var certificateRepository: CertificateRepository =
        CoreDataCertificateRepository(persistence: persistence)

    public lazy var provisioningProfileRepository: ProvisioningProfileRepository =
        CoreDataProvisioningProfileRepository(persistence: persistence)

    // MARK: - Throwing resolvers (W-5)

    /// Returns the certificate engine. The `throws` is call-site
    /// discipline (W-5): a resolver that can fail must be handled,
    /// never silently nilled. Nothing in `init` can leave this unset.
    public func resolveCertificateEngine() throws -> CertificateEngineProtocol {
        certificateEngine
    }

    public func resolveProvisioningEngine() throws -> ProvisioningEngineProtocol {
        provisioningEngine
    }

    public func resolveCertificateRepository() throws -> CertificateRepository {
        certificateRepository
    }

    public func resolveProvisioningProfileRepository() throws -> ProvisioningProfileRepository {
        provisioningProfileRepository
    }

    public func resolveKeychain() throws -> KeychainService {
        keychain
    }

    public func resolveFileSystem() throws -> FileSystemManager {
        files
    }

    // MARK: - Use-case factories

    public func makeImportCertificateUseCase() throws -> ImportCertificateUseCase {
        ImportCertificateUseCase(
            engine: try resolveCertificateEngine(),
            repository: try resolveCertificateRepository(),
            keychain: keychain,
            fileSystem: files,
            logger: AppLogger.shared
        )
    }

    public func makeImportProvisioningProfileUseCase() throws -> ImportProvisioningProfileUseCase {
        ImportProvisioningProfileUseCase(
            engine: try resolveProvisioningEngine(),
            repository: try resolveProvisioningProfileRepository(),
            fileSystem: files,
            logger: AppLogger.shared
        )
    }

    public func makeDeleteCertificateUseCase() throws -> DeleteCertificateUseCase {
        DeleteCertificateUseCase(
            repository: try resolveCertificateRepository(),
            keychain: keychain,
            fileSystem: files,
            logger: AppLogger.shared
        )
    }

    public func makeDeleteProvisioningProfileUseCase() throws -> DeleteProvisioningProfileUseCase {
        DeleteProvisioningProfileUseCase(
            repository: try resolveProvisioningProfileRepository(),
            fileSystem: files,
            logger: AppLogger.shared
        )
    }

    public func makeFetchExpiringProfilesUseCase() throws -> FetchExpiringProfilesUseCase {
        FetchExpiringProfilesUseCase(
            repository: try resolveProvisioningProfileRepository(),
            engine: try resolveProvisioningEngine()
        )
    }
}
