import Foundation

/// Full inspection of an IPA: metadata plus everything found inside the
/// main executable and the bundle layout. Produced by `inspectIPA(_:)`.
///
/// Unified by the coordinator: the Domain definition (sourceURL, fileSize,
/// sha256, frameworks, appExtensions, plugIns, watchApps, entitlements as
/// `[String: String]`) plus the engine definition's Mach-O and layout
/// fields (appBundleURLs, isFatBinary, rpaths, segments, uuids, SDK
/// version, code-signature presence). Entitlements stay `[String: String]`
/// (Codable); the engine stringifies values when building the report.
public struct IPAInspectionReport: Codable, Equatable, Identifiable {
    public let id: UUID
    public var sourceURL: URL
    public var metadata: AppMetadata
    public var fileSize: Int64
    public var sha256: String?
    public var architectures: [String]
    public var frameworks: [String]
    public var appExtensions: [String]
    public var plugIns: [String]
    public var watchApps: [String]
    public var linkedLibraries: [String]
    public var entitlements: [String: String]
    public var warnings: [String]
    public var inspectedAt: Date
    public var appBundleURLs: [URL]
    public var isFatBinary: Bool
    public var isEncrypted: Bool
    public var rpaths: [String]
    public var segments: [String]
    public var uuids: [String]
    public var minimumOSVersion: String?
    public var sdkVersion: String?
    public var hasCodeSignature: Bool
    public var hasProvisioningProfile: Bool
    public var extensionBundleIdentifiers: [String]
    public var frameworkNames: [String]
    public var iconData: Data?

    public init(
        id: UUID = UUID(),
        sourceURL: URL = URL(fileURLWithPath: "/"),
        metadata: AppMetadata,
        fileSize: Int64 = 0,
        sha256: String? = nil,
        architectures: [String] = [],
        frameworks: [String] = [],
        appExtensions: [String] = [],
        plugIns: [String] = [],
        watchApps: [String] = [],
        linkedLibraries: [String] = [],
        entitlements: [String: String] = [:],
        warnings: [String] = [],
        inspectedAt: Date = Date(),
        appBundleURLs: [URL] = [],
        isFatBinary: Bool = false,
        isEncrypted: Bool = false,
        rpaths: [String] = [],
        segments: [String] = [],
        uuids: [String] = [],
        minimumOSVersion: String? = nil,
        sdkVersion: String? = nil,
        hasCodeSignature: Bool = false,
        hasProvisioningProfile: Bool = false,
        extensionBundleIdentifiers: [String] = [],
        frameworkNames: [String] = [],
        iconData: Data? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.fileSize = fileSize
        self.sha256 = sha256
        self.architectures = architectures
        self.frameworks = frameworks
        self.appExtensions = appExtensions
        self.plugIns = plugIns
        self.watchApps = watchApps
        self.linkedLibraries = linkedLibraries
        self.entitlements = entitlements
        self.warnings = warnings
        self.inspectedAt = inspectedAt
        self.appBundleURLs = appBundleURLs
        self.isFatBinary = isFatBinary
        self.isEncrypted = isEncrypted
        self.rpaths = rpaths
        self.segments = segments
        self.uuids = uuids
        self.minimumOSVersion = minimumOSVersion
        self.sdkVersion = sdkVersion
        self.hasCodeSignature = hasCodeSignature
        self.hasProvisioningProfile = hasProvisioningProfile
        self.extensionBundleIdentifiers = extensionBundleIdentifiers
        self.frameworkNames = frameworkNames
        self.iconData = iconData
    }

    public var isSupportedArchitecture: Bool {
        architectures.isEmpty || architectures.contains("arm64")
    }
}
