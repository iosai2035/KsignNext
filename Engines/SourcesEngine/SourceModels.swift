import Foundation

// MARK: - SourceModels
//
// Codable models for the public source format, implemented from the
// public format description (a JSON document with `name`, `identifier`,
// `apps`, and `news`). No AltSourceKit code is used here.
//
// Source dates are ISO-8601 strings, with or without fractional seconds,
// so every date field is decoded from a string with a tolerant parser
// instead of relying on `JSONDecoder`'s date strategy. Encoding writes the
// same ISO-8601 string form back, so a decoded model re-encodes to valid
// source JSON.

// MARK: - Date parsing

/// Tolerant ISO-8601 parsing for source date strings such as
/// `2024-01-15T10:30:00Z` and `2024-01-15T10:30:00.000Z`.
public enum AltSourceDateParsing {

    private static let formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    private static let encoderFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    public static func string(from date: Date) -> String {
        encoderFormatter.string(from: date)
    }
}

// MARK: - Top-level source

/// One public-format source document.
public struct AltSource: Codable, Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let subtitle: String?
    public let description: String?
    public let iconURL: URL?
    public let headerURL: URL?
    public let website: URL?
    public let apps: [AltSourceApp]
    public let news: [AltSourceNewsItem]?

    enum CodingKeys: String, CodingKey {
        case name
        case identifier
        case subtitle
        case description
        case iconURL
        case headerURL
        case website
        case apps
        case news
    }

    public init(
        name: String,
        identifier: String,
        subtitle: String? = nil,
        description: String? = nil,
        iconURL: URL? = nil,
        headerURL: URL? = nil,
        website: URL? = nil,
        apps: [AltSourceApp],
        news: [AltSourceNewsItem]? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.subtitle = subtitle
        self.description = description
        self.iconURL = iconURL
        self.headerURL = headerURL
        self.website = website
        self.apps = apps
        self.news = news
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        identifier = try container.decode(String.self, forKey: .identifier)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        headerURL = try container.decodeIfPresent(URL.self, forKey: .headerURL)
        website = try container.decodeIfPresent(URL.self, forKey: .website)
        apps = try container.decode([AltSourceApp].self, forKey: .apps)
        news = try container.decodeIfPresent([AltSourceNewsItem].self, forKey: .news)
    }
}

// MARK: - App

/// One permission entry declared by an app (`appPermissions`).
public struct AltSourceAppPermission: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// The `appPermissions` object: entitlements and privacy usage strings.
public struct AltSourceAppPermissions: Codable, Sendable, Equatable {
    public let entitlements: [AltSourceAppPermission]?
    public let privacy: [String: String]?

    public init(entitlements: [AltSourceAppPermission]? = nil, privacy: [String: String]? = nil) {
        self.entitlements = entitlements
        self.privacy = privacy
    }
}

/// One app listed by a source, with its full version history.
public struct AltSourceApp: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let developerName: String
    public let subtitle: String?
    public let localizedDescription: String?
    public let iconURL: URL
    public let tintColor: String?
    public let category: String?
    public let versions: [AltSourceVersion]
    public let appPermissions: AltSourceAppPermissions?

    enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier
        case developerName
        case subtitle
        case localizedDescription
        case iconURL
        case tintColor
        case category
        case versions
        case appPermissions
    }

    public init(
        name: String,
        bundleIdentifier: String,
        developerName: String,
        subtitle: String? = nil,
        localizedDescription: String? = nil,
        iconURL: URL,
        tintColor: String? = nil,
        category: String? = nil,
        versions: [AltSourceVersion],
        appPermissions: AltSourceAppPermissions? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.developerName = developerName
        self.subtitle = subtitle
        self.localizedDescription = localizedDescription
        self.iconURL = iconURL
        self.tintColor = tintColor
        self.category = category
        self.versions = versions
        self.appPermissions = appPermissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        developerName = try container.decode(String.self, forKey: .developerName)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = try container.decode(URL.self, forKey: .iconURL)
        tintColor = try container.decodeIfPresent(String.self, forKey: .tintColor)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        versions = try container.decode([AltSourceVersion].self, forKey: .versions)
        appPermissions = try container.decodeIfPresent(AltSourceAppPermissions.self, forKey: .appPermissions)
    }

    /// All versions, newest first.
    public var sortedVersions: [AltSourceVersion] {
        versions.sorted { $0.date > $1.date }
    }

    /// The newest version, or nil when the app declares no versions.
    public var latestVersion: AltSourceVersion? {
        versions.max(by: { $0.date < $1.date })
    }

    /// Download size of the newest version, when known.
    public var latestSize: Int64? {
        latestVersion?.size
    }
}

