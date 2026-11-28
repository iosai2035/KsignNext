import Foundation
import XCTest
import CoreData
import CryptoKit
@testable import KsignNext

/// Phase 1 test support: fixture loading, synthetic DER / profile
/// builders, fake engines and repositories, and an in-memory Core Data
/// stack. No production code lives here; nothing in this file is
/// user-facing. See `Tests/Fixtures/README.md` for the fixture set.
enum FixtureBuilder {

    // MARK: - Fixture loading

    static let testPassword = "test123"

    /// URL of a committed fixture file (e.g. `"valid.p12"`).
    static func fixtureURL(named name: String) -> URL {
        // Test bundles locate resources under the test target bundle;
        // fall back to a source-tree search so the helper also works
        // when the target is run from a plain `xcodebuild` invocation.
        if let url = Bundle(for: FixtureBundleMarker.self).url(forResource: name, withExtension: nil) {
            return url
        }
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/Fixtures").appendingPathComponent(name),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) { return url }
        return candidates[0]
    }

    static func fixtureData(named name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(named: name))
    }

    /// A fresh, empty directory under the system temp area, owned by
    /// the calling test (deleted in `tearDown`).
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KsignNextTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Model factories

    static func makeCertificateModel(
        id: UUID = UUID(),
        name: String = "Test Certificate",
        commonName: String? = "Apple Development: Test User (ABCDE12345)",
        issuer: String? = "CN=Test Issuer, O=Test Org",
        serialNumber: String? = "01A2B3C4",
        fingerprint: String = String(repeating: "a", count: 64),
        teamIdentifier: String? = "ABCDE12345",
        kind: CertificateKind = .development,
        status: CertificateStatus = .valid,
        notBefore: Date? = Date().addingTimeInterval(-86_400),
        expirationDate: Date? = Date().addingTimeInterval(365 * 86_400),
        fileURL: URL? = nil,
        keychainAccount: String? = nil,
        isStoredInKeychain: Bool = false,
        importedAt: Date = Date()
    ) -> CertificateModel {
        CertificateModel(
            id: id, name: name, commonName: commonName, issuer: issuer,
            serialNumber: serialNumber, fingerprint: fingerprint,
            teamIdentifier: teamIdentifier, kind: kind, status: status,
            notBefore: notBefore, expirationDate: expirationDate,
            fileURL: fileURL, keychainAccount: keychainAccount,
            isStoredInKeychain: isStoredInKeychain, importedAt: importedAt)
    }

    static func makeProvisioningModel(
        id: UUID = UUID(),
        name: String = "Test Development",
        uuid: String = "11111111-2222-3333-4444-555555555555",
        appIdentifier: String = "ABCDE12345.com.example.test",
        teamIdentifier: String = "ABCDE12345",
        teamName: String? = "Test Org",
        kind: ProvisioningKind = .development,
        expirationDate: Date? = Date().addingTimeInterval(365 * 86_400),
        creationDate: Date? = Date().addingTimeInterval(-30 * 86_400),
        bundleIdentifierPrefixes: [String] = ["com.example.test"],
        platform: String? = nil,
        dataHash: String = String(repeating: "b", count: 64),
        entitlements: [String: String] = ["application-identifier": "ABCDE12345.com.example.test"],
        provisionedDevices: [String] = [String(repeating: "A", count: 40)],
        certificates: [String] = [],
        fileURL: URL? = nil,
        importedAt: Date = Date()
    ) -> ProvisioningModel {
        ProvisioningModel(
            id: id, name: name, uuid: uuid, appIdentifier: appIdentifier,
            teamIdentifier: teamIdentifier, teamName: teamName, kind: kind,
            expirationDate: expirationDate, creationDate: creationDate,
            bundleIdentifierPrefixes: bundleIdentifierPrefixes, platform: platform,
            dataHash: dataHash, entitlements: entitlements,
            provisionedDevices: provisionedDevices, certificates: certificates,
            fileURL: fileURL, importedAt: importedAt)
    }

    // MARK: - Synthetic DER builder (incl. the R-M1 large-arc OID)

    /// DER length octets (short form below 128, long form above).
    static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    static func derTLV(tag: UInt8, content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    /// An OID body whose second arc is encoded with base-128
    /// continuation bytes accumulating to (2^70 - 1), far above
    /// `Int.max`. The R-M1 fix must return `nil` for this OID instead
    /// of trapping while accumulating the arc.
    static func largeArcOIDBody() -> Data {
        // First byte 0x55 = arcs (2, 5). Then nine 0xFF continuation
        // bytes and a final 0x7F terminator: value = 2^70 - 1.
        Data([0x55] + [UInt8](repeating: 0xFF, count: 9) + [0x7F])
    }

    static func derOID(_ body: Data) -> Data { derTLV(tag: 0x06, content: body) }

    /// OID 2.5.4.3 (commonName) / 2.5.4.11 (organizationalUnitName).
    static func derStandardOID(_ bytes: [UInt8]) -> Data { derTLV(tag: 0x06, content: Data(bytes)) }

    static func derUTF8String(_ value: String) -> Data {
        derTLV(tag: 0x0C, content: Data(value.utf8))
    }

    static func derUTCTime(_ value: String) -> Data {
        derTLV(tag: 0x17, content: Data(value.utf8))
    }

    /// One RDN: SET { SEQUENCE { OID, UTF8String(value) } }.
    static func derRDN(oid: Data, value: String) -> Data {
        derTLV(tag: 0x31, content: derTLV(tag: 0x30, content: oid + derUTF8String(value)))
    }

    static func derName(rdns: [Data]) -> Data {
        derTLV(tag: 0x30, content: rdns.reduce(Data(), +))
    }

    /// A minimal but length-correct DER certificate. The subject holds
    /// a normal CN RDN, one RDN whose OID carries the R-M1 large arc,
    /// and a normal OU RDN. A correct parser reads the CN and OU and
    /// yields `nil` for the oversized-OID attribute — it must not
    /// trap. Other fields are structurally valid but minimal (the
    /// parser under test reads DN + validity, not the signature).
    static func derCertificateWithLargeArcOID() -> Data {
        let cnOID = derStandardOID([0x55, 0x04, 0x03])
        let ouOID = derStandardOID([0x55, 0x04, 0x0B])
        let largeOID = derOID(largeArcOIDBody())
        let subject = derName(rdns: [
            derRDN(oid: cnOID, value: "Apple Development: Test User"),
            derRDN(oid: largeOID, value: "ABCDE12345"),
            derRDN(oid: ouOID, value: "ABCDE12345"),
        ])
        let issuer = derName(rdns: [derRDN(oid: cnOID, value: "Test Issuer")])
        let validity = derTLV(tag: 0x30, content:
            derUTCTime("260101000000Z") + derUTCTime("270101000000Z"))
        let algorithm = derTLV(tag: 0x30, content:
            derStandardOID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
            + derTLV(tag: 0x05, content: Data()))
        let spki = derTLV(tag: 0x30, content:
            algorithm + derTLV(tag: 0x03, content: Data([0x00])))
        let version = derTLV(tag: 0xA0, content: derTLV(tag: 0x02, content: Data([0x02])))
        let serial = derTLV(tag: 0x02, content: Data([0x01]))
        let tbs = derTLV(tag: 0x30, content:
            version + serial + algorithm + issuer + validity + subject + spki)
        return derTLV(tag: 0x30, content:
            tbs + algorithm + derTLV(tag: 0x03, content: Data([0x00])))
    }

    // MARK: - Synthetic profile (plist) builder

    /// Builds a `.mobileprovision` payload: an XML plist. The engine
    /// under test scans for the first `<?xml` and the last `</plist>`,
    /// so the bytes are a plain plist (documented test fixture, not
    /// an Apple-signed CMS blob).
    static func syntheticProfileData(
        name: String? = "Test Development",
        uuid: String? = "11111111-2222-3333-4444-555555555555",
        teamIdentifier: [String]? = ["ABCDE12345"],
        teamName: String? = "Test Org",
        appIdentifier: String? = "ABCDE12345.com.example.test",
        expirationDate: Date? = nil,
        provisionedDevices: [String]? = [String(repeating: "A", count: 40)],
        provisionsAllDevices: Bool = false,
        getTaskAllow: Bool? = true,
        certificates: [String]? = [],
        extraStringWithPlistEndTag: String? = nil
    ) -> Data {
        var dict: [String: Any] = [:]
        if let name { dict["Name"] = name }
        if let uuid { dict["UUID"] = uuid }
        if let teamIdentifier { dict["TeamIdentifier"] = teamIdentifier }
        if let teamName { dict["TeamName"] = teamName }
        dict["AppIDName"] = "Test App"
        var entitlements: [String: Any] = [:]
        if let appIdentifier { entitlements["application-identifier"] = appIdentifier }
        if let getTaskAllow { entitlements["get-task-allow"] = getTaskAllow }
        dict["Entitlements"] = entitlements
        if let certificates { dict["DeveloperCertificates"] = certificates }
        dict["ExpirationDate"] = expirationDate ?? Date().addingTimeInterval(365 * 86_400)
        dict["CreationDate"] = Date().addingTimeInterval(-30 * 86_400)
        dict["Version"] = 1
        if let provisionedDevices { dict["ProvisionedDevices"] = provisionedDevices }
        if provisionsAllDevices { dict["ProvisionsAllDevices"] = true }
        if let extraStringWithPlistEndTag { dict["TestNote"] = extraStringWithPlistEndTag }
        // swiftlint:disable:next force_try
        return try! PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
    }

    /// `count` zero bytes, for the engine size-limit tests.
    static func oversizedData(bytes: Int) -> Data { Data(count: bytes) }
}

