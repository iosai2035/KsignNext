import Foundation

/// Post-signing verification: asks the signing engine to verify a
/// signed IPA and returns a plain result for the UI. A `false` result
/// is a verification failure, not a crash — it is reported as a typed
/// error only when the caller asks for `throwOnFailure`.
public final class VerifySignatureUseCase {
    private let signingEngine: SigningEngineProtocol
    private let logs: LogsManager

    public init(signingEngine: SigningEngineProtocol, logs: LogsManager = .shared) {
        self.signingEngine = signingEngine
        self.logs = logs
    }

    public struct VerificationOutcome: Equatable {
        public var isValid: Bool
        public var bundleIdentifier: String
        public var checkedAt: Date

        public init(isValid: Bool, bundleIdentifier: String, checkedAt: Date = Date()) {
            self.isValid = isValid
            self.bundleIdentifier = bundleIdentifier
            self.checkedAt = checkedAt
        }
    }

    public func execute(signedURL: URL, bundleIdentifier: String, throwOnFailure: Bool = false) async throws -> VerificationOutcome {
        let operationID = UUID()
        await logs.info("Verifying signature for \(bundleIdentifier)", operationID: operationID)
        let isValid = try await signingEngine.verify(signedURL, bundleIdentifier: bundleIdentifier)
        if !isValid {
            await logs.error("Signature verification failed for \(bundleIdentifier)", operationID: operationID)
            if throwOnFailure {
                throw AppError.signing(.verificationFailed(reason: "The signature of \(bundleIdentifier) is not valid."))
            }
        } else {
            await logs.info("Signature verified for \(bundleIdentifier)", operationID: operationID)
        }
        return VerificationOutcome(isValid: isValid, bundleIdentifier: bundleIdentifier)
    }
}
