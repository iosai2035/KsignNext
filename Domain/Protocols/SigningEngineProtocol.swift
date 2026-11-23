import Foundation

/// Signs an IPA with a P12 certificate + provisioning profile (or
/// ad-hoc where the environment allows). The signing backend is
/// reached only through this protocol; the concrete adapter (zsign)
/// is another builder's job.
public protocol SigningEngineProtocol: AnyObject, Sendable {
    /// Creates a disposable workspace for the operation.
    func prepare(_ request: SigningRequest) async throws -> SigningWorkspace

    /// Validates the request against the certificate, provisioning
    /// profile and IPA (bundle/team matching, entitlements, arch).
    /// Throws `SigningError` / `CertificateError` on mismatch.
    func validate(_ request: SigningRequest, workspace: SigningWorkspace) async throws

    /// Runs the full signing pipeline, emitting progress events.
    /// The returned stream ends with a `.completed` event; a failure
    /// throws instead of emitting a success event.
    func sign(_ request: SigningRequest) -> AsyncStream<SigningProgress>

    /// Verifies a signed IPA and returns `true` only if the signature
    /// is valid for the given bundle identifier.
    func verify(_ signedURL: URL, bundleIdentifier: String) async throws -> Bool

    /// Cancels the in-flight operation with `operationID`, if any.
    func cancel(operationID: UUID) async

    /// Deletes the workspace for `operationID` (called on success and
    /// on failure; must be safe to call twice).
    func cleanup(operationID: UUID) async
}
