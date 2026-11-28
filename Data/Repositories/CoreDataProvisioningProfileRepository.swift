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

    public func fetchAll() async throws -> [ProvisioningModel] {
        do {
            return try await perform { context in
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
            return try await perform { context in
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
            return try await perform { context in
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
            try await perform { context in
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
        let request = NSFetchRequest<NSManagedObject>(entityName: ProvisioningProfileMapper.entityName)
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
