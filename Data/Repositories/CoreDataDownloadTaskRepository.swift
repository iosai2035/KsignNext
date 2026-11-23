import CoreData
import Foundation

/// Core Data implementation of `DownloadTaskRepository`.
public final class CoreDataDownloadTaskRepository: DownloadTaskRepository, @unchecked Sendable {
    private let persistence: PersistenceController
    private static let entityName = "DownloadTask"

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [DownloadTaskModel] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func fetch(id: UUID) async throws -> DownloadTaskModel? {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else { return nil }
            return Self.map(object)
        }
    }

    public func fetchActive() async throws -> [DownloadTaskModel] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "status IN %@", ["queued", "downloading", "paused"])
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func save(_ task: DownloadTaskModel) async throws {
        try await persistence.performBackground { context in
            let object = try Self.find(id: task.id, in: context)
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            object.setValue(task.id, forKey: "id")
            object.setValue(task.url.absoluteString, forKey: "url")
            object.setValue(task.fileName, forKey: "fileName")
            object.setValue(task.destinationURL?.absoluteString, forKey: "destinationURL")
            object.setValue(task.downloadedBytes, forKey: "downloadedBytes")
            object.setValue(task.totalBytes ?? 0, forKey: "totalBytes")
            object.setValue(task.currentStage, forKey: "currentStage")
            object.setValue(task.progress, forKey: "progress")
            object.setValue(task.status.rawValue, forKey: "status")
            object.setValue(task.error, forKey: "error")
            object.setValue(task.expectedChecksum, forKey: "expectedChecksum")
            object.setValue(task.startedAt, forKey: "startedAt")
            object.setValue(task.completedAt, forKey: "completedAt")
        }
    }

    public func delete(id: UUID) async throws {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else {
                throw StorageError.notFound(id: id.uuidString)
            }
            context.delete(object)
        }
    }

    private static func find(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func map(_ object: NSManagedObject) -> DownloadTaskModel? {
        guard let id = object.value(forKey: "id") as? UUID,
              let urlString = object.value(forKey: "url") as? String,
              let url = URL(string: urlString) else { return nil }
        let destinationString = object.value(forKey: "destinationURL") as? String
        let totalBytes = object.value(forKey: "totalBytes") as? Int64 ?? 0
        return DownloadTaskModel(
            id: id,
            url: url,
            fileName: object.value(forKey: "fileName") as? String ?? "",
            destinationURL: destinationString.flatMap(URL.init(string:)),
            downloadedBytes: object.value(forKey: "downloadedBytes") as? Int64 ?? 0,
            totalBytes: totalBytes == 0 ? nil : totalBytes,
            currentStage: object.value(forKey: "currentStage") as? String ?? "",
            progress: object.value(forKey: "progress") as? Double ?? 0,
            status: DownloadStatus(rawValue: object.value(forKey: "status") as? String ?? "") ?? .queued,
            error: object.value(forKey: "error") as? String,
            expectedChecksum: object.value(forKey: "expectedChecksum") as? String,
            startedAt: object.value(forKey: "startedAt") as? Date,
            completedAt: object.value(forKey: "completedAt") as? Date
        )
    }
}
