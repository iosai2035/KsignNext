import Foundation

/// A signing certificate. The P12 file itself lives in the workspace
/// certificates folder and its password lives in the Keychain under
/// `keychainAccount`; neither is ever stored in this model or in
/// Core Data.
///
/// `fingerprint` is the SHA-256 hex of the certificate DER — it is
/// the model's `dataHash`. `isStoredInKeychain` is true exactly when
/// `keychainAccount` is set: the account string
/// `"p12-password-<id>"` carries the certificate UUID, so it is itself
/// the Keychain reference and no second reference field exists.
public struct CertificateModel: Codable, Equatable, Identifiable, Sendable {
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
    /// Keychain account holding this certificate's P12 password
    /// (`"p12-password-<id>"`), or `nil` when no password is stored.
    public var keychainAccount: String?
    public var isStoredInKeychain: Bool = false
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
        isStoredInKeychain: Bool? = nil,
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
        // True exactly when a Keychain account is set, unless the
        // caller explicitly overrides it.
        self.isStoredInKeychain = isStoredInKeychain ?? (keychainAccount != nil)
        self.importedAt = importedAt
    }

    public var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }

    /// Whole calendar days from now until expiry; `nil` when no
    /// expiration date is known. Negative when already expired.
    public var daysUntilExpiration: Int? {
        guard let expirationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day
    }

    public var p12FileName: String? { fileURL?.lastPathComponent }
}
