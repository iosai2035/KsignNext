import Foundation
import Security
import CryptoKit

/// Parses and validates signing certificates (P12/PFX, PEM/DER).
///
/// Passwords are transient call parameters only: they are never stored in
/// a model or in plaintext anywhere. `importP12` stores the password in
/// the Keychain (via `KeychainService`) under an account derived from the
/// imported model's id, and records only that account name in the model.
///
/// Revocation: no OCSP/CRL check is performed here, so this engine NEVER
/// reports `.revoked`. A certificate whose validity cannot be confirmed
/// is reported as `.unknown` rather than falsely revoked.
public final class CertificateEngine: CertificateEngineProtocol, @unchecked Sendable {

    private let keychain: KeychainService
    private let fileManager: SecureFileManager

    /// Maximum P12 / certificate file size accepted (10 MiB).
    private static let maxCertificateBytes = 10 * 1024 * 1024

    public init(
        keychain: KeychainService = .shared,
        fileManager: SecureFileManager = .shared
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
    }

    // MARK: - CertificateEngineProtocol

    public func parseP12(at url: URL, password: String) async throws -> CertificateModel {
        let data = try readFile(at: url, limit: Self.maxCertificateBytes)
        let identity = try importIdentity(from: data, password: password)
        guard let certificate = try certificate(of: identity) else {
            throw AppError.certificate(.invalidFormat(reason: "The P12 file contains no certificate."))
        }
        return try await model(from: certificate, name: url.deletingPathExtension().lastPathComponent, fileURL: url)
    }

