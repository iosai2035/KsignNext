import CoreData
import Foundation

/// Core Data stack for the `KsignNext` model (version v2).
///
/// - No lightweight migration: the store is never migrated
///   automatically. An old, incompatible store is detected with
///   `storeRequiresManualMigration()` and must be handled by the
///   manual-migration flow (ask the user to back up, then
///   `resetStoreForManualMigration()`, then load a fresh empty store
///   and move the data programmatically). A failed load surfaces as a
///   typed `AppError.storage(.migrationFailed)` instead of crashing.
/// - No passwords or private keys are ever stored in this store:
///   secrets live only in the Keychain (see `KeychainService`).
/// - Writes go through a background context; the view context is
///   read-only from the UI thread.
/// - `performBackground` must only be called after `load()` has
///   succeeded; before that it throws
///   `AppError.storage(.unavailable)`.
public final class PersistenceController: @unchecked Sendable {
    public static let shared = PersistenceController()

    public static let modelName = "KsignNext"
    public static let storeFileName = "KsignNext.sqlite"

    public let container: NSPersistentContainer

    /// `true` once `load()` has successfully loaded the stores.
    public private(set) var isLoaded = false

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
            // Manual migration only (blueprint §2): never migrate
            // automatically and never infer a mapping model.
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            container.persistentStoreDescriptions = [description]
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Loads the persistent stores. Call once at launch (or once per
    /// fresh controller after a manual-migration reset); throws a
    /// typed error instead of calling `fatalError` so the app can
    /// show a recovery screen. When the existing store is from an
    /// older model version, the error explains that a manual
    /// migration is needed.
    public func load() async throws {
        if isLoaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    let reason: String
                    if self.storeRequiresManualMigration() {
                        reason = "The existing data store is from an older version and cannot be opened automatically. Back up your files, then reset the store to start fresh. (\(error.localizedDescription))"
                    } else {
                        reason = error.localizedDescription
                    }
                    continuation.resume(throwing: AppError.storage(.migrationFailed(reason: reason)))
                } else {
                    // Set the flag before resuming so a caller that
                    // immediately uses the stack after `load()`
                    // returns sees a loaded store.
                    self.isLoaded = true
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

    // MARK: - Manual migration

    /// `true` when a store file exists on disk but was written by an
    /// older model version, so `load()` cannot open it and the manual
    /// migration flow must run. `false` on first launch (no store
    /// file yet), when the store matches the current model, and when
    /// the store metadata cannot be read at all (in that case
    /// `load()` reports the failure itself).
    public func storeRequiresManualMigration() -> Bool {
        let url = Self.storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        } catch {
            return false
        }
        return !container.managedObjectModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// Removes the existing store files so a fresh empty store can be
    /// created. This is one step of the manual-migration flow only —
    /// never called automatically. The caller must discard this
    /// controller and create a fresh `PersistenceController` before
    /// calling `load()`, because this controller's container is bound
    /// to the removed store.
    public func resetStoreForManualMigration() throws {
        try destroyStore()
    }

    /// Deletes the store file. Used only for an explicit user "reset
    /// data" action (via `resetStoreForManualMigration()`); never
    /// called automatically.
    public func destroyStore() throws {
        let url = Self.storeURL()
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                throw AppError.storage(.deleteFailed(reason: error.localizedDescription))
            }
        }
        for fileURL in [url, URL(fileURLWithPath: url.path + "-shm"), URL(fileURLWithPath: url.path + "-wal")] {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    throw AppError.storage(.deleteFailed(reason: error.localizedDescription))
                }
            }
        }
        isLoaded = false
    }

    // MARK: - Contexts

    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Runs `work` on a background context and saves it if it changed.
    /// Errors thrown by `work` pass through untouched (so a
    /// repository's typed `AppError`, e.g. `.notFound`, is never
    /// re-wrapped); only a context-save failure is mapped, to
    /// `AppError.storage(.saveFailed)`. Mapping of fetch errors to
    /// `AppError.storage` happens in the repositories, at their
    /// boundary.
    public func performBackground<T>(_ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        guard isLoaded else {
            throw AppError.storage(.unavailable(reason: "The data store has not finished loading yet."))
        }
        let context = newBackgroundContext()
        return try await context.perform {
            let result = try work(context)
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    throw AppError.storage(.saveFailed(reason: error.localizedDescription))
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
            throw AppError.storage(.saveFailed(reason: error.localizedDescription))
        }
    }
}
