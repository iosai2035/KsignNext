import Foundation

/// Parses and validates certificates (P12/PFX, PEM/DER) and
/// provisioning profiles (.mobileprovision). Passwords are accepted
/// as transient parameters only and stored via `KeychainService`;
/// they are never stored in a model or in Core Data.
///
/// Size limits are enforced inside the engine before parsing or
/// saving: P12/certificate 10 MiB, profile 5 MiB.
public protocol CertificateEngineProtocol: AnyObject, Sendable {
    /// Parses a P12/PFX file. `password` is used only for this call.
    /// A password-less P12 (`password == ""`) must succeed.
    func parseP12(at url: URL, password: String) async throws -> CertificateModel

    /// Parses a PEM (`-----BEGIN CERTIFICATE-----`) or raw DER
    /// certificate file.
    func parseCertificate(at url: URL) async throws -> CertificateModel

    /// Parses a `.mobileprovision` file. Delegates to the provisioning
    /// engine; there is exactly one implementation of profile parsing.
    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel

    /// Checks that `certificate` and `profile` belong together
    /// (team identifier, certificate fingerprint listed in the
    /// profile, neither expired). A `nil` expiration date means "no
    /// expiry known" and is not an error. Bundle-ID and device
    /// coverage are signing-time checks and are not part of this
    /// validation.
    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws

    /// Returns the current status (valid / expired / invalid /
    /// unknown). `.revoked` is never returned — there is no OCSP/CRL
    /// check. A future `notBefore` yields `.invalid`, not
    /// `.notYetValid`.
    func status(of certificate: CertificateModel) async -> CertificateStatus

    /// Reads the stored P12 password for `certificate` from the
    /// Keychain, or `nil` when no password is stored.
    func storedPassword(for certificate: CertificateModel) throws -> String?

    /// Imports a P12 into the workspace + Keychain and returns the
    /// stored model: parse → atomic copy into `Certificates/` as
    /// `<base>-<id>.p12` → save the password in the Keychain under
    /// `passwordAccount(for: model.id)` — always, even for a
    /// password-less P12, whose empty password is saved as `""` and
    /// whose record is registered like any other. On Keychain
    /// failure the copied file is deleted and the error is thrown,
    /// leaving no orphan file.
    func importP12(at url: URL, password: String) async throws -> CertificateModel

    /// Imports a provisioning profile into the workspace: parse →
    /// reject an already-expired profile before any file copy →
    /// atomic copy into `Certificates/` as
    /// `<base>-<id>.mobileprovision`.
    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel

    /// The Keychain account holding a certificate's P12 password.
    static func passwordAccount(for id: UUID) -> String
}
