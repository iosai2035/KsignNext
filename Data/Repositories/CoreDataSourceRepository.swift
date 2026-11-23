import CoreData
import Foundation

/// Core Data implementation of `SourceRepository`.
public final class CoreDataSourceRepository: SourceRepository, @unchecked Sendable {
    private let persistence: PersistenceController
    private static let entityName = "Source"

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [SourceModel] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func fetch(id: UUID) async throws -> SourceModel? {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else { return nil }
            return Self.map(object)
        }
    }

    public func save(_ source: SourceModel) async throws {
        try await persistence.performBackground { context in
            let object = try Self.find(id: source.id, in: context)
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            object.setValue(source.id, forKey: "id")
            object.setValue(source.name, forKey: "name")
            object.setValue(source.url.absoluteString, forKey: "url")
            object.setValue(source.identifier, forKey: "identifier")
            object.setValue(source.lastUpdated, forKey: "lastUpdated")
            object.setValue(Int64(source.appCount), forKey: "appCount")
            object.setValue(source.isEnabled, forKey: "isEnabled")
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

    private static func map(_ object: NSManagedObject) -> SourceModel? {
        guard let id = object.value(forKey: "id") as? UUID,
              let urlString = object.value(forKey: "url") as? String,
              let url = URL(string: urlString) else { return nil }
        return SourceModel(
            id: id,
            name: object.value(forKey: "name") as? String ?? "",
            url: url,
            identifier: object.value(forKey: "identifier") as? String,
            lastUpdated: object.value(forKey: "lastUpdated") as? Date,
            appCount: Int(object.value(forKey: "appCount") as? Int64 ?? 0),
            isEnabled: object.value(forKey: "isEnabled") as? Bool ?? true
        )
    }
}
