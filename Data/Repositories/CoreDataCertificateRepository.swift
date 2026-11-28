import CoreData
import Foundation

/// Core Data implementation of `CertificateRepository`.
/// Stores certificate metadata only — never passwords or private keys.
/// Those live in the Keychain under `keychainAccount`.
///
/// Core Data errors are mapped to `AppError.storage` at this boundary:
/// errors already typed as `AppError` (e.g. `.notFound` from a
/// missing delete) pass through untouched; any other error from a
/// fetch becomes `.loadFailed`, from a save `.saveFailed`, from a
/// delete `.deleteFailed`. This repository never touches the Keychain
/// or the filesystem.
public final class CoreDataCertificateRepository: CertificateRepository, @unchecked Sendable {
    private let persistence: PersistenceController?
    private let context: NSManagedObjectContext?

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        self.context = nil
    }

    /// Test initializer: runs every operation directly on the given
    /// context (an in-memory store in the repository tests) instead
    /// of the shared persistence controller.
    public init(context: NSManagedObjectContext) {
        self.persistence = nil
        self.context = context
    }

    public func fetchAll() async throws -> [CertificateModel] {
        do {
            return try await perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: CertificateMapper.entityName)
                request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
                return try context.fetch(request).compactMap(CertificateMapper.toModel)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func fetch(id: UUID) async throws -> CertificateModel? {
        do {
            return try await perform { context in
                guard let object = try Self.find(id: id, in: context) else { return nil }
                return CertificateMapper.toModel(object)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func fetch(fingerprint: String) async throws -> CertificateModel? {
        do {
            return try await perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: CertificateMapper.entityName)
                request.predicate = NSPredicate(format: "fingerprint == %@", fingerprint)
                request.fetchLimit = 1
                return try context.fetch(request).first.flatMap(CertificateMapper.toModel)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func save(_ certificate: CertificateModel) async throws {
        do {
            try await perform { context in
                let object = try Self.find(id: certificate.id, in: context)
                    ?? NSEntityDescription.insertNewObject(forEntityName: CertificateMapper.entityName, into: context)
                CertificateMapper.apply(certificate, to: object)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.saveFailed(reason: error.localizedDescription))
        }
    }

    public func delete(id: UUID) async throws {
        do {
            try await perform { context in
                guard let object = try Self.find(id: id, in: context) else {
                    throw AppError.storage(.notFound(id: id.uuidString))
                }
                context.delete(object)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.deleteFailed(reason: error.localizedDescription))
        }
    }

    private static func find(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: CertificateMapper.entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Runs `work` through the persistence controller when one is
    /// configured, otherwise directly on the injected test context
    /// (saving it when it changed). The work's own error always takes
    /// precedence over a save error: the save only runs after the
    /// work succeeds.
    private func perform<T>(_ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        if let persistence {
            return try await persistence.performBackground(work)
        }
        guard let context else {
            throw AppError.storage(.unavailable(reason: "No data store is configured."))
        }
        return try await context.perform {
            let result = try work(context)
            if context.hasChanges {
                try context.save()
            }
            return result
        }
    }
}
