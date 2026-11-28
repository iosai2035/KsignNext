import Foundation

/// One signing operation: the input IPA, where the signed IPA goes,
/// and the options. The output URL is computed by the use case in the
/// `Signed/` folder before the engine runs, so a failed operation
/// never leaves a half-written file at the output path.
public struct SigningRequest: Sendable {
    public let operationID: UUID
    public let sourceURL: URL
    public let outputURL: URL
    public let configuration: SigningConfiguration

    public init(operationID: UUID = UUID(), sourceURL: URL, outputURL: URL, configuration: SigningConfiguration) {
        self.operationID = operationID
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.configuration = configuration
    }
}

/// Pipeline stages reported to the UI. `failed` / `cancelled` are
/// terminal progress states, but they are NOT success signals: the
/// engine's `sign` also throws the typed error, and the use case
/// only returns a result when the signed IPA file is proven to exist.
public enum SigningStage: String, Sendable, Equatable {
    case preparing, validating, removingSignature, injecting, signing, verifying, packaging
    case completed, failed, cancelled
}

/// One progress update. `progress` is 0...1.
public struct SigningProgress: Sendable, Equatable {
    public let operationID: UUID
    public let stage: SigningStage
    public let progress: Double
    public let message: String

    public init(operationID: UUID, stage: SigningStage, progress: Double, message: String) {
        self.operationID = operationID
        self.stage = stage
        self.progress = progress
        self.message = message
    }
}

/// The result of a successful sign. Returned ONLY after the output
/// file exists, is non-empty, and (when enabled) passes structural
/// verification — success is never reported before that.
public struct SignedResult: Sendable, Equatable {
    public let outputURL: URL
    public let sha256: String
    public let sizeBytes: Int64
    public let bundleIdentifier: String
    public let duration: TimeInterval

    public init(outputURL: URL, sha256: String, sizeBytes: Int64, bundleIdentifier: String, duration: TimeInterval) {
        self.outputURL = outputURL
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.bundleIdentifier = bundleIdentifier
        self.duration = duration
    }
}

/// What `IPAEngine.inspect` learned about an IPA without signing it.
public struct AppInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String
    public let build: String
    public let executableName: String
    public let appName: String
    public let architectures: [MachOArchitecture]
    public let hasCodeSignature: Bool

    public init(bundleIdentifier: String, displayName: String, version: String, build: String,
                executableName: String, appName: String, architectures: [MachOArchitecture],
                hasCodeSignature: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.build = build
        self.executableName = executableName
        self.appName = appName
        self.architectures = architectures
        self.hasCodeSignature = hasCodeSignature
    }
}

/// The outcome of structural verification. `verify` throws ONLY for
/// unreadable input; a structurally unsound app returns `passed ==
/// false` with each failed check named in `failures`, so the caller
/// can report the specific reason instead of a bare "failed".
public struct VerificationReport: Equatable, Sendable {
    public let passed: Bool
    public let failures: [String]

    public init(passed: Bool, failures: [String] = []) {
        self.passed = passed
        self.failures = failures
    }
}
