import Foundation

/// An AltSource-style JSON source of apps. Sources are data only:
/// nothing from a source is ever executed, and only HTTPS URLs are
/// accepted (see `Validators` / `HTTPClient`).
public struct SourceModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var identifier: String?
    public var iconURL: URL?
    public var websiteURL: URL?
    public var lastUpdated: Date?
    public var appCount: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        identifier: String? = nil,
        iconURL: URL? = nil,
        websiteURL: URL? = nil,
        lastUpdated: Date? = nil,
        appCount: Int = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.identifier = identifier
        self.iconURL = iconURL
        self.websiteURL = websiteURL
        self.lastUpdated = lastUpdated
        self.appCount = appCount
        self.isEnabled = isEnabled
    }
}

/// One app entry listed by a source.
public struct SourceApp: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var bundleIdentifier: String
    public var version: String
    public var downloadURL: URL
    public var iconURL: URL?
    public var size: Int64?
    public var sourceID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        downloadURL: URL,
        iconURL: URL? = nil,
        size: Int64? = nil,
        sourceID: UUID
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.downloadURL = downloadURL
        self.iconURL = iconURL
        self.size = size
        self.sourceID = sourceID
    }
}