private final class FixtureBundleMarker: NSObject {}

// MARK: - Keychain test service

enum KeychainTestService {
    /// Never the production namespace: tests use this service name.
    static func make() -> KeychainService {
        KeychainService(service: "com.ksignnext.app.tests")
    }
}

// MARK: - In-memory Core Data stack

final class InMemoryCoreDataStack {
    let container: NSPersistentContainer
    var viewContext: NSManagedObjectContext { container.viewContext }

    init() {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "KsignNextTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { fatalError("In-memory store failed to load: \(error)") }
        }
    }

    private static func attribute(_ name: String, type: NSAttributeType, optional: Bool = true, transformer: String? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.valueTransformerName = transformer
        return attribute
    }

    /// Programmatic model v2 (same entity + attribute names as
    /// `Data/Persistence/KsignNext.xcdatamodeld` v2, §B.6), so the
    /// repository tests do not depend on the model file landing first.
    static func makeModel() -> NSManagedObjectModel {
        let certificate = NSEntityDescription()
        certificate.name = "Certificate"
        certificate.managedObjectClassName = "NSManagedObject"
        certificate.properties = [
            attribute("id", type: .UUIDAttributeType, optional: false),
            attribute("name", type: .stringAttributeType, optional: false),
            attribute("commonName", type: .stringAttributeType),
            attribute("issuer", type: .stringAttributeType),
            attribute("serialNumber", type: .stringAttributeType),
            attribute("fingerprint", type: .stringAttributeType, optional: false),
            attribute("teamIdentifier", type: .stringAttributeType),
            attribute("kind", type: .stringAttributeType, optional: false),
            attribute("status", type: .stringAttributeType, optional: false),
            attribute("notBefore", type: .dateAttributeType),
            attribute("expirationDate", type: .dateAttributeType),
            attribute("fileURL", type: .stringAttributeType),
            attribute("keychainAccount", type: .stringAttributeType),
            attribute("isStoredInKeychain", type: .booleanAttributeType, optional: false),
            attribute("importedAt", type: .dateAttributeType, optional: false),
        ]
        let profile = NSEntityDescription()
        profile.name = "ProvisioningProfile"
        profile.managedObjectClassName = "NSManagedObject"
        profile.properties = [
            attribute("id", type: .UUIDAttributeType, optional: false),
            attribute("name", type: .stringAttributeType, optional: false),
            attribute("uuid", type: .stringAttributeType, optional: false),
            attribute("appIdentifier", type: .stringAttributeType, optional: false),
            attribute("teamIdentifier", type: .stringAttributeType, optional: false),
            attribute("teamName", type: .stringAttributeType),
            attribute("kind", type: .stringAttributeType, optional: false),
            attribute("expirationDate", type: .dateAttributeType),
            attribute("creationDate", type: .dateAttributeType),
            attribute("bundleIdentifierPrefixes", type: .transformableAttributeType, transformer: "NSSecureUnarchiveFromData"),
            attribute("platform", type: .stringAttributeType),
            attribute("dataHash", type: .stringAttributeType, optional: false),
            attribute("entitlements", type: .transformableAttributeType, transformer: "NSSecureUnarchiveFromData"),
            attribute("provisionedDevices", type: .transformableAttributeType, transformer: "NSSecureUnarchiveFromData"),
            attribute("certificates", type: .transformableAttributeType, transformer: "NSSecureUnarchiveFromData"),
            attribute("fileURL", type: .stringAttributeType),
            attribute("importedAt", type: .dateAttributeType, optional: false),
        ]
        let model = NSManagedObjectModel()
        model.entities = [certificate, profile]
        return model
    }
}

