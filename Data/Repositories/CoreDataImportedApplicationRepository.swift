import CoreData
import Foundation

/// Core Data implementation of `ImportedApplicationRepository`.
/// Uses generic `NSManagedObject` access so no generated subclasses
/// are required; attribute names match `KsignNext.xcdatamodel`.
public final class CoreDataImportedApplicationRepository: ImportedApplicationRepository, @unchecked Sendable {
    private let persistence: PersistenceController
    private static let entityName = "ImportedApplication"

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [ImportedIPA] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
            let objects = try context.fetch(request)
            return objects.compactMap(Self.map)
        }
    }

    public func fetch(id: UUID) async throws -> ImportedIPA? {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else { return nil }
            return Self.map(object)
        }
    }

    public func fetch(bundleIdentifier: String) async throws -> [ImportedIPA] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "bundleIdentifier == %@", bundleIdentifier)
            request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func save(_ application: ImportedIPA) async throws {
        try await persistence.performBackground { context in
            let object = try Self.find(id: application.id, in: context)
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            object.setValue(application.id, forKey: "id")
            object.setValue(application.name, forKey: "name")
            object.setValue(application.bundleIdentifier, forKey: "bundleIdentifier")
            object.setValue(application.version, forKey: "version")
            object.setValue(application.buildVersion, forKey: "buildVersion")
            object.setValue(application.fileSize, forKey: "fileSize")
            object.setValue(application.importedAt, forKey: "importedAt")
            object.setValue(application.fileURL.absoluteString, forKey: "fileURL")
            object.setValue(application.iconData, forKey: "iconData")
            object.setValue(application.architecture, forKey: "architecture")
            object.setValue(application.signatureStatus.rawValue, forKey: "signatureStatus")
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

    // MARK: - Private helpers

    private static func find(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func map(_ object: NSManagedObject) -> ImportedIPA? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        let fileURLString = object.value(forKey: "fileURL") as? String
        return ImportedIPA(
            id: id,
            name: object.value(forKey: "name") as? String ?? "",
            bundleIdentifier: object.value(forKey: "bundleIdentifier") as? String ?? "",
            version: object.value(forKey: "version") as? String ?? "",
            buildVersion: object.value(forKey: "buildVersion") as? String ?? "",
            fileSize: object.value(forKey: "fileSize") as? Int64 ?? 0,
            importedAt: object.value(forKey: "importedAt") as? Date ?? Date(),
            fileURL: fileURLString.flatMap(URL.init(string:)) ?? URL(fileURLWithPath: ""),
            iconData: object.value(forKey: "iconData") as? Data,
            architecture: object.value(forKey: "architecture") as? String ?? "arm64",
            signatureStatus: SignatureStatus(rawValue: object.value(forKey: "signatureStatus") as? String ?? "") ?? .unknown
        )
    }
}
