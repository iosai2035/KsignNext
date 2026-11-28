import CryptoKit
import Foundation
import Security
import UIKit

/// The per-device TLS identity for the LAN install server. Generated
/// on this device, never shared, bundled, or downloaded: a CryptoKit
/// P-256 key whose 32-byte `rawRepresentation` lives in the Keychain
/// (generic-password item, `AfterFirstUnlockThisDeviceOnly`), and a
/// self-signed X.509 certificate (365 days) whose DER, fingerprint,
/// dates, common name, and LAN IP live in UserDefaults.
///
/// The certificate is validated by parsing it with
/// `SecCertificateCreateWithData` before it is stored or returned —
/// a certificate that does not parse is a generation failure, never
/// a stored identity.
///
/// Known limitation (surfaced in the UI, not hidden): the SAN
/// carries the LAN IP known at generation time. If the device's LAN
/// IP changes, the certificate's SAN no longer matches the install
/// URL — the install screen tells the user to reset the identity.
public final class TLSIdentityService: TLSIdentityServiceProtocol, @unchecked Sendable {
    public static let keychainAccount = "tls-identity-private-key"
    private static let certificateDERKey = "ksign.tlsCertificateDER"
    private static let fingerprintKey = "ksign.tlsFingerprint"
    private static let notBeforeKey = "ksign.tlsNotBefore"
    private static let notAfterKey = "ksign.tlsNotAfter"
    private static let commonNameKey = "ksign.tlsCommonName"
    private static let lanIPKey = "ksign.tlsLanIP"
    public static let validityDays = 365

    private let keychain: KeychainService
    private let defaults: UserDefaults
    private let deviceName: () -> String

    public init(keychain: KeychainService = .shared, defaults: UserDefaults = .standard,
                deviceName: @escaping () -> String = { UIDevice.current.name }) {
        self.keychain = keychain
        self.defaults = defaults
        self.deviceName = deviceName
    }

    // MARK: - Identity

    public func currentIdentity() async throws -> TLSIdentity {
        if let stored = loadStoredIdentity(), stored.notAfter > Date() {
            return stored
        }
        return try await generateIdentity()
    }

    public func privateKeyPKCS8DER() async throws -> Data {
        let raw = try loadPrivateKeyRaw()
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
        return DERBuilder.pkcs8DER(privateKeyRaw: raw,
                                   publicKeyPoint: privateKey.publicKey.rawRepresentation)
    }

    public func rotateIdentity() async throws -> TLSIdentity {
        try? keychain.delete(account: Self.keychainAccount)
        for key in [Self.certificateDERKey, Self.fingerprintKey, Self.notBeforeKey,
                    Self.notAfterKey, Self.commonNameKey, Self.lanIPKey] {
            defaults.removeObject(forKey: key)
        }
        return try await generateIdentity()
    }

    public func storedFingerprint() -> String? {
        defaults.string(forKey: Self.fingerprintKey)
    }

    // MARK: - Generation

    private func generateIdentity() async throws -> TLSIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let raw = privateKey.rawRepresentation // 32 bytes
        do {
            try keychain.save(raw, account: Self.keychainAccount)
        } catch {
            throw mapKeychainError(error)
        }
        let commonName = deviceName()
        let lanIP = Self.lanIPv4Address()
        let notBefore = Date()
        let notAfter = Calendar.current.date(byAdding: .day, value: Self.validityDays, to: notBefore) ?? notBefore.addingTimeInterval(365 * 24 * 3600)
        var serialBytes = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        serialBytes[0] &= 0x7F // clear the high bit (DER INTEGER stays non-negative)
        let publicPoint = privateKey.publicKey.rawRepresentation // 65 bytes, 0x04 || X || Y
        let tbs = DERBuilder.tbsCertificate(commonName: commonName, serial: serialBytes, notBefore: notBefore,
                                            notAfter: notAfter, publicKeyPoint: publicPoint, lanIP: lanIP)
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try privateKey.signature(for: tbs)
        } catch {
            throw AppError.certificate(.keychainFailure(reason: "The TLS identity could not be signed: \(error.localizedDescription)"))
        }
        let certificateDER = DERBuilder.buildCertificate(
            commonName: commonName, serial: serialBytes, notBefore: notBefore, notAfter: notAfter,
            publicKeyPoint: publicPoint, lanIP: lanIP, signatureDER: signature.derRepresentation)
        // A certificate that does not parse is a generation failure,
        // never a stored identity.
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw AppError.certificate(.invalidFormat(reason: "The generated TLS certificate does not parse."))
        }
        let fingerprint = sha256Hex(certificateDER)
        defaults.set(certificateDER, forKey: Self.certificateDERKey)
        defaults.set(fingerprint, forKey: Self.fingerprintKey)
        defaults.set(notBefore, forKey: Self.notBeforeKey)
        defaults.set(notAfter, forKey: Self.notAfterKey)
        defaults.set(commonName, forKey: Self.commonNameKey)
        if let lanIP { defaults.set(lanIP, forKey: Self.lanIPKey) } else { defaults.removeObject(forKey: Self.lanIPKey) }
        return TLSIdentity(certificateDER: certificateDER, fingerprintSHA256: fingerprint,
                           notBefore: notBefore, notAfter: notAfter, commonName: commonName, lanIP: lanIP)
    }

    private func loadStoredIdentity() -> TLSIdentity? {
        guard let der = defaults.data(forKey: Self.certificateDERKey),
              let fingerprint = defaults.string(forKey: Self.fingerprintKey),
              let notBefore = defaults.object(forKey: Self.notBeforeKey) as? Date,
              let notAfter = defaults.object(forKey: Self.notAfterKey) as? Date,
              let commonName = defaults.string(forKey: Self.commonNameKey) else { return nil }
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else { return nil }
        guard sha256Hex(der) == fingerprint else { return nil }
        // The stored private key must still exist; without it the
        // identity cannot serve TLS, so it is regenerated.
        guard (try? loadPrivateKeyRaw()) != nil else { return nil }
        return TLSIdentity(certificateDER: der, fingerprintSHA256: fingerprint, notBefore: notBefore,
                           notAfter: notAfter, commonName: commonName,
                           lanIP: defaults.string(forKey: Self.lanIPKey))
    }

    private func loadPrivateKeyRaw() throws -> Data {
        do {
            guard let raw = try keychain.read(account: Self.keychainAccount) else {
                throw AppError.certificate(.missingPrivateKey)
            }
            guard raw.count == 32 else {
                throw AppError.certificate(.invalidFormat(reason: "The stored TLS private key is not 32 bytes."))
            }
            return raw
        } catch let error as AppError {
            throw error
        } catch {
            throw mapKeychainError(error)
        }
    }

    private func mapKeychainError(_ error: Error) -> AppError {
        if let certificateError = error as? CertificateError {
            return AppError.certificate(certificateError)
        }
        return AppError.certificate(.keychainFailure(reason: error.localizedDescription))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - LAN address

    /// The device's LAN IPv4 address (Wi-Fi `en0` first, then any
    /// up, non-loopback IPv4 interface), or nil when there is none
    /// (no Wi-Fi — installing on another device is impossible then).
    public static func lanIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