// MARK: - Fake engines (deterministic, protocol-based)

final class FakeCertificateEngine: CertificateEngineProtocol, @unchecked Sendable {
    var parseP12Model: CertificateModel = FixtureBuilder.makeCertificateModel()
    var parseP12Error: AppError?
    var parseCertificateModel: CertificateModel = FixtureBuilder.makeCertificateModel()
    var importModel: CertificateModel = FixtureBuilder.makeCertificateModel()
    var importError: AppError?
    /// When set, `importP12` copies the source file into this folder
    /// first, then throws `importError` — simulating a Keychain
    /// failure after the copy, for rollback tests.
    var copyDestinationFolder: URL?
    var copiedFileURL: URL?
    var savedKeychainAccounts: [String] = []
    /// When set, `importP12` also writes the password into this real
    /// Keychain service, so rollback tests can observe Keychain state.
    var realKeychain: KeychainService?
    var validatePairError: AppError?
    var statusResult: CertificateStatus = .valid
    var storedPasswordResult: String? = "test123"
    var parseP12Calls: [URL] = []
    var importP12Calls: [(url: URL, password: String)] = []

    static func passwordAccount(for id: UUID) -> String { "p12-password-\(id.uuidString)" }

    func parseP12(at url: URL, password: String) async throws -> CertificateModel {
        parseP12Calls.append(url)
        if let parseP12Error { throw parseP12Error }
        return parseP12Model
    }

