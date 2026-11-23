import Foundation

public enum InjectionPath: String, Codable, CaseIterable {
    case frameworks
    case plugIns
    case appRoot
}

public enum InjectionFolder: String, Codable, CaseIterable {
    case frameworks
    case plugIns
    case none
}

/// How a file is injected into the app bundle.
public enum InjectionType: String, Codable, CaseIterable {
    case dylib
    case deb
    case framework
    case bundle
    case unknown
}

/// Full signing configuration (prompt §9). All fields are plain data;
/// the signing engine interprets them, the UI edits them.
public struct SigningConfiguration: Codable, Equatable, Identifiable {
    public let id: UUID
    public var certificateID: UUID?
    public var provisioningProfileID: UUID?
    public var bundleIdentifier: String
    public var displayName: String?
    public var version: String?
    public var entitlementsURL: URL?
    public var preserveOriginalMetadata: Bool
    public var removeOriginalSignature: Bool
    public var includeExtensions: Bool
    public var verifyAfterSigning: Bool

    // Signing options
    public var ppqProtection: Bool
    public var doAdhocSigning: Bool
    public var onlyModify: Bool
    public var removeProvisioning: Bool
    public var removeSupportedDevices: Bool
    public var injectionFiles: [URL]
    public var disInjectionFiles: [URL]
    public var removeFiles: [String]
    public var injectPath: InjectionPath
    public var injectFolder: InjectionFolder

    public init(
        id: UUID = UUID(),
        certificateID: UUID? = nil,
        provisioningProfileID: UUID? = nil,
        bundleIdentifier: String,
        displayName: String? = nil,
        version: String? = nil,
        entitlementsURL: URL? = nil,
        preserveOriginalMetadata: Bool = true,
        removeOriginalSignature: Bool = true,
        includeExtensions: Bool = true,
        verifyAfterSigning: Bool = true,
        ppqProtection: Bool = false,
        doAdhocSigning: Bool = false,
        onlyModify: Bool = false,
        removeProvisioning: Bool = false,
        removeSupportedDevices: Bool = false,
        injectionFiles: [URL] = [],
        disInjectionFiles: [URL] = [],
        removeFiles: [String] = [],
        injectPath: InjectionPath = .frameworks,
        injectFolder: InjectionFolder = .frameworks
    ) {
        self.id = id
        self.certificateID = certificateID
        self.provisioningProfileID = provisioningProfileID
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.entitlementsURL = entitlementsURL
        self.preserveOriginalMetadata = preserveOriginalMetadata
        self.removeOriginalSignature = removeOriginalSignature
        self.includeExtensions = includeExtensions
        self.verifyAfterSigning = verifyAfterSigning
        self.ppqProtection = ppqProtection
        self.doAdhocSigning = doAdhocSigning
        self.onlyModify = onlyModify
        self.removeProvisioning = removeProvisioning
        self.removeSupportedDevices = removeSupportedDevices
        self.injectionFiles = injectionFiles
        self.disInjectionFiles = disInjectionFiles
        self.removeFiles = removeFiles
        self.injectPath = injectPath
        self.injectFolder = injectFolder
    }

    /// A configuration is usable when it names a certificate (or ad-hoc)
    /// and a valid bundle identifier.
    public var isUsable: Bool {
        (doAdhocSigning || certificateID != nil)
            && Validators.isValidBundleIdentifier(bundleIdentifier)
    }

    public static func `default`(bundleIdentifier: String) -> SigningConfiguration {
        SigningConfiguration(bundleIdentifier: bundleIdentifier)
    }
}
