import Foundation

/// The per-device TLS identity for the LAN install server. The
/// identity is generated on this device, its private key lives in
/// the Keychain, and it is NEVER shared, bundled, or downloaded.
/// The certificate is self-signed (365 days) and its SHA-256
/// fingerprint is shown to the user for comparison on the other
/// device before the certificate is trusted there.
public struct TLSIdentity: Equatable, Sendable {
    public let certificateDER: Data
    public let fingerprintSHA256: String
    public let notBefore: Date
    public let notAfter: Date
    public let commonName: String
    public let lanIP: String?

    public init(certificateDER: Data, fingerprintSHA256: String, notBefore: Date,
                notAfter: Date, commonName: String, lanIP: String?) {
        self.certificateDER = certificateDER
        self.fingerprintSHA256 = fingerprintSHA256
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.commonName = commonName
        self.lanIP = lanIP
    }
}

public protocol TLSIdentityServiceProtocol: AnyObject, Sendable {
    /// The current identity, generating one on first use (or when the
    /// stored key/cert is missing or expired). Never returns a shared
    /// or bundled identity.
    func currentIdentity() async throws -> TLSIdentity
    /// PKCS#8 DER of the private key, for the TLS server context only.
    /// Held in memory only; never written to disk, never logged.
    func privateKeyPKCS8DER() async throws -> Data
    /// Deletes the stored key and generates a fresh identity. Old
    /// fingerprints and QR codes stop being trustworthy.
    func rotateIdentity() async throws -> TLSIdentity
    /// The stored fingerprint, or nil when no identity exists yet.
    func storedFingerprint() -> String?
}