    func parseCertificate(at url: URL) async throws -> CertificateModel { parseCertificateModel }

    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        FixtureBuilder.makeProvisioningModel()
    }

    func importP12(at url: URL, password: String) async throws -> CertificateModel {
        importP12Calls.append((url, password))
        if let folder = copyDestinationFolder {
            let destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(importModel.id.uuidString).p12")
            try FileManager.default.copyItem(at: url, to: destination)
            copiedFileURL = destination
        }
        if let importError { throw importError }
        var model = importModel
        model.keychainAccount = Self.passwordAccount(for: model.id)
        model.isStoredInKeychain = true
        savedKeychainAccounts.append(model.keychainAccount ?? "")
        if let realKeychain, let account = model.keychainAccount {
            try realKeychain.savePassword(password, account: account)
        }
        return model
    }

    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        FixtureBuilder.makeProvisioningModel()
    }

    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws {
        if let validatePairError { throw validatePairError }
    }

    func status(of certificate: CertificateModel) async -> CertificateStatus { statusResult }

    func storedPassword(for certificate: CertificateModel) throws -> String? { storedPasswordResult }
}

final class FakeProvisioningEngine: ProvisioningEngineProtocol, @unchecked Sendable {
    var parseModel: ProvisioningModel = FixtureBuilder.makeProvisioningModel()
    var parseError: AppError?
    var importModel: ProvisioningModel = FixtureBuilder.makeProvisioningModel()
    var importError: AppError?
    var copyDestinationFolder: URL?
    var copiedFileURL: URL?
    var validatePairError: AppError?
    /// Models returned by `parseProvisioningProfile`, keyed by the
    /// file name — lets the expiring-profiles use case re-parse files.
    var modelsByFileName: [String: ProvisioningModel] = [:]

    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        if let parseError { throw parseError }
        return modelsByFileName[url.lastPathComponent] ?? parseModel
    }

    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel {
        if let folder = copyDestinationFolder {
            let destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(importModel.id.uuidString).mobileprovision")
            try FileManager.default.copyItem(at: url, to: destination)
            copiedFileURL = destination
        }
        if let importError { throw importError }
        return importModel
    }

    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws {
        if let validatePairError { throw validatePairError }
    }

    func allows(bundleID: String, profile: ProvisioningModel) -> Bool {
        profile.allows(bundleID: bundleID)
    }

    func deviceIsProvisioned(_ deviceUDID: String, in profile: ProvisioningModel) -> Bool {
        profile.provisionedDevices.contains(deviceUDID)
    }
}