// MARK: - Version

/// One released version of an app.
public struct AltSourceVersion: Codable, Sendable, Equatable {
    public let version: String
    public let date: Date
    public let localizedDescription: String?
    public let downloadURL: URL
    public let size: Int64
    public let minOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case date
        case localizedDescription
        case downloadURL
        case size
        case minOSVersion
    }

    public init(
        version: String,
        date: Date,
        localizedDescription: String? = nil,
        downloadURL: URL,
        size: Int64,
        minOSVersion: String? = nil
    ) {
        self.version = version
        self.date = date
        self.localizedDescription = localizedDescription
        self.downloadURL = downloadURL
        self.size = size
        self.minOSVersion = minOSVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        let rawDate = try container.decode(String.self, forKey: .date)
        guard let parsedDate = AltSourceDateParsing.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .date,
                in: container,
                debugDescription: "Invalid ISO-8601 date string for field 'date': \(rawDate)"
            )
        }
        date = parsedDate
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        size = try container.decode(Int64.self, forKey: .size)
        minOSVersion = try container.decodeIfPresent(String.self, forKey: .minOSVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(AltSourceDateParsing.string(from: date), forKey: .date)
        try container.encodeIfPresent(localizedDescription, forKey: .localizedDescription)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(minOSVersion, forKey: .minOSVersion)
    }
}

// MARK: - News

/// One news item published by a source.
public struct AltSourceNewsItem: Codable, Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let caption: String
    public let date: Date
    public let tintColor: String?
    public let imageURL: URL?
    public let appID: String?
    public let notify: Bool?
    public let externalURL: URL?

    enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case caption
        case date
        case tintColor
        case imageURL
        case appID
        case notify
        case externalURL
    }

    public init(
        identifier: String,
        title: String,
        caption: String,
        date: Date,
        tintColor: String? = nil,
        imageURL: URL? = nil,
        appID: String? = nil,
        notify: Bool? = nil,
        externalURL: URL? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.caption = caption
        self.date = date
        self.tintColor = tintColor
        self.imageURL = imageURL
        self.appID = appID
        self.notify = notify
        self.externalURL = externalURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decode(String.self, forKey: .title)
        caption = try container.decode(String.self, forKey: .caption)
        let rawDate = try container.decode(String.self, forKey: .date)
        guard let parsedDate = AltSourceDateParsing.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .date,
                in: container,
                debugDescription: "Invalid ISO-8601 date string for field 'date': \(rawDate)"
            )
        }
        date = parsedDate
        tintColor = try container.decodeIfPresent(String.self, forKey: .tintColor)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        appID = try container.decodeIfPresent(String.self, forKey: .appID)
        notify = try container.decodeIfPresent(Bool.self, forKey: .notify)
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(title, forKey: .title)
        try container.encode(caption, forKey: .caption)
        try container.encode(AltSourceDateParsing.string(from: date), forKey: .date)
        try container.encodeIfPresent(tintColor, forKey: .tintColor)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encodeIfPresent(notify, forKey: .notify)
        try container.encodeIfPresent(externalURL, forKey: .externalURL)
    }
}
