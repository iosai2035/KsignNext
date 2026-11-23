import Foundation

/// JSON transfer object for a certificate (export / sharing of
/// certificate metadata). Never carries a password, P12 data or a
/// private key — only public metadata.
public struct CertificateDTO: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var commonName: String?
    public var fingerprint: String
    public var teamIdentifier: String?
    public var kind: String
    public var status: String
    public var expirationDate: Date?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        commonName: String? = nil,
        fingerprint: String,
        teamIdentifier: String? = nil,
        kind: String = CertificateKind.unknown.rawValue,
        status: String = CertificateStatus.unknown.rawValue,
        expirationDate: Date? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.commonName = commonName
        self.fingerprint = fingerprint
        self.teamIdentifier = teamIdentifier
        self.kind = kind
        self.status = status
        self.expirationDate = expirationDate
        self.importedAt = importedAt
    }

    public init(from certificate: CertificateModel) {
        self.init(
            id: certificate.id,
            name: certificate.name,
            commonName: certificate.commonName,
            fingerprint: certificate.fingerprint,
            teamIdentifier: certificate.teamIdentifier,
            kind: certificate.kind.rawValue,
            status: certificate.status.rawValue,
            expirationDate: certificate.expirationDate,
            importedAt: certificate.importedAt
        )
    }

    public func toCertificateModel() -> CertificateModel {
        CertificateModel(
            id: id,
            name: name,
            commonName: commonName,
            fingerprint: fingerprint,
            teamIdentifier: teamIdentifier,
            kind: CertificateKind(rawValue: kind) ?? .unknown,
            status: CertificateStatus(rawValue: status) ?? .unknown,
            expirationDate: expirationDate,
            importedAt: importedAt
        )
    }
}
