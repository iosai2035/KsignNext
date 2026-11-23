import Foundation

/// JSON transfer object for an imported app (source feeds, export,
/// and cross-process sharing). Never carries file contents or secrets.
public struct AppDTO: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var bundleIdentifier: String
    public var version: String
    public var buildVersion: String
    public var fileSize: Int64
    public var importedAt: Date
    public var architecture: String
    public var signatureStatus: String

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        buildVersion: String,
        fileSize: Int64 = 0,
        importedAt: Date = Date(),
        architecture: String = "arm64",
        signatureStatus: String = SignatureStatus.unknown.rawValue
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildVersion = buildVersion
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.architecture = architecture
        self.signatureStatus = signatureStatus
    }

    public init(from application: ImportedIPA) {
        self.init(
            id: application.id,
            name: application.name,
            bundleIdentifier: application.bundleIdentifier,
            version: application.version,
            buildVersion: application.buildVersion,
            fileSize: application.fileSize,
            importedAt: application.importedAt,
            architecture: application.architecture,
            signatureStatus: application.signatureStatus.rawValue
        )
    }

    public init(from metadata: AppMetadata) {
        self.init(
            id: metadata.id,
            name: metadata.name,
            bundleIdentifier: metadata.bundleIdentifier,
            version: metadata.version,
            buildVersion: metadata.buildVersion,
            architecture: metadata.architectures.first ?? "arm64"
        )
    }

    /// Rebuilds the domain model; `fileURL` must be supplied by the
    /// caller because a DTO never carries a local filesystem path.
    public func toImportedIPA(fileURL: URL) -> ImportedIPA {
        ImportedIPA(
            id: id,
            name: name,
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildVersion: buildVersion,
            fileSize: fileSize,
            importedAt: importedAt,
            fileURL: fileURL,
            architecture: architecture,
            signatureStatus: SignatureStatus(rawValue: signatureStatus) ?? .unknown
        )
    }
}
