import Foundation

/// Parses and validates certificates (P12/PFX, PEM/DER) and
/// provisioning profiles (.mobileprovision). Passwords are accepted
/// as transient parameters only and stored via `KeychainService`;
/// they are never stored in a model or in Core Data.
public protocol CertificateEngineProtocol: AnyObject, Sendable {
    /// Parses a P12/PFX file. `password` is used only for this call.
    func parseP12(at url: URL, password: String) async throws -> CertificateModel

    /// Parses a PEM/DER certificate file.
    func parseCertificate(at url: URL) async throws -> CertificateModel

    /// Parses a .mobileprovision file.
    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel

    /// Checks that `certificate` and `profile` belong together
    /// (team identifier, certificate fingerprint in the profile).
    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws

    /// Returns the current status (valid / expired / revoked / ...).
    /// Revoked is reported only after a reliable check; otherwise
    /// `.unknown` is returned rather than a false revocation.
    func status(of certificate: CertificateModel) async -> CertificateStatus

    /// Imports a P12 into the workspace + Keychain and returns the
    /// stored model. The password is stored in the Keychain under an
    /// account derived from the returned model's id.
    func importP12(at url: URL, password: String) async throws -> CertificateModel

    /// Imports a provisioning profile into the workspace.
    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel
}