// MARK: - Fake repositories (in-memory, protocol-based)

final class FakeCertificateRepository: CertificateRepository, @unchecked Sendable {
    private(set) var records: [UUID: CertificateModel] = [:]
    var errorToThrow: AppError?
    var deleteError: AppError?
    var saveCalls = 0

    func fetchAll() async throws -> [CertificateModel] {
        if let errorToThrow { throw errorToThrow }
        return records.values.sorted { $0.importedAt > $1.importedAt }
    }

    func fetch(id: UUID) async throws -> CertificateModel? {
        if let errorToThrow { throw errorToThrow }
        return records[id]
    }

    func fetch(fingerprint: String) async throws -> CertificateModel? {
        if let errorToThrow { throw errorToThrow }
        return records.values.first { $0.fingerprint == fingerprint }
    }

    func save(_ certificate: CertificateModel) async throws {
        saveCalls += 1
        if let errorToThrow { throw errorToThrow }
        records[certificate.id] = certificate
    }

    func delete(id: UUID) async throws {
        if let deleteError { throw deleteError }
        if let errorToThrow { throw errorToThrow }
        guard records.removeValue(forKey: id) != nil else {
            throw AppError.storage(.notFound(id: id.uuidString))
        }
    }
}

final class FakeProvisioningProfileRepository: ProvisioningProfileRepository, @unchecked Sendable {
    private(set) var records: [UUID: ProvisioningModel] = [:]
    var errorToThrow: AppError?
    var deleteError: AppError?
    var saveCalls = 0

    func fetchAll() async throws -> [ProvisioningModel] {
        if let errorToThrow { throw errorToThrow }
        return records.values.sorted { $0.importedAt > $1.importedAt }
    }

    func fetch(id: UUID) async throws -> ProvisioningModel? {
        if let errorToThrow { throw errorToThrow }
        return records[id]
    }

    func fetch(uuid: String) async throws -> ProvisioningModel? {
        if let errorToThrow { throw errorToThrow }
        return records.values.first { $0.uuid == uuid }
    }

    func save(_ profile: ProvisioningModel) async throws {
        saveCalls += 1
        if let errorToThrow { throw errorToThrow }
        records[profile.id] = profile
    }

    func delete(id: UUID) async throws {
        if let deleteError { throw deleteError }
        if let errorToThrow { throw errorToThrow }
        guard records.removeValue(forKey: id) != nil else {
            throw AppError.storage(.notFound(id: id.uuidString))
        }
    }
}
