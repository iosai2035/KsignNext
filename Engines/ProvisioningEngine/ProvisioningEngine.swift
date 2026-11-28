import Foundation
import CryptoKit

/// Parses .mobileprovision profiles.
///
/// A .mobileprovision file is a PKCS#7 (CMS) envelope wrapping an XML
/// plist. This engine extracts the plist by scanning for the `<?xml`
/// marker and decoding up to the LAST `</plist>` — it does NOT attempt
/// full CMS signature verification, so a parsed profile is treated as
/// structurally valid but its signature is unverified; callers must not
/// present it as Apple-verified.
public final class ProvisioningEngine: ProvisioningEngineProtocol, @unchecked Sendable {

    private let keychain: KeychainService
    private let fileManager: FileSystemManager

    /// Maximum profile size accepted (5 MiB).
    private static let maxProfileBytes = 5 * 1024 * 1024

    public init(
        keychain: KeychainService = .shared,
        fileManager: FileSystemManager = .shared
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
    }

    // MARK: - ProvisioningEngineProtocol

    public func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        let data = try readFile(at: url, limit: Self.maxProfileBytes)
        let plistData = try extractPlistData(from: data, sourceName: url.lastPathComponent)
        let raw = try decodePlist(plistData, sourceName: url.lastPathComponent)
        var model = try model(from: raw, fileURL: url)
        model.dataHash = sha256Hex(of: data)
        return model
    }

    public func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        var model = try await parseProvisioningProfile(at: url)
        if let expiration = model.expirationDate, expiration < Date() {
            throw AppError.certificate(.provisioningExpired(expirationDate: expiration))
        }
        let destination = try storedProfileURL(fileName: url.lastPathComponent, id: model.id)
        let data = try readFile(at: url, limit: Self.maxProfileBytes)
        do {
            try fileManager.writeAtomically(data, to: destination)
        } catch {
            throw AppError.certificate(.provisioningInvalid(reason: "The profile could not be copied into the workspace: \(error.localizedDescription)"))
        }
        model.fileURL = destination
        model.dataHash = sha256Hex(of: data)
        return model
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

    public func allows(bundleID: String, profile: ProvisioningModel) -> Bool {
        profile.allows(bundleID: bundleID)
    }

    public func deviceIsProvisioned(_ deviceUDID: String, in profile: ProvisioningModel) -> Bool {
        profile.provisionedDevices.contains(deviceUDID)
    }

    // MARK: - CMS envelope / plist extraction

    /// Finds the XML plist inside the CMS envelope. The envelope is a
    /// DER structure; the plist is embedded as its content, so the
    /// span from the first `<?xml` to the LAST `</plist>` is the
    /// document. The last occurrence is used deliberately: a plist
    /// string value may itself contain the literal `</plist>`, and
    /// stopping at the first occurrence would truncate the document.
    private func extractPlistData(from data: Data, sourceName: String) throws -> Data {
        let xmlMarker = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlMarker)?.lowerBound,
              let end = data.range(of: plistEnd, options: .backwards, in: start..<data.endIndex)?.upperBound else {
            throw AppError.certificate(.provisioningInvalid(reason: "“\(sourceName)” contains no embedded XML plist."))
        }
        return data[start..<end]
    }

    /// Raw plist keys of a provisioning profile. Only the keys this
    /// engine uses are modelled; unknown keys are ignored.
    private struct RawProfile: Decodable {
        var name: String?
        var uuid: String?
        var appIDName: String?
        var applicationIdentifierPrefix: [String]?
        var teamIdentifier: [String]?
        var teamName: String?
        var creationDate: Date?
        var expirationDate: Date?
        var entitlements: [String: PlistValue]?
        var provisionedDevices: [String]?
        var developerCertificates: [Data]?
        var provisionsAllDevices: Bool?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case uuid = "UUID"
            case appIDName = "AppIDName"
            case applicationIdentifierPrefix = "ApplicationIdentifierPrefix"
            case teamIdentifier = "TeamIdentifier"
            case teamName = "TeamName"
            case creationDate = "CreationDate"
            case expirationDate = "ExpirationDate"
            case entitlements = "Entitlements"
            case provisionedDevices = "ProvisionedDevices"
            case developerCertificates = "DeveloperCertificates"
            case provisionsAllDevices = "ProvisionsAllDevices"
        }
    }

    /// A plist value flattened to a display string for `ProvisioningModel.entitlements`.
    private enum PlistValue: Decodable {
        case string(String)
        case bool(Bool)
        case array([PlistValue])
        case dict([String: PlistValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = Self.attempt(String.self, from: container) { self = .string(value); return }
            if let value = Self.attempt(Bool.self, from: container) { self = .bool(value); return }
            if let value = Self.attempt([PlistValue].self, from: container) { self = .array(value); return }
            if let value = Self.attempt([String: PlistValue].self, from: container) { self = .dict(value); return }
            throw DecodingError.typeMismatch(PlistValue.self, DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported entitlement plist value."))
        }

        /// Tries one decoding; a failure means "not this type", not an
        /// error to surface — written as do/catch so no throwing call
        /// is ever silenced into `nil` elsewhere.
        private static func attempt<T: Decodable>(_ type: T.Type, from container: SingleValueDecodingContainer) -> T? {
            do {
                return try container.decode(type)
            } catch {
                return nil
            }
        }

        var displayString: String {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value ? "true" : "false"
            case .array(let values): return values.map(\.displayString).joined(separator: ", ")
            case .dict(let dict):
                return dict.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key)=\($0.value.displayString)" }
                    .joined(separator: "; ")
            }
        }

        var boolValue: Bool? {
            if case .bool(let value) = self { return value }
            return nil
        }

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }

    private func decodePlist(_ data: Data, sourceName: String) throws -> RawProfile {
        do {
            return try PropertyListDecoder().decode(RawProfile.self, from: data)
        } catch {
            throw AppError.certificate(.provisioningInvalid(reason: "The plist inside “\(sourceName)” could not be decoded: \(error.localizedDescription)"))
        }
    }

    // MARK: - Model mapping

    private func model(from raw: RawProfile, fileURL: URL?) throws -> ProvisioningModel {
        guard let name = raw.name, !name.isEmpty else {
            throw AppError.certificate(.provisioningInvalid(reason: "The profile has no Name."))
        }
        guard let uuid = raw.uuid, !uuid.isEmpty else {
            throw AppError.certificate(.provisioningInvalid(reason: "The profile has no UUID."))
        }
        guard let teamIdentifier = raw.teamIdentifier?.first, !teamIdentifier.isEmpty else {
            throw AppError.certificate(.provisioningInvalid(reason: "The profile has no TeamIdentifier."))
        }
        let entitlements = raw.entitlements ?? [:]
        let appIdentifier = entitlements["application-identifier"]?.stringValue
            ?? raw.applicationIdentifierPrefix?.first.map { $0 + ".*" }
            ?? ""
        guard !appIdentifier.isEmpty else {
            throw AppError.certificate(.provisioningInvalid(reason: "The profile has no application-identifier."))
        }
        let certificates = (raw.developerCertificates ?? []).map { $0.base64EncodedString() }
        // Stable id: derive it from the profile's own UUID when possible,
        // so the same profile parsed twice (e.g. at import and at signing)
        // resolves to the same id. Falls back to a fresh UUID otherwise.
        var model = ProvisioningModel(
            id: UUID(uuidString: uuid) ?? UUID(),
            name: name,
            uuid: uuid,
            appIdentifier: appIdentifier,
            teamIdentifier: teamIdentifier,
            teamName: raw.teamName,
            kind: kind(entitlements: entitlements, devices: raw.provisionedDevices ?? [], provisionsAllDevices: raw.provisionsAllDevices ?? false),
            expirationDate: raw.expirationDate,
            creationDate: raw.creationDate,
            entitlements: entitlements.mapValues(\.displayString),
            provisionedDevices: raw.provisionedDevices ?? [],
            certificates: certificates,
            fileURL: fileURL
        )
        // Phase 1 fields: a single App ID, so the prefix list holds
        // exactly the bundle identifier; profiles carry no explicit
        // platform field, so `platform` stays nil. `dataHash` (SHA-256
        // of the raw file bytes) is set by the caller, which owns the
        // raw bytes.
        model.bundleIdentifierPrefixes = [model.bundleIdentifier]
        model.platform = nil
        return model
    }

    /// Heuristic kind from entitlements + device list (Apple documents no
    /// explicit kind field in the profile).
    private func kind(entitlements: [String: PlistValue], devices: [String], provisionsAllDevices: Bool) -> ProvisioningKind {
        if provisionsAllDevices { return .enterprise }
        let getTaskAllow = entitlements["get-task-allow"]?.boolValue ?? false
        if devices.isEmpty { return .appStore }
        return getTaskAllow ? .development : .adhoc
    }

    // MARK: - Helpers

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readFile(at url: URL, limit: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.certificate(.provisioningInvalid(reason: "File not found: “\(url.lastPathComponent)”"))
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > limit {
                throw AppError.certificate(.provisioningInvalid(reason: "File “\(url.lastPathComponent)” exceeds the \(limit) byte limit."))
            }
            return try Data(contentsOf: url)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.certificate(.provisioningInvalid(reason: "“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)"))
        }
    }

    private func storedProfileURL(fileName: String, id: UUID) throws -> URL {
        let folder = try fileManager.folder(.certificates)
        let base = (fileName as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? id.uuidString : base
        return folder.appendingPathComponent("\(safeBase)-\(id.uuidString).mobileprovision")
    }
}
