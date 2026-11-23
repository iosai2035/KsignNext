import Foundation

public enum ProvisioningKind: String, Codable, CaseIterable {
    case development
    case adhoc
    case appStore
    case enterprise
    case unknown
}

/// A parsed .mobileprovision profile. `entitlements` are the raw
/// plist values (strings/bools/arrays encoded as strings for display);
/// the structured form lives in `EntitlementsModel`.
public struct ProvisioningModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var uuid: String
    public var appIdentifier: String
    public var teamIdentifier: String
    public var teamName: String?
    public var kind: ProvisioningKind
    public var expirationDate: Date?
    public var creationDate: Date?
    public var entitlements: [String: String]
    public var provisionedDevices: [String]
    public var certificates: [String]
    public var fileURL: URL?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        uuid: String,
        appIdentifier: String,
        teamIdentifier: String,
        teamName: String? = nil,
        kind: ProvisioningKind = .unknown,
        expirationDate: Date? = nil,
        creationDate: Date? = nil,
        entitlements: [String: String] = [:],
        provisionedDevices: [String] = [],
        certificates: [String] = [],
        fileURL: URL? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.appIdentifier = appIdentifier
        self.teamIdentifier = teamIdentifier
        self.teamName = teamName
        self.kind = kind
        self.expirationDate = expirationDate
        self.creationDate = creationDate
        self.entitlements = entitlements
        self.provisionedDevices = provisionedDevices
        self.certificates = certificates
        self.fileURL = fileURL
        self.importedAt = importedAt
    }

    public var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }

    /// The bundle identifier part of the App ID (after the team prefix).
    public var bundleIdentifier: String {
        let prefix = teamIdentifier + "."
        if appIdentifier.hasPrefix(prefix) {
            return String(appIdentifier.dropFirst(prefix.count))
        }
        return appIdentifier
    }

    /// `true` when the profile's App ID allows `bundleID`
    /// (exact match or wildcard `*`).
    public func allows(bundleID: String) -> Bool {
        let allowed = bundleIdentifier
        if allowed == "*" { return true }
        if allowed.hasSuffix(".*") {
            let prefix = String(allowed.dropLast(2))
            return bundleID.hasPrefix(prefix)
        }
        return allowed == bundleID
    }
}
