import Foundation

/// Parses `.mobileprovision` profiles (a PKCS#7/CMS envelope wrapping
/// an XML plist) and answers coverage questions about them.
///
/// The pure coverage logic also lives on `ProvisioningModel`
/// (`allows(bundleID:)`, `deviceIsProvisioned(_:)`); the engine
/// methods below delegate to the model.
public protocol ProvisioningEngineProtocol: AnyObject, Sendable {
    /// Parses a `.mobileprovision` file into a `ProvisioningModel`.
    /// Parsing alone does NOT reject an expired profile — only
    /// import does.
    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel

    /// Imports a profile into the workspace: parse → reject an
    /// already-expired profile with
    /// `AppError.certificate(.provisioningExpired)` BEFORE any file
    /// copy → atomic copy into `Certificates/` as
    /// `<base>-<id>.mobileprovision` → set `fileURL` and `dataHash`
    /// (SHA-256 of the raw file bytes).
    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel

    /// Throws unless `certificate` and `profile` belong together
    /// (same team, certificate listed in the profile, neither
    /// expired). Check order: team mismatch → profile expired →
    /// certificate expired → certificate not listed.
    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws

    /// `true` when `bundleID` is covered by the profile's App ID
    /// (exact match or wildcard; see `ProvisioningModel.allows`).
    func allows(bundleID: String, profile: ProvisioningModel) -> Bool

    /// `true` when `deviceUDID` is listed in the profile
    /// (development / ad-hoc profiles only; an App Store profile
    /// lists none and therefore covers no pasted UDID by list).
    func deviceIsProvisioned(_ deviceUDID: String, in profile: ProvisioningModel) -> Bool
}
