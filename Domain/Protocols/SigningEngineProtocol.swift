import Foundation

/// The signing pipeline. Success is reported ONLY by returning a
/// `SignedResult` — and only after the signed IPA file exists, is
/// non-empty, and (when enabled) passes structural verification.
/// Any failure throws the typed error AND reports `.failed` through
/// `progress`; a finished progress stream is never, by itself, a
/// success signal.
public protocol SigningEngineProtocol: AnyObject, Sendable {
    func sign(_ request: SigningRequest,
              progress: @escaping @Sendable (SigningProgress) -> Void) async throws -> SignedResult
    /// Structural verification of a signed IPA (delegates to the
    /// verification engine). Throws only for unreadable input.
    func verify(_ signedURL: URL, bundleIdentifier: String, expectProfile: Bool) async throws -> VerificationReport
    func cancel(operationID: UUID) async
    func cleanup(operationID: UUID) async
}
