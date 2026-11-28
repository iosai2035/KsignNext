import Foundation

/// Post-sign structural verification. Throws ONLY for unreadable
/// input (missing file, not a ZIP, extraction failure). A
/// structurally unsound app returns `passed == false` with each
/// failed check named in `failures`.
///
/// Honest limit: this proves the signature artefacts are present and
/// consistent — NOT that Apple cryptographically signed anything.
/// A pass means "structurally sound".
public protocol VerificationEngineProtocol: AnyObject, Sendable {
    func verify(signedIPAURL: URL, expectedBundleIdentifier: String, expectProfile: Bool) async throws -> VerificationReport
}
