import Foundation

/// Static app configuration, read from the bundle / sensible defaults.
/// No secrets live here.
public struct AppConfiguration: Equatable {
    public var bundleIdentifier: String
    public var appName: String
    public var version: String
    public var buildNumber: String
    public var minimumOSVersion: String
    public var maxConcurrentDownloads: Int
    public var downloadTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var verifyAfterSigningByDefault: Bool
    public var preserveOriginalMetadataByDefault: Bool
    public var maxIPABytes: Int64
    public var maxArchiveEntries: Int
    public var localServerPort: Int

    public init(
        bundleIdentifier: String = "com.ksignnext.app",
        appName: String = "Ksign Next",
        version: String = "1.0.0",
        buildNumber: String = "1",
        minimumOSVersion: String = "16.0",
        maxConcurrentDownloads: Int = 3,
        downloadTimeout: TimeInterval = 300,
        requestTimeout: TimeInterval = 30,
        verifyAfterSigningByDefault: Bool = true,
        preserveOriginalMetadataByDefault: Bool = true,
        maxIPABytes: Int64 = SecureFileManager.maxIPABytes,
        maxArchiveEntries: Int = SecureFileManager.maxArchiveEntries,
        localServerPort: Int = 8080
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.version = version
        self.buildNumber = buildNumber
        self.minimumOSVersion = minimumOSVersion
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.downloadTimeout = downloadTimeout
        self.requestTimeout = requestTimeout
        self.verifyAfterSigningByDefault = verifyAfterSigningByDefault
        self.preserveOriginalMetadataByDefault = preserveOriginalMetadataByDefault
        self.maxIPABytes = maxIPABytes
        self.maxArchiveEntries = maxArchiveEntries
        self.localServerPort = localServerPort
    }

    /// Reads the real values from the app bundle where available.
    public static func fromBundle(_ bundle: Bundle = .main) -> AppConfiguration {
        var config = AppConfiguration()
        if let identifier = bundle.bundleIdentifier { config.bundleIdentifier = identifier }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            config.appName = name
        }
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            config.version = version
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            config.buildNumber = build
        }
        if let minimumOS = bundle.object(forInfoDictionaryKey: "MinimumOSVersion") as? String {
            config.minimumOSVersion = minimumOS
        }
        return config
    }

    public var displayVersion: String { "\(version) (\(buildNumber))" }
}
