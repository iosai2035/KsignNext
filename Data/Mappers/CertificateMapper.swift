import CoreData
import Foundation

/// Managed-object ↔ `CertificateModel` mapping. Lives in Data, not
/// Domain: Domain never imports Core Data. The store uses generic
/// `NSManagedObject` (no generated subclasses); all field access goes
/// through `value(forKey:)` / `setValue(_:forKey:)` here, so a model
/// change touches exactly one file.
///
/// `fileURL` is stored as a String (`absoluteString`) and parsed back
/// with `URL(string:)`; an unparseable stored string yields `nil`
/// rather than a crash.
public enum CertificateMapper {
    public static let entityName = "Certificate"

    /// Builds a model from a managed object, or `nil` when the row
    /// has no `id` (a corrupt row is dropped by the caller's
    /// `compactMap`, never thrown).
    public static func toModel(_ object: NSManagedObject) -> CertificateModel? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        let keychainAccount = object.value(forKey: "keychainAccount") as? String
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
            keychainAccount: keychainAccount,
            isStoredInKeychain: object.value(forKey: "isStoredInKeychain") as? Bool ?? (keychainAccount != nil),
            importedAt: object.value(forKey: "importedAt") as? Date ?? Date()
        )
    }

    /// Writes every model field into an existing managed object
    /// (inserted or fetched by the repository).
    public static func apply(_ model: CertificateModel, to object: NSManagedObject) {
        object.setValue(model.id, forKey: "id")
        object.setValue(model.name, forKey: "name")
        object.setValue(model.commonName, forKey: "commonName")
        object.setValue(model.issuer, forKey: "issuer")
        object.setValue(model.serialNumber, forKey: "serialNumber")
        object.setValue(model.fingerprint, forKey: "fingerprint")
        object.setValue(model.teamIdentifier, forKey: "teamIdentifier")
        object.setValue(model.kind.rawValue, forKey: "kind")
        object.setValue(model.status.rawValue, forKey: "status")
        object.setValue(model.notBefore, forKey: "notBefore")
        object.setValue(model.expirationDate, forKey: "expirationDate")
        object.setValue(model.fileURL?.absoluteString, forKey: "fileURL")
        object.setValue(model.keychainAccount, forKey: "keychainAccount")
        object.setValue(model.isStoredInKeychain, forKey: "isStoredInKeychain")
        object.setValue(model.importedAt, forKey: "importedAt")
    }
}
