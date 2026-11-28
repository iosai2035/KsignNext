import CoreData
import Foundation

/// Core Data implementation of `ProvisioningProfileRepository`.
/// Stores profile metadata only — the raw profile bytes live on disk
/// as a file (`fileURL`) and are never duplicated into Core Data.
///
/// Core Data errors are mapped to `AppError.storage` at this boundary:
/// errors already typed as `AppError` (e.g. `.notFound` from a
/// missing delete) pass through untouched; any other error from a
/// fetch becomes `.loadFailed`, from a save `.saveFailed`, from a
/// delete `.deleteFailed`. This repository never touches the Keychain
/// or the filesystem.
public final class CoreDataProvisioningProfileRepository: ProvisioningProfileRepository, @unchecked Sendable {
    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [ProvisioningModel] {
        do {
            return try await persistence.performBackground { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: ProvisioningProfileMapper.entityName)
                request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
                return try context.fetch(request).compactMap(ProvisioningProfileMapper.toModel)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func fetch(id: UUID) async throws -> ProvisioningModel? {
        do {
            return try await persistence.performBackground { context in
                guard let object = try Self.find(id: id, in: context) else { return nil }
                return ProvisioningProfileMapper.toModel(object)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func fetch(uuid: String) async throws -> ProvisioningModel? {
        do {
            return try await persistence.performBackground { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: ProvisioningProfileMapper.entityName)
                request.predicate = NSPredicate(format: "uuid == %@", uuid)
                request.fetchLimit = 1
                return try context.fetch(request).first.flatMap(ProvisioningProfileMapper.toModel)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storage(.loadFailed(reason: error.localizedDescription))
        }
    }

    public func save(_ profile: ProvisioningModel) async throws {
        do {
            try await persistence.performBackground { context in
                let object = try Self.find(id: profile.id, in: context)
                    ?? NSEntityDescription.insertNewObject(forEntityName: ProvisioningProfileMapper.entityName, into: context)
                ProvisioningProfileMapper.apply(profile, to: object)
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
        let request = NSFetchRequest<NSManagedObject>(entityName: ProvisioningProfileMapper.entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}
