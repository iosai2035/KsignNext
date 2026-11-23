import Foundation

/// Repository contracts. All methods are async and throw typed
/// `AppError.storage` errors; no repository ever returns mock data.

public protocol ImportedApplicationRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [ImportedIPA]
    func fetch(id: UUID) async throws -> ImportedIPA?
    func fetch(bundleIdentifier: String) async throws -> [ImportedIPA]
    func save(_ application: ImportedIPA) async throws
    func delete(id: UUID) async throws
}

public protocol SignedApplicationRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [SigningResult]
    func fetch(id: UUID) async throws -> SigningResult?
    func save(_ result: SigningResult) async throws
    func delete(id: UUID) async throws
}

public protocol CertificateRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [CertificateModel]
    func fetch(id: UUID) async throws -> CertificateModel?
    func fetch(fingerprint: String) async throws -> CertificateModel?
    func save(_ certificate: CertificateModel) async throws
    func delete(id: UUID) async throws
}

public protocol SourceRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [SourceModel]
    func fetch(id: UUID) async throws -> SourceModel?
    func save(_ source: SourceModel) async throws
    func delete(id: UUID) async throws
}

public protocol DownloadTaskRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [DownloadTaskModel]
    func fetch(id: UUID) async throws -> DownloadTaskModel?
    func fetchActive() async throws -> [DownloadTaskModel]
    func save(_ task: DownloadTaskModel) async throws
    func delete(id: UUID) async throws
}

public protocol LogRepository: AnyObject, Sendable {
    func fetchAll(limit: Int) async throws -> [OperationLogModel]
    func fetch(forOperation operationID: UUID) async throws -> [OperationLogModel]
    func save(_ log: OperationLogModel) async throws
    func deleteAll() async throws
}
