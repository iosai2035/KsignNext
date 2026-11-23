import Foundation

/// Outcome of a signing operation. A result is only ever produced
/// after signing, verification (when requested) and a real output file
/// all exist — never a success message without a file.
public struct SigningResult: Codable, Equatable, Identifiable {
    public let id: UUID
    public var operationID: UUID
    public var importedIPAID: UUID
    public var signedFileURL: URL
    public var bundleIdentifier: String
    public var version: String
    public var certificateID: UUID?
    public var certificateFingerprint: String?
    public var teamIdentifier: String?
    public var signatureStatus: SignatureStatus
    public var verified: Bool
    public var fileSize: Int64
    public var signedAt: Date
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        operationID: UUID,
        importedIPAID: UUID,
        signedFileURL: URL,
        bundleIdentifier: String,
        version: String,
        certificateID: UUID? = nil,
        certificateFingerprint: String? = nil,
        teamIdentifier: String? = nil,
        signatureStatus: SignatureStatus = .signed,
        verified: Bool = false,
        fileSize: Int64 = 0,
        signedAt: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.operationID = operationID
        self.importedIPAID = importedIPAID
        self.signedFileURL = signedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.certificateID = certificateID
        self.certificateFingerprint = certificateFingerprint
        self.teamIdentifier = teamIdentifier
        self.signatureStatus = signatureStatus
        self.verified = verified
        self.fileSize = fileSize
        self.signedAt = signedAt
        self.duration = duration
    }
}
