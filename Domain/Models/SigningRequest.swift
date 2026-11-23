import Foundation

public enum SigningStage: String, Codable, CaseIterable {
    case preparing
    case validating
    case removingSignature
    case injecting
    case signing
    case verifying
    case packaging
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// One progress event emitted by the signing engine.
public struct SigningProgress: Codable, Equatable {
    public var operationID: UUID
    public var stage: SigningStage
    public var progress: Double // 0.0...1.0
    public var message: String
    public var timestamp: Date

    public init(operationID: UUID, stage: SigningStage, progress: Double, message: String, timestamp: Date = Date()) {
        self.operationID = operationID
        self.stage = stage
        self.progress = progress
        self.message = message
        self.timestamp = timestamp
    }
}

/// Input to a signing operation. `operationID` is the Operation ID
/// carried into every log entry for this signing run.
public struct SigningRequest: Codable, Equatable, Identifiable {
    public let id: UUID
    public var operationID: UUID { id }
    public var importedIPAID: UUID
    public var sourceURL: URL
    public var configuration: SigningConfiguration
    public var outputFileName: String?

    public init(
        id: UUID = UUID(),
        importedIPAID: UUID,
        sourceURL: URL,
        configuration: SigningConfiguration,
        outputFileName: String? = nil
    ) {
        self.id = id
        self.importedIPAID = importedIPAID
        self.sourceURL = sourceURL
        self.configuration = configuration
        self.outputFileName = outputFileName
    }
}
