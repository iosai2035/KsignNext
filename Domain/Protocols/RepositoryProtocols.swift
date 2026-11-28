import Foundation

/// Repository contracts. All methods are async and throw `AppError`
/// (storage cases); no repository ever returns mock data, touches the
/// Keychain, or touches the filesystem — side-effect cleanup belongs
/// to the use cases, not the repository.
///
/// - `save` is an upsert by `id` and returns `Void`.
/// - `fetch` returns `nil` when the record is missing.
/// - `delete` throws `AppError.storage(.notFound(id:))` when the
///   record is missing.
/// - `fetchAll` is sorted by `importedAt` descending.
public protocol CertificateRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [CertificateModel]
    func fetch(id: UUID) async throws -> CertificateModel?
    func fetch(fingerprint: String) async throws -> CertificateModel?
    func save(_ certificate: CertificateModel) async throws
    func delete(id: UUID) async throws
}

/// Repository contract for provisioning profiles. There was no profile
/// repository before Phase 1; the shape mirrors
/// `CertificateRepository`.
public protocol ProvisioningProfileRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [ProvisioningModel]
    func fetch(id: UUID) async throws -> ProvisioningModel?
    func fetch(uuid: String) async throws -> ProvisioningModel?
    func save(_ profile: ProvisioningModel) async throws
    func delete(id: UUID) async throws
}
