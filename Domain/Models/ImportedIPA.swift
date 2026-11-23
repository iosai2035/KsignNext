import Foundation

public enum SignatureStatus: String, Codable, CaseIterable {
    case unsigned
    case signed
    case verified
    case failed
    case expired
    case unknown
}

/// An IPA the user imported into the workspace. `fileURL` is a path
/// inside the workspace (see `SecureFileManager`); never an arbitrary
/// user path stored raw.
///
/// Unified by the coordinator: the Domain definition plus
/// `minimumOSVersion` and `originalURL` from the engine definition.
public struct ImportedIPA: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var bundleIdentifier: String
    public var version: String
    public var buildVersion: String
    public var minimumOSVersion: String?
    public var fileSize: Int64
    public var importedAt: Date
    public var fileURL: URL
    public var originalURL: URL?
    public var iconData: Data?
    public var architecture: String
    public var signatureStatus: SignatureStatus
    public var metadata: AppMetadata?

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        buildVersion: String,
        minimumOSVersion: String? = nil,
        fileSize: Int64,
        importedAt: Date = Date(),
        fileURL: URL,
        originalURL: URL? = nil,
        iconData: Data? = nil,
        architecture: String = "arm64",
        signatureStatus: SignatureStatus = .unknown,
        metadata: AppMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.fileURL = fileURL
        self.originalURL = originalURL
        self.iconData = iconData
        self.architecture = architecture
        self.signatureStatus = signatureStatus
        self.metadata = metadata
    }
}
