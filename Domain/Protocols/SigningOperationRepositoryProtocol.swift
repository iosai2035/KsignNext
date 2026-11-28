import Foundation

/// The stored record of signing operations. `save` is an upsert by
/// id; `fetch` returns nil when missing; `delete` throws when missing.
public protocol SigningOperationRepositoryProtocol: AnyObject, Sendable {
    func fetchAll() async throws -> [SigningOperationModel]
    func fetch(id: UUID) async throws -> SigningOperationModel?
    func save(_ operation: SigningOperationModel) async throws
    func delete(id: UUID) async throws
}
