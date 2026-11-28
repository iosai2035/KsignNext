import Foundation

/// The stored record of one signing operation. A record is written
/// for every attempt: `.succeeded` only when the signed IPA file was
/// proven to exist and pass verification; `.failed` / `.cancelled`
/// otherwise. A failed attempt never leaves a succeeded record.
public enum SigningOperationStatus: String, Codable, CaseIterable, Sendable {
    case running, succeeded, failed, cancelled
}

public struct SigningOperationModel: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var status: SigningOperationStatus
    public var startDate: Date
    public var endDate: Date?
    public var errorMessage: String?
    public var outputPath: String?
    public var outputSHA256: String?
    public var outputSizeBytes: Int64?
    public var bundleIdentifier: String?
    public var certificateID: UUID?
    public var provisioningProfileID: UUID?

    public init(
        id: UUID = UUID(),
        status: SigningOperationStatus = .running,
        startDate: Date = Date(),
        endDate: Date? = nil,
        errorMessage: String? = nil,
        outputPath: String? = nil,
        outputSHA256: String? = nil,
        outputSizeBytes: Int64? = nil,
        bundleIdentifier: String? = nil,
        certificateID: UUID? = nil,
        provisioningProfileID: UUID? = nil
    ) {
        self.id = id
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
        self.errorMessage = errorMessage
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputSizeBytes = outputSizeBytes
        self.bundleIdentifier = bundleIdentifier
        self.certificateID = certificateID
        self.provisioningProfileID = provisioningProfileID
    }
}
