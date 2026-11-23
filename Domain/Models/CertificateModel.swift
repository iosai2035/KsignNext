import Foundation

public enum CertificateStatus: String, Codable, CaseIterable {
    case valid
    case expired
    case revoked
    case invalid
    case mismatched
    case unknown
}

public enum CertificateKind: String, Codable, CaseIterable {
    case developer
    case distribution
    case development
    case adhoc
    case unknown
}

/// A signing certificate. The P12 itself and its password are never
/// stored in this model: the file lives in the workspace certificates
/// folder and the password lives in the Keychain under
/// `keychainAccount` (see `KeychainService`).
public struct CertificateModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var commonName: String?
    public var issuer: String?
    public var serialNumber: String?
    public var fingerprint: String
    public var teamIdentifier: String?
    public var kind: CertificateKind
    public var status: CertificateStatus
    public var notBefore: Date?
    public var expirationDate: Date?
    public var fileURL: URL?
    /// Keychain account holding this certificate's P12 password.
    public var keychainAccount: String?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        commonName: String? = nil,
        issuer: String? = nil,
        serialNumber: String? = nil,
        fingerprint: String,
        teamIdentifier: String? = nil,
        kind: CertificateKind = .unknown,
        status: CertificateStatus = .unknown,
        notBefore: Date? = nil,
        expirationDate: Date? = nil,
        fileURL: URL? = nil,
        keychainAccount: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.commonName = commonName
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.fingerprint = fingerprint
        self.teamIdentifier = teamIdentifier
        self.kind = kind
        self.status = status
        self.notBefore = notBefore
        self.expirationDate = expirationDate
        self.fileURL = fileURL
        self.keychainAccount = keychainAccount
        self.importedAt = importedAt
    }

    public var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }

    public var daysUntilExpiration: Int? {
        guard let expirationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day
    }
}
