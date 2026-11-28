import Foundation

/// Current state of a signing certificate.
///
/// `.revoked` exists for completeness but is never produced by
/// `CertificateEngine.status(of:)` — there is no OCSP/CRL check in
/// Phase 1, so a certificate is never reported as revoked.
public enum CertificateStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case expired
    case revoked
    case invalid
    case mismatched
    case unknown
}

/// Kind of a signing certificate, derived from the subject common name
/// by the certificate engine.
public enum CertificateKind: String, Codable, CaseIterable, Sendable {
    case developer
    case distribution
    case development
    case adhoc
    case unknown
}
