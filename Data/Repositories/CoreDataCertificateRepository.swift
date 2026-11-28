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
    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [CertificateModel] {
        do {
            return try await persistence.performBackground { context in
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
            return try await persistence.performBackground { context in
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
            return try await persistence.performBackground { context in
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
            try await persistence.performBackground { context in
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
            try await persistence.performBackground { context in
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
}
