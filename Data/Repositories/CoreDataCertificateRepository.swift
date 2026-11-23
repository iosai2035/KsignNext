import CoreData
import Foundation

/// Core Data implementation of `CertificateRepository`.
/// Stores certificate metadata only — never passwords or private keys.
/// Those live in the Keychain under `keychainAccount`.
public final class CoreDataCertificateRepository: CertificateRepository, @unchecked Sendable {
    private let persistence: PersistenceController
    private static let entityName = "Certificate"

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    public func fetchAll() async throws -> [CertificateModel] {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
            return try context.fetch(request).compactMap(Self.map)
        }
    }

    public func fetch(id: UUID) async throws -> CertificateModel? {
        try await persistence.performBackground { context in
            guard let object = try Self.find(id: id, in: context) else { return nil }
            return Self.map(object)
        }
    }

    public func fetch(fingerprint: String) async throws -> CertificateModel? {
        try await persistence.performBackground { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "fingerprint == %@", fingerprint)
            request.fetchLimit = 1
            return try context.fetch(request).first.flatMap(Self.map)
        }
    }

    public func save(_ certificate: CertificateModel) async throws {
        try await persistence.performBackground { context in
            let object = try Self.find(id: certificate.id, in: context)
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            object.setValue(certificate.id, forKey: "id")
            object.setValue(certificate.name, forKey: "name")
            object.setValue(certificate.commonName, forKey: "commonName")
            object.setValue(certificate.issuer, forKey: "issuer")
            object.setValue(certificate.serialNumber, forKey: "serialNumber")
            object.setValue(certificate.fingerprint, forKey: "fingerprint")
            object.setValue(certificate.teamIdentifier, forKey: "teamIdentifier")
            object.setValue(certificate.kind.rawValue, forKey: "kind")
            object.setValue(certificate.status.rawValue, forKey: "status")
            object.setValue(certificate.notBefore, forKey: "notBefore")
            object.setValue(certificate.expirationDate, forKey: "expirationDate")
            object.setValue(certificate.fileURL?.absoluteString, forKey: "fileURL")
            object.setValue(certificate.keychainAccount, forKey: "keychainAccount")
            object.setValue(certificate.importedAt, forKey: "importedAt")
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

    private static func map(_ object: NSManagedObject) -> CertificateModel? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        let fileURLString = object.value(forKey: "fileURL") as? String
        return CertificateModel(
            id: id,
            name: object.value(forKey: "name") as? String ?? "",
            commonName: object.value(forKey: "commonName") as? String,
            issuer: object.value(forKey: "issuer") as? String,
            serialNumber: object.value(forKey: "serialNumber") as? String,
            fingerprint: object.value(forKey: "fingerprint") as? String ?? "",
            teamIdentifier: object.value(forKey: "teamIdentifier") as? String,
            kind: CertificateKind(rawValue: object.value(forKey: "kind") as? String ?? "") ?? .unknown,
            status: CertificateStatus(rawValue: object.value(forKey: "status") as? String ?? "") ?? .unknown,
            notBefore: object.value(forKey: "notBefore") as? Date,
            expirationDate: object.value(forKey: "expirationDate") as? Date,
            fileURL: fileURLString.flatMap(URL.init(string:)),
            keychainAccount: object.value(forKey: "keychainAccount") as? String,
            importedAt: object.value(forKey: "importedAt") as? Date ?? Date()
        )
    }
}
