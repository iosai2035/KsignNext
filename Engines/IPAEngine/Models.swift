import Foundation

// NOTE (coordinator integration): IPAError, SigningError, AppMetadata,
// ImportedIPA, IPAInspectionReport and IPAEngineProtocol used to be
// defined here as well as in Core/Domain. The Core/Domain definitions
// are canonical now; this file keeps only ExtractedIPA, which is
// unique to the engine layer.

/// The result of extracting an IPA into the workspace.
public struct ExtractedIPA: Identifiable {
    public let id: UUID
    public var importedIPAId: UUID?
    public var sourceURL: URL
    public var extractionDirectory: URL
    public var appBundleURLs: [URL]
    public var primaryAppBundleURL: URL?
    public var metadata: AppMetadata?
    public var extractedAt: Date

    public init(
        id: UUID = UUID(),
        importedIPAId: UUID? = nil,
        sourceURL: URL,
        extractionDirectory: URL,
        appBundleURLs: [URL],
        primaryAppBundleURL: URL? = nil,
        metadata: AppMetadata? = nil,
        extractedAt: Date = Date()
    ) {
        self.id = id
        self.importedIPAId = importedIPAId
        self.sourceURL = sourceURL
        self.extractionDirectory = extractionDirectory
        self.appBundleURLs = appBundleURLs
        self.primaryAppBundleURL = primaryAppBundleURL
        self.metadata = metadata
        self.extractedAt = extractedAt
    }
}
