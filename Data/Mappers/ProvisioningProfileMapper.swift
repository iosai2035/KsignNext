import CoreData
import Foundation

/// Managed-object ↔ `ProvisioningModel` mapping. Lives in Data, not
/// Domain: Domain never imports Core Data. The store uses generic
/// `NSManagedObject` (no generated subclasses); all field access goes
/// through `value(forKey:)` / `setValue(_:forKey:)` here, so a model
/// change touches exactly one file.
///
/// The array / dictionary fields are Transformable attributes
/// (`NSSecureUnarchiveFromData`, custom classes `[String]` and
/// `[String: String]`); they bridge to `NSArray` / `NSDictionary` and
/// are read back with conditional casts, defaulting to empty when
/// absent. `fileURL` is stored as a String (`absoluteString`) and
/// parsed back with `URL(string:)`; an unparseable stored string
/// yields `nil` rather than a crash.
public enum ProvisioningProfileMapper {
    public static let entityName = "ProvisioningProfile"

    /// Builds a model from a managed object, or `nil` when the row
    /// has no `id` (a corrupt row is dropped by the caller's
    /// `compactMap`, never thrown).
    public static func toModel(_ object: NSManagedObject) -> ProvisioningModel? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        let fileURLString = object.value(forKey: "fileURL") as? String
        return ProvisioningModel(
            id: id,
            name: object.value(forKey: "name") as? String ?? "",
            uuid: object.value(forKey: "uuid") as? String ?? "",
            appIdentifier: object.value(forKey: "appIdentifier") as? String ?? "",
            teamIdentifier: object.value(forKey: "teamIdentifier") as? String ?? "",
            teamName: object.value(forKey: "teamName") as? String,
            kind: ProvisioningKind(rawValue: object.value(forKey: "kind") as? String ?? "") ?? .unknown,
            expirationDate: object.value(forKey: "expirationDate") as? Date,
            creationDate: object.value(forKey: "creationDate") as? Date,
            bundleIdentifierPrefixes: object.value(forKey: "bundleIdentifierPrefixes") as? [String] ?? [],
            platform: object.value(forKey: "platform") as? String,
            dataHash: object.value(forKey: "dataHash") as? String ?? "",
            entitlements: object.value(forKey: "entitlements") as? [String: String] ?? [:],
            provisionedDevices: object.value(forKey: "provisionedDevices") as? [String] ?? [],
            certificates: object.value(forKey: "certificates") as? [String] ?? [],
            fileURL: fileURLString.flatMap(URL.init(string:)),
            importedAt: object.value(forKey: "importedAt") as? Date ?? Date()
        )
    }

    /// Writes every model field into an existing managed object
    /// (inserted or fetched by the repository).
    public static func apply(_ model: ProvisioningModel, to object: NSManagedObject) {
        object.setValue(model.id, forKey: "id")
        object.setValue(model.name, forKey: "name")
        object.setValue(model.uuid, forKey: "uuid")
        object.setValue(model.appIdentifier, forKey: "appIdentifier")
        object.setValue(model.teamIdentifier, forKey: "teamIdentifier")
        object.setValue(model.teamName, forKey: "teamName")
        object.setValue(model.kind.rawValue, forKey: "kind")
        object.setValue(model.expirationDate, forKey: "expirationDate")
        object.setValue(model.creationDate, forKey: "creationDate")
        object.setValue(model.bundleIdentifierPrefixes, forKey: "bundleIdentifierPrefixes")
        object.setValue(model.platform, forKey: "platform")
        object.setValue(model.dataHash, forKey: "dataHash")
        object.setValue(model.entitlements, forKey: "entitlements")
        object.setValue(model.provisionedDevices, forKey: "provisionedDevices")
        object.setValue(model.certificates, forKey: "certificates")
        object.setValue(model.fileURL?.absoluteString, forKey: "fileURL")
        object.setValue(model.importedAt, forKey: "importedAt")
    }
}