    public func parseCertificate(at url: URL) async throws -> CertificateModel {
        let data = try readFile(at: url, limit: Self.maxCertificateBytes)
        let derData = try derData(from: data, sourceURL: url)
        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw AppError.certificate(.invalidFormat(reason: "The data is not a valid DER or PEM certificate."))
        }
        return try await model(from: certificate, name: url.deletingPathExtension().lastPathComponent, fileURL: url)
    }

    public func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        // Provisioning parsing lives in ProvisioningEngine; delegate so
        // there is exactly one implementation of the plist extraction.
        try await ProvisioningEngine(keychain: keychain, fileManager: fileManager)
            .parseProvisioningProfile(at: url)
    }

    public func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws {
        if let certTeam = certificate.teamIdentifier, !certTeam.isEmpty,
           certTeam != profile.teamIdentifier {
            throw AppError.certificate(.provisioningMismatch(
                reason: "The certificate belongs to team “\(certTeam)” but the profile belongs to team “\(profile.teamIdentifier)”."
            ))
        }
        if let expiration = profile.expirationDate, expiration < Date() {
            throw AppError.certificate(.provisioningExpired(expirationDate: expiration))
        }
        if let expiration = certificate.expirationDate, expiration < Date() {
            throw AppError.certificate(.expired(expirationDate: expiration))
        }
        if !profile.certificates.isEmpty {
            let matches = profile.certificates.contains { base64DER in
                guard let der = Data(base64Encoded: base64DER) else { return false }
                return sha256Hex(of: der) == certificate.fingerprint
            }
            if !matches {
                throw AppError.certificate(.provisioningMismatch(
                    reason: "The certificate is not listed in the provisioning profile."
                ))
            }
        }
    }

    public func status(of certificate: CertificateModel) async -> CertificateStatus {
        if certificate.fingerprint.isEmpty { return .invalid }
        if let notBefore = certificate.notBefore, notBefore > Date() { return .invalid }
        if let expiration = certificate.expirationDate {
            if expiration < Date() { return .expired }
        } else {
            return .unknown
        }
        // No revocation check is performed: `.revoked` is never returned
        // here, so a valid, unexpired certificate is `.valid`.
        return .valid
    }

    public func importP12(at url: URL, password: String) async throws -> CertificateModel {
        var model = try await parseP12(at: url, password: password)
        let destination = try storedCertificateURL(fileName: url.lastPathComponent, id: model.id)
        let data = try readFile(at: url, limit: Self.maxCertificateBytes)
        do {
            try fileManager.writeAtomically(data, to: destination)
        } catch {
            throw AppError.certificate(.keychainFailure(reason: "The certificate could not be copied into the workspace: \(error.localizedDescription)"))
        }
        let account = Self.passwordAccount(for: model.id)
        do {
            try keychain.savePassword(password, account: account)
        } catch {
            // Do not leave an orphaned file behind if the secret cannot be stored.
            try? FileManager.default.removeItem(at: destination)
            throw AppError.certificate(.keychainFailure(reason: error.localizedDescription))
        }
        model.fileURL = destination
        model.keychainAccount = account
        model.status = await status(of: model)
        return model
    }

    public func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        try await ProvisioningEngine(keychain: keychain, fileManager: fileManager)
            .importProvisioningProfile(at: url)
    }

    // MARK: - Keychain helpers

    /// Keychain account holding the P12 password for a certificate id.
    public static func passwordAccount(for id: UUID) -> String {
        "p12-password-\(id.uuidString)"
    }

    /// The stored P12 password for a previously imported certificate, if any.
    public func storedPassword(for certificate: CertificateModel) throws -> String? {
        guard let account = certificate.keychainAccount else { return nil }
        return try keychain.readPassword(account: account)
    }

    // MARK: - P12 import

    private func importIdentity(from data: Data, password: String) throws -> SecIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed {
                throw AppError.certificate(.wrongPassword)
            }
            throw AppError.certificate(.invalidFormat(reason: keychainMessage(for: status)))
        }
        guard let imported = items as? [[String: Any]], let first = imported.first else {
            throw AppError.certificate(.invalidFormat(reason: "The P12 file is empty."))
        }
        guard let identity = first[kSecImportItemIdentity as String] as? SecIdentity else {
            throw AppError.certificate(.missingPrivateKey)
        }
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, privateKey != nil else {
            throw AppError.certificate(.missingPrivateKey)
        }
        return identity
    }

    private func certificate(of identity: SecIdentity) throws -> SecCertificate? {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess else {
            throw AppError.certificate(.invalidFormat(reason: keychainMessage(for: status)))
        }
        return certificate
    }

    // MARK: - Certificate parsing

    private func model(from certificate: SecCertificate, name: String, fileURL: URL?) async throws -> CertificateModel {
        let derData = SecCertificateCopyData(certificate) as Data
        let fingerprint = sha256Hex(of: derData)
        let values = certificateValues(certificate)

        let commonName = stringValue(for: kSecOIDCommonName, in: values)
            ?? SecCertificateCopySubjectSummary(certificate) as String?
        let teamIdentifier = stringValue(for: kSecOIDOrganizationalUnit, in: values)
        let serial = dataValue(for: kSecOIDX509V1SerialNumber, in: values)
            .map { $0.map { String(format: "%02x", $0) }.joined() }
        let notBefore = dateValue(for: kSecOIDX509V1ValidityNotBefore, in: values)
        let notAfter = dateValue(for: kSecOIDX509V1ValidityNotAfter, in: values)
        let issuer = issuerName(from: values)

        var model = CertificateModel(
            name: name.isEmpty ? (commonName ?? "Certificate") : name,
            commonName: commonName,
            issuer: issuer,
            serialNumber: serial,
            fingerprint: fingerprint,
            teamIdentifier: teamIdentifier,
            kind: kind(forCommonName: commonName),
            notBefore: notBefore,
            expirationDate: notAfter,
            fileURL: fileURL
        )
        model.status = await status(of: model)
        return model
    }

    /// `SecCertificateCopyValues` result, keyed by OID string.
    private func certificateValues(_ certificate: SecCertificate) -> [String: [String: Any]] {
        let keys: [CFString] = [
            kSecOIDCommonName,
            kSecOIDOrganizationalUnit,
            kSecOIDX509V1SerialNumber,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
            kSecOIDX509V1IssuerName
        ]
        guard let raw = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: [String: Any]] else {
            return [:]
        }
        return raw
    }

    private func valueDictionary(for oid: CFString, in values: [String: [String: Any]]) -> [String: Any]? {
        values[oid as String]
    }

    private func stringValue(for oid: CFString, in values: [String: [String: Any]]) -> String? {
        valueDictionary(for: oid, in: values)?[kSecPropertyKeyValue as String] as? String
    }

    private func dataValue(for oid: CFString, in values: [String: [String: Any]]) -> Data? {
        valueDictionary(for: oid, in: values)?[kSecPropertyKeyValue as String] as? Data
    }

    private func dateValue(for oid: CFString, in values: [String: [String: Any]]) -> Date? {
        valueDictionary(for: oid, in: values)?[kSecPropertyKeyValue as String] as? Date
    }

    /// Builds a readable issuer string ("CN=…, O=…") from the issuer RDN list.
    private func issuerName(from values: [String: [String: Any]]) -> String? {
        guard let rdns = valueDictionary(for: kSecOIDX509V1IssuerName, in: values)?[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return nil
        }
        let parts = rdns.compactMap { rdn -> String? in
            guard let label = rdn[kSecPropertyKeyLabel as String] as? String,
                  let value = rdn[kSecPropertyKeyValue as String] as? String else { return nil }
            return "\(label)=\(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func kind(forCommonName commonName: String?) -> CertificateKind {
        guard let commonName else { return .unknown }
        let lower = commonName.lowercased()
        if lower.contains("apple development") || lower.contains("iphone developer") || lower.contains("ios developer") {
            return .development
        }
        if lower.contains("apple distribution") || lower.contains("iphone distribution") || lower.contains("ios distribution") {
            return .distribution
        }
        if lower.contains("developer id") { return .distribution }
        return .unknown
    }

    // MARK: - PEM / DER

    /// Accepts raw DER, or PEM text (`-----BEGIN CERTIFICATE-----`).
    private func derData(from data: Data, sourceURL: URL) throws -> Data {
        if let text = String(data: data, encoding: .utf8),
           text.contains("-----BEGIN CERTIFICATE-----") {
            let base64 = text
                .components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().joined()
                .components(separatedBy: "-----END CERTIFICATE-----").first ?? ""
            let cleaned = base64.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: cleaned), !decoded.isEmpty else {
                throw AppError.certificate(.invalidFormat(reason: "The PEM certificate at “\(sourceURL.lastPathComponent)” could not be decoded."))
            }
            return decoded
        }
        guard !data.isEmpty else {
            throw AppError.certificate(.invalidFormat(reason: "The certificate file “\(sourceURL.lastPathComponent)” is empty."))
        }
        return data
    }

    // MARK: - Helpers

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func keychainMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Security error \(status)."
    }

    private func readFile(at url: URL, limit: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.certificate(.invalidFormat(reason: "File not found: “\(url.lastPathComponent)”"))
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > limit {
                throw AppError.certificate(.invalidFormat(reason: "File “\(url.lastPathComponent)” exceeds the \(limit) byte limit."))
            }
            return try Data(contentsOf: url)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.certificate(.invalidFormat(reason: "“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)"))
        }
    }

    private func storedCertificateURL(fileName: String, id: UUID) throws -> URL {
        let folder = try fileManager.folder(.certificates)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let safeBase = base.isEmpty ? id.uuidString : base
        let candidate = folder.appendingPathComponent("\(safeBase)-\(id.uuidString).\(ext.isEmpty ? "p12" : ext)")
        return candidate
    }
}
