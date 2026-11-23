import CoreData
import Foundation

/// Core Data implementation of `SignedApplicationRepository`.
public final class CoreDataSignedApplicationRepository: SignedApplicationRepository, @unchecked Sendable {
    private let persistence: PersistenceController
    private static let entityName = "SignedApplication"

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [SigningResult] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "signingDate", ascending: false)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func fetch(id: UUID) async throws -> SigningResult? {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else { return nil }
            return Self.map(object)
        }
    }

    public func save(_ result: SigningResult) async throws {
        try await persistence.performBackground { context in
            let object = try Self.find(id: result.id, in: context)
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            object.setValue(result.id, forKey: "id")
            object.setValue(result.importedIPAID, forKey: "importedIPAID")
            object.setValue(result.operationID, forKey: "operationID")
            object.setValue(result.bundleIdentifier, forKey: "name")
            object.setValue(result.bundleIdentifier, forKey: "bundleIdentifier")
            object.setValue(result.version, forKey: "version")
            object.setValue("", forKey: "buildVersion")
            object.setValue(result.fileSize, forKey: "fileSize")
            object.setValue(result.signedAt, forKey: "signingDate")
            object.setValue(result.signedFileURL.absoluteString, forKey: "fileURL")
            object.setValue(result.signatureStatus.rawValue, forKey: "signatureStatus")
            object.setValue(result.certificateID, forKey: "certificateID")
            object.setValue(result.teamIdentifier, forKey: "teamIdentifier")
            object.setValue(result.certificateFingerprint, forKey: "fingerprint")
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

    private static func map(_ object: NSManagedObject) -> SigningResult? {
        guard let id = object.value(forKey: "id") as? UUID,
              let operationID = object.value(forKey: "operationID") as? UUID,
              let importedIPAID = object.value(forKey: "importedIPAID") as? UUID else { return nil }
        let fileURLString = object.value(forKey: "fileURL") as? String
        return SigningResult(
            id: id,
            operationID: operationID,
            importedIPAID: importedIPAID,
            signedFileURL: fileURLString.flatMap(URL.init(string:)) ?? URL(fileURLWithPath: ""),
            bundleIdentifier: object.value(forKey: "bundleIdentifier") as? String ?? "",
            version: object.value(forKey: "version") as? String ?? "",
            certificateID: object.value(forKey: "certificateID") as? UUID,
            certificateFingerprint: object.value(forKey: "fingerprint") as? String,
            teamIdentifier: object.value(forKey: "teamIdentifier") as? String,
            signatureStatus: SignatureStatus(rawValue: object.value(forKey: "signatureStatus") as? String ?? "") ?? .signed,
            verified: false,
            fileSize: object.value(forKey: "fileSize") as? Int64 ?? 0,
            signedAt: object.value(forKey: "signingDate") as? Date ?? Date(),
            duration: 0
        )
    }
}
