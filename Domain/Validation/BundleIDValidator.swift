import Foundation

/// Domain validation for bundle identifiers, returning typed errors
/// (not bare booleans) so the UI can show the exact problem.
public enum BundleIDValidator {
    public static func validate(_ value: String) throws {
        guard Validators.isNonEmpty(value) else {
            throw AppError.validation(.emptyValue(field: "Bundle Identifier"))
        }
        guard Validators.isValidBundleIdentifier(value) else {
            throw AppError.validation(.invalidBundleIdentifier(value))
        }
    }

    public static func isValid(_ value: String) -> Bool {
        Validators.isValidBundleIdentifier(value)
    }

    /// Checks a provisioning profile's App ID against a bundle ID,
    /// honouring wildcards (`*` and `com.example.*`).
    public static func profile(_ profile: ProvisioningModel, allows bundleID: String) throws {
        guard profile.allows(bundleID: bundleID) else {
            throw AppError.signing(.bundleIdentifierMismatch(expected: profile.bundleIdentifier, found: bundleID))
        }
    }

    /// Checks that the certificate's team matches the profile's team.
    public static func team(certificate: CertificateModel, profile: ProvisioningModel) throws {
        guard let team = certificate.teamIdentifier else {
            throw AppError.signing(.invalidCertificate(reason: "The certificate has no team identifier."))
        }
        guard team == profile.teamIdentifier else {
            throw AppError.signing(.teamIdentifierMismatch(expected: profile.teamIdentifier, found: team))
        }
    }
}
