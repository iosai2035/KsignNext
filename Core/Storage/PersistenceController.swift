import CoreData
import Foundation

/// Core Data stack for the `KsignNext` model.
///
/// - Lightweight migration is enabled; a failed migration surfaces as a
///   typed `StorageError.migrationFailed` instead of crashing.
/// - No passwords or private keys are ever stored in this store: secrets
///   live only in the Keychain (see `KeychainService`).
/// - Writes go through a background context; the view context is read-only
///   from the UI thread.
public final class PersistenceController {
    public static let shared = PersistenceController()

    public static let modelName = "KsignNext"
    public static let storeFileName = "KsignNext.sqlite"

    public let container: NSPersistentContainer

    public var viewContext: NSManagedObjectContext { container.viewContext }

    public init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: Self.modelName)
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else {
            let storeURL = Self.storeURL()
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            container.persistentStoreDescriptions = [description]
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Loads the persistent stores. Call once at launch; throws a typed
    /// error instead of calling `fatalError` so the app can show a
    /// recovery screen.
    public func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: StorageError.migrationFailed(reason: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public static func storeURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("KsignNext").appendingPathComponent(storeFileName)
    }

    // MARK: - Contexts

    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Runs `work` on a background context and saves it if it changed.
    public func performBackground<T>(_ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = newBackgroundContext()
        return try await context.perform {
            let result = try work(context)
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    throw StorageError.saveFailed(reason: error.localizedDescription)
                }
            }
            return result
        }
    }

    public func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            throw StorageError.saveFailed(reason: error.localizedDescription)
        }
    }

    /// Deletes the store file. Used only for an explicit user "reset data"
    /// action; never called automatically.
    public func destroyStore() throws {
        let url = Self.storeURL()
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                throw StorageError.deleteFailed(reason: error.localizedDescription)
            }
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    }
}
