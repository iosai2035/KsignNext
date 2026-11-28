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
    private let fileManager: FileSystemManager

    /// Maximum P12 / certificate file size accepted (10 MiB).
    private static let maxCertificateBytes = 10 * 1024 * 1024

    public init(
        keychain: KeychainService = .shared,
        fileManager: FileSystemManager = .shared
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
            // Both sides are SHA-256 hex; compare case-insensitively so
            // a differently-cased stored fingerprint still matches.
            let fingerprint = certificate.fingerprint.lowercased()
            let matches = profile.certificates.contains { base64DER in
                guard let der = Data(base64Encoded: base64DER) else { return false }
                return sha256Hex(of: der).lowercased() == fingerprint
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
            // The password is saved even when it is "" (password-less
            // P12): the empty password is still the registered secret
            // for this certificate, and registration must not be skipped.
            try keychain.savePassword(password, account: account)
        } catch {
            // Do not leave an orphaned file behind if the secret cannot be stored.
            // Best-effort cleanup: a failure here must not mask the
            // Keychain error being thrown, so it is swallowed.
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {}
            throw AppError.certificate(.keychainFailure(reason: error.localizedDescription))
        }
        model.fileURL = destination
        model.keychainAccount = account
        model.isStoredInKeychain = true
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
        guard let identityObject = first[kSecImportItemIdentity as String] as? AnyObject,
              CFGetTypeID(identityObject) == SecIdentityGetTypeID() else {
            throw AppError.certificate(.missingPrivateKey)
        }
        // The type ID was verified above, so this bit-cast is safe.
        // (`as? SecIdentity` is rejected by the Swift 6 compiler because
        // a conditional downcast to a CoreFoundation type always succeeds.)
        let identity = unsafeBitCast(identityObject, to: SecIdentity.self)
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
        let fields = parseCertificateFields(derData)

        let commonName = fields.subjectCommonName
            ?? SecCertificateCopySubjectSummary(certificate) as String?
        let teamIdentifier = fields.subjectOrganizationalUnit
        let serial = fields.serialHex
        let notBefore = fields.notBefore
        let notAfter = fields.notAfter
        let issuer = fields.issuerDisplay

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
        model.isStoredInKeychain = false
        model.status = await status(of: model)
        return model
    }

    // MARK: - DER parsing (no kSecOID* constants)

    /// Fields pulled from an X.509 certificate's DER encoding.
    private struct CertificateFields {
        var serialHex: String?
        var notBefore: Date?
        var notAfter: Date?
        var subjectCommonName: String?
        var subjectOrganizationalUnit: String?
        var issuerDisplay: String?
    }

    /// One DER tag-length-value element.
    private struct DERTLV {
        var tag: UInt8
        var content: Data
        var totalLength: Int
    }

    private static func derReadTLV(_ data: Data, at offset: Int) -> DERTLV? {
        guard offset < data.count, offset + 1 < data.count else { return nil }
        let tag = data[offset]
        var index = offset + 1
        let lengthByte = data[index]
        index += 1
        var length: Int
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7F)
            guard count > 0, count <= 4, index + count <= data.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[index])
                index += 1
            }
        }
        guard index + length <= data.count else { return nil }
        let content = data.subdata(in: index..<(index + length))
        return DERTLV(tag: tag, content: content, totalLength: (index - offset) + length)
    }

    private static func derChildren(of content: Data) -> [DERTLV] {
        var result: [DERTLV] = []
        var offset = 0
        while offset < content.count, let tlv = derReadTLV(content, at: offset) {
            guard tlv.totalLength > 0 else { break }
            result.append(tlv)
            offset += tlv.totalLength
        }
        return result
    }

    /// Decodes an OID value (without its tag/length) to dotted form.
    /// R-M1: arcs accumulate in `UInt64` and an arc larger than
    /// `Int.max` is rejected with `nil` at the end of that arc, so a
    /// hostile OID can never trap the process with an integer overflow.
    private static func derOIDString(_ content: Data) -> String? {
        guard !content.isEmpty else { return nil }
        var arcs: [Int] = []
        let first = Int(content[0])
        arcs.append(min(first / 40, 2))
        arcs.append(first - 40 * arcs[0])
        var value: UInt64 = 0
        for byte in content.dropFirst() {
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                guard value <= UInt64(Int.max) else { return nil }
                arcs.append(Int(value))   // value <= Int.max, so this is safe
                value = 0
            }
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    private static func derStringValue(_ tlv: DERTLV) -> String? {
        switch tlv.tag {
        case 0x0C, 0x13, 0x16: // UTF8String, PrintableString, IA5String
            return String(data: tlv.content, encoding: .utf8)
        case 0x14: // TeletexString (T61)
            return String(data: tlv.content, encoding: .utf8)
                ?? String(data: tlv.content, encoding: .isoLatin1)
        case 0x1E: // BMPString (UTF-16BE)
            return String(data: tlv.content, encoding: .utf16BigEndian)
        default:
            return nil
        }
    }

    private static func derDateValue(_ tlv: DERTLV) -> Date? {
        guard let text = String(data: tlv.content, encoding: .ascii) else { return nil }
        let digits = text.filter { $0.isNumber }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        if tlv.tag == 0x17 { // UTCTime YYMMDDHHMMSS(Z)
            guard digits.count >= 10 else { return nil }
            let yy = Int(digits.prefix(2)) ?? 0
            let year = yy < 50 ? 2000 + yy : 1900 + yy
            let month = Int(digits.dropFirst(2).prefix(2)) ?? 0
            let day = Int(digits.dropFirst(4).prefix(2)) ?? 0
            let hour = Int(digits.dropFirst(6).prefix(2)) ?? 0
            let minute = Int(digits.dropFirst(8).prefix(2)) ?? 0
            let second = digits.count >= 12 ? (Int(digits.dropFirst(10).prefix(2)) ?? 0) : 0
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        } else if tlv.tag == 0x18 { // GeneralizedTime YYYYMMDDHHMMSS(Z)
            guard digits.count >= 12 else { return nil }
            let year = Int(digits.prefix(4)) ?? 0
            let month = Int(digits.dropFirst(4).prefix(2)) ?? 0
            let day = Int(digits.dropFirst(6).prefix(2)) ?? 0
            let hour = Int(digits.dropFirst(8).prefix(2)) ?? 0
            let minute = Int(digits.dropFirst(10).prefix(2)) ?? 0
            let second = digits.count >= 14 ? (Int(digits.dropFirst(12).prefix(2)) ?? 0) : 0
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        }
        return nil
    }

    private static func derDistinguishedName(_ nameTLV: DERTLV) -> [(oid: String, value: String)] {
        var result: [(oid: String, value: String)] = []
        for rdn in derChildren(of: nameTLV.content) {
            for atv in derChildren(of: rdn.content) {
                let parts = derChildren(of: atv.content)
                guard parts.count >= 2, parts[0].tag == 0x06,
                      let oid = derOIDString(parts[0].content),
                      let value = derStringValue(parts[1]) else { continue }
                result.append((oid: oid, value: value))
            }
        }
        return result
    }

    private static func derShortLabel(for oid: String) -> String {
        switch oid {
        case "2.5.4.3": return "CN"
        case "2.5.4.6": return "C"
        case "2.5.4.7": return "L"
        case "2.5.4.8": return "ST"
        case "2.5.4.10": return "O"
        case "2.5.4.11": return "OU"
        case "2.5.4.5": return "SERIALNUMBER"
        case "2.5.4.42": return "GN"
        case "2.5.4.4": return "SN"
        default: return oid
        }
    }

    /// Walks Certificate -> TBSCertificate and extracts the serial number,
    /// validity window, subject CN/OU and a readable issuer string.
    /// The `kSecOID*` constants are not visible in the iOS SDK's Swift
    /// interface, so this reads the DER bytes `SecCertificateCopyData`
    /// already provides instead of `SecCertificateCopyValues`.
    private func parseCertificateFields(_ der: Data) -> CertificateFields {
        var fields = CertificateFields()
        guard let outer = Self.derReadTLV(der, at: 0), outer.tag == 0x30 else { return fields }
        let certChildren = Self.derChildren(of: outer.content)
        guard let tbs = certChildren.first, tbs.tag == 0x30 else { return fields }
        let tbsChildren = Self.derChildren(of: tbs.content)
        var index = 0
        // Optional explicit version [0].
        if index < tbsChildren.count, tbsChildren[index].tag == 0xA0 { index += 1 }
        // Serial number INTEGER.
        if index < tbsChildren.count, tbsChildren[index].tag == 0x02 {
            fields.serialHex = tbsChildren[index].content.map { String(format: "%02x", $0) }.joined()
            index += 1
        }
        // Signature AlgorithmIdentifier — skip.
        index += 1
        // Issuer Name.
        if index < tbsChildren.count, tbsChildren[index].tag == 0x30 {
            let issuer = Self.derDistinguishedName(tbsChildren[index])
            let parts = issuer.map { "\(Self.derShortLabel(for: $0.oid))=\($0.value)" }
            fields.issuerDisplay = parts.isEmpty ? nil : parts.joined(separator: ", ")
            index += 1
        }
        // Validity.
        if index < tbsChildren.count, tbsChildren[index].tag == 0x30 {
            let validity = Self.derChildren(of: tbsChildren[index].content)
            if validity.count >= 2 {
                fields.notBefore = Self.derDateValue(validity[0])
                fields.notAfter = Self.derDateValue(validity[1])
            }
            index += 1
        }
        // Subject Name.
        if index < tbsChildren.count, tbsChildren[index].tag == 0x30 {
            let subject = Self.derDistinguishedName(tbsChildren[index])
            fields.subjectCommonName = subject.first { $0.oid == "2.5.4.3" }?.value
            fields.subjectOrganizationalUnit = subject.first { $0.oid == "2.5.4.11" }?.value
        }
        return fields
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
