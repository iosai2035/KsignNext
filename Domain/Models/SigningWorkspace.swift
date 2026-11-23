import Foundation

/// A disposable working directory for one signing operation: the IPA
/// is extracted here, modified, re-signed and re-packaged. The
/// workspace is deleted by `cleanup()` when the operation ends,
/// whether it succeeded or failed.
public struct SigningWorkspace: Equatable, Identifiable {
    public let id: UUID
    public var operationID: UUID
    public var rootURL: URL
    public var extractedAppURL: URL?
    public var createdAt: Date

    public init(id: UUID = UUID(), operationID: UUID, rootURL: URL, extractedAppURL: URL? = nil, createdAt: Date = Date()) {
        self.id = id
        self.operationID = operationID
        self.rootURL = rootURL
        self.extractedAppURL = extractedAppURL
        self.createdAt = createdAt
    }

    public var payloadURL: URL { rootURL.appendingPathComponent("Payload", isDirectory: true) }
    public var outputURL: URL { rootURL.appendingPathComponent("output.ipa") }

    public func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
