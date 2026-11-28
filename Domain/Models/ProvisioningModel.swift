import Foundation

/// A parsed `.mobileprovision` profile. The raw profile bytes live on
/// disk as a file (`fileURL`); they are never duplicated into
/// Core Data. `dataHash` is the SHA-256 hex of those raw bytes.
/// `entitlements` are flattened display strings; `certificates` are
/// base64 DER blobs of the certificates embedded in the profile.
public struct ProvisioningModel: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var uuid: String
    public var appIdentifier: String
    public var teamIdentifier: String
    public var teamName: String?
    public var kind: ProvisioningKind
    public var expirationDate: Date?
    public var creationDate: Date?
    /// App ID bundle prefixes this profile covers. In Phase 1 this is
    /// `[bundleIdentifier]` (a single App ID); later phases may add
    /// more entries.
    public var bundleIdentifierPrefixes: [String]
    /// Platform the profile targets. `nil` in Phase 1 — profiles
    /// carry no explicit platform field; later phases fill it.
    public var platform: String?
    public var dataHash: String
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
        bundleIdentifierPrefixes: [String] = [],
        platform: String? = nil,
        dataHash: String = "",
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
        self.bundleIdentifierPrefixes = bundleIdentifierPrefixes
        self.platform = platform
        self.dataHash = dataHash
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

    /// Whole calendar days from now until expiry; `nil` when no
    /// expiration date is known. Negative when already expired.
    public var daysUntilExpiration: Int? {
        guard let expirationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day
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
    ///
    /// - `"*"` allows any bundle ID.
    /// - `"com.example.*"` allows `"com.example.foo"` but NOT
    ///   `"com.exampleFoo"` and NOT `"com.example"` itself — the
    ///   wildcard needs a real sub-identifier after the prefix dot.
    /// - Anything else must match exactly.
    public func allows(bundleID: String) -> Bool {
        let allowed = bundleIdentifier
        if allowed == "*" { return true }
        if allowed.hasSuffix(".*") {
            let prefix = String(allowed.dropLast(2))
            return bundleID.hasPrefix(prefix + ".")
        }
        return allowed == bundleID
    }

    /// `true` when `deviceUDID` is listed in `provisionedDevices`
    /// (exact match, nothing else). An App Store profile lists no
    /// devices and therefore covers no pasted UDID by list; its
    /// "covers any device" nature is a UI statement, not a `true`
    /// from this function.
    public func deviceIsProvisioned(_ deviceUDID: String) -> Bool {
        provisionedDevices.contains(deviceUDID)
    }
}
