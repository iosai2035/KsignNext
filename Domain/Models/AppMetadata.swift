import Foundation

/// Metadata read from an app bundle's Info.plist (and, where available,
/// from the IPA inspection). Pure value type; no file access here.
///
/// Unified by the coordinator: the Domain definition plus the fields
/// the IPA engine fills in (fileSize, fileURL, extensions, frameworks,
/// device families, URL schemes). `Hashable` is required by the engine.
public struct AppMetadata: Codable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var bundleIdentifier: String
    public var version: String
    public var buildVersion: String
    public var minimumOSVersion: String?
    public var executableName: String?
    public var architectures: [String]
    public var isEncrypted: Bool
    public var hasExtensions: Bool
    public var hasFrameworks: Bool
    public var iconData: Data?
    public var fileSize: Int64
    public var fileURL: URL?
    public var extensionBundleIdentifiers: [String]
    public var frameworkNames: [String]
    public var supportedDeviceFamilies: [Int]
    public var requiresiPhoneOS: Bool
    public var bundleDisplayName: String?
    public var urlSchemes: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        buildVersion: String,
        minimumOSVersion: String? = nil,
        executableName: String? = nil,
        architectures: [String] = [],
        isEncrypted: Bool = false,
        hasExtensions: Bool = false,
        hasFrameworks: Bool = false,
        iconData: Data? = nil,
        fileSize: Int64 = 0,
        fileURL: URL? = nil,
        extensionBundleIdentifiers: [String] = [],
        frameworkNames: [String] = [],
        supportedDeviceFamilies: [Int] = [],
        requiresiPhoneOS: Bool = false,
        bundleDisplayName: String? = nil,
        urlSchemes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
        self.executableName = executableName
        self.architectures = architectures
        self.isEncrypted = isEncrypted
        self.hasExtensions = hasExtensions
        self.hasFrameworks = hasFrameworks
        self.iconData = iconData
        self.fileSize = fileSize
        self.fileURL = fileURL
        self.extensionBundleIdentifiers = extensionBundleIdentifiers
        self.frameworkNames = frameworkNames
        self.supportedDeviceFamilies = supportedDeviceFamilies
        self.requiresiPhoneOS = requiresiPhoneOS
        self.bundleDisplayName = bundleDisplayName
        self.urlSchemes = urlSchemes
    }

    public var displayVersion: String {
        buildVersion.isEmpty ? version : "\(version) (\(buildVersion))"
    }

    public var isArm64Only: Bool {
        architectures == ["arm64"]
    }
}
