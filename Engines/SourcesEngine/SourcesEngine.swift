import Foundation

// MARK: - SourcesEngine
//
// AltStore-format source support, implemented from the public format
// description. No AltSourceKit code is used.
//
// DOCUMENTED DEVIATION: the §14 SourcesEngine is not in the §4 folder
// list, so it lives in its own folder, `Engines/SourcesEngine/`, next to
// the other engines.
//
// Source allowlist note: this engine ships with NO bundled sources at all.
// Only sources the user adds themselves are ever fetched, and only over
// HTTPS. Piracy sources are never added, bundled, suggested, or fetched by
// this engine; adding a source is always an explicit user action in the UI.
//
// Safety rules enforced by this file:
// * Nothing from a source is ever executed. A source only supplies JSON
//   metadata and download URLs; downloading produces a file on disk and
//   nothing more.
// * Source URLs and app download URLs must be HTTPS; plain HTTP is refused.
// * Parsing errors name the offending field so the user (and the UI) can
//   tell exactly what is wrong with a source document.

// MARK: - Source model

/// Health of a user-added source.
public enum SourceStatus: String, Codable, Sendable, Equatable {
    case active
    case unreachable
    case invalid
    case updating
}

/// One user-added source, as shown in the UI.
public struct Source: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var identifier: String
    public var url: URL
    public var iconURL: URL?
    public var lastUpdated: Date?
    public var status: SourceStatus
    public var appCount: Int

    public init(
        id: UUID,
        name: String,
        identifier: String,
        url: URL,
        iconURL: URL? = nil,
        lastUpdated: Date? = nil,
        status: SourceStatus,
        appCount: Int
    ) {
        self.id = id
        self.name = name
        self.identifier = identifier
        self.url = url
        self.iconURL = iconURL
        self.lastUpdated = lastUpdated
        self.status = status
        self.appCount = appCount
    }
}

// MARK: - Errors

/// Every failure a source operation can report.
public enum SourceError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case notHTTPS(URL)
    case duplicateSource(identifier: String)
    case networkError(String)
    case httpStatus(Int)
    case emptyResponse
    case decodingFailed(field: String, detail: String)
    case sourceNotFound(UUID)
    case noDownloadEngine
    case noVersionsAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid source URL: \(value)"
        case .notHTTPS(let url):
            return "Only HTTPS sources are allowed: \(url.absoluteString)"
        case .duplicateSource(let identifier):
            return "This source is already added: \(identifier)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .httpStatus(let status):
            return "Source server returned HTTP status \(status)."
        case .emptyResponse:
            return "Source server returned an empty response."
        case .decodingFailed(let field, let detail):
            return "Could not parse source JSON (field '\(field)'): \(detail)"
        case .sourceNotFound(let id):
            return "No source with id \(id.uuidString)."
        case .noDownloadEngine:
            return "No download engine is configured, so the app cannot be downloaded."
        case .noVersionsAvailable(let bundleIdentifier):
            return "No versions are listed for \(bundleIdentifier)."
        }
    }

    var isDecodingError: Bool {
        if case .decodingFailed = self { return true }
        return false
    }
}

// MARK: - Download bridge

/// The minimal download capability SourcesEngine needs. It is defined here,
/// in the sources area, so this engine does not depend on the download
/// engine's concrete type; `DownloadEngine` conforms to it (see below).
public protocol SourceDownloadEngine: AnyObject, Sendable {
    func enqueueDownload(url: URL, fileName: String?, expectedSHA256: String?) async throws -> DownloadTask
}

extension DownloadEngine: SourceDownloadEngine {
    public func enqueueDownload(url: URL, fileName: String?, expectedSHA256: String?) async throws -> DownloadTask {
        try await enqueue(url: url, fileName: fileName, expectedSHA256: expectedSHA256)
    }
}

// MARK: - Engine

/// Fetches, parses, caches, and lists AltStore-format sources, and hands
/// app downloads to a `SourceDownloadEngine`.
public actor SourcesEngine {

    private struct CachedSource {
        var source: Source
        var altSource: AltSource
        var fetchedAt: Date
    }

    public static let defaultCacheTTL: TimeInterval = 3600

    private let urlSession: URLSession
    private let downloadEngine: (any SourceDownloadEngine)?
    private var cacheTTL: TimeInterval
    private var cached: [UUID: CachedSource] = [:]

    /// - Parameters:
    ///   - urlSession: used for source JSON fetches. Defaults to shared.
    ///   - cacheTTL: how long a fetched source document stays fresh.
    ///   - downloadEngine: used by `download(app:version:using:)` when no
    ///     engine is passed to that call. May be nil; downloading then
    ///     throws `SourceError.noDownloadEngine` instead of pretending.
    public init(
        urlSession: URLSession = .shared,
        cacheTTL: TimeInterval = defaultCacheTTL,
        downloadEngine: (any SourceDownloadEngine)? = nil
    ) {
        self.urlSession = urlSession
        self.cacheTTL = cacheTTL
        self.downloadEngine = downloadEngine
    }

    // MARK: Sources

    /// Validates, fetches, and adds a user-supplied source URL.
    /// Throws `.notHTTPS` for non-HTTPS URLs and `.duplicateSource` when
    /// the same URL or the same source identifier is already added.
    public func addSource(url: URL) async throws -> Source {
        guard url.scheme?.lowercased() == "https" else {
            throw SourceError.notHTTPS(url)
        }
        let normalized = Self.normalizedURLString(url)
        if cached.values.contains(where: { Self.normalizedURLString($0.source.url) == normalized }) {
            throw SourceError.duplicateSource(identifier: url.absoluteString)
        }
        let altSource = try await fetchSource(from: url)
        if cached.values.contains(where: { $0.source.identifier.lowercased() == altSource.identifier.lowercased() }) {
            throw SourceError.duplicateSource(identifier: altSource.identifier)
        }
        let source = Source(
            id: UUID(),
            name: altSource.name,
            identifier: altSource.identifier,
            url: url,
            iconURL: altSource.iconURL,
            lastUpdated: Date(),
            status: .active,
            appCount: altSource.apps.count
        )
        cached[source.id] = CachedSource(source: source, altSource: altSource, fetchedAt: Date())
        return source
    }

    /// Removes a source and drops its cache entry.
    public func removeSource(id: UUID) {
        cached.removeValue(forKey: id)
    }

    /// All added sources, sorted by name.
    public func allSources() -> [Source] {
        cached.values.map { $0.source }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One source by id, or nil.
    public func source(id: UUID) -> Source? {
        cached[id]?.source
    }

    // MARK: Fetch + parse

    /// Fetches and parses a source document from an HTTPS URL. Validates
    /// the scheme, the HTTP status, and the JSON; decoding failures name
    /// the offending field via `SourceError.decodingFailed`.
    public func fetchSource(from url: URL) async throws -> AltSource {
        guard url.scheme?.lowercased() == "https" else {
            throw SourceError.notHTTPS(url)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SourceError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError("No HTTP response received from the source server.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SourceError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw SourceError.emptyResponse
        }
        do {
            return try Self.makeDecoder().decode(AltSource.self, from: data)
        } catch {
            throw Self.mapDecodingError(error)
        }
    }

    // MARK: Refresh + cache

    /// Re-fetches one source and updates its cache entry. On failure the
    /// source status becomes `.invalid` for parse errors and `.unreachable`
    /// otherwise, and the previous (stale) document is kept so its apps
    /// remain listable.
    @discardableResult
    public func refreshSource(id: UUID) async throws -> Source {
        guard let record = cached[id] else {
            throw SourceError.sourceNotFound(id)
        }
        do {
            let altSource = try await fetchSource(from: record.source.url)
            var updated = record.source
            updated.name = altSource.name
            updated.identifier = altSource.identifier
            updated.iconURL = altSource.iconURL
            updated.lastUpdated = Date()
            updated.status = .active
            updated.appCount = altSource.apps.count
            cached[id] = CachedSource(source: updated, altSource: altSource, fetchedAt: Date())
            return updated
        } catch {
            var failed = record.source
            failed.status = (error as? SourceError)?.isDecodingError == true ? .invalid : .unreachable
            cached[id] = CachedSource(source: failed, altSource: record.altSource, fetchedAt: record.fetchedAt)
            throw error
        }
    }

    /// Refreshes every added source. One source failing does not stop the
    /// others; each result is reported per source id.
    public func refreshAll() async -> [UUID: Result<Source, SourceError>] {
        var results: [UUID: Result<Source, SourceError>] = [:]
        for id in cached.keys {
            do {
                results[id] = .success(try await refreshSource(id: id))
            } catch let error as SourceError {
                results[id] = .failure(error)
            } catch {
                results[id] = .failure(.networkError(error.localizedDescription))
            }
        }
        return results
    }

    /// How long a fetched source document stays fresh, in seconds.
    public func setCacheTTL(_ ttl: TimeInterval) {
        cacheTTL = max(0, ttl)
    }

    /// Drops every cached source document. Sources stay added; their
    /// documents are re-fetched on next use.
    public func clearCache() {
        cached.removeAll()
    }

    // MARK: Apps + versions

    /// The apps of one source, re-fetching first when the cache entry is
    /// older than the TTL.
    public func apps(for sourceID: UUID) async throws -> [AltSourceApp] {
        guard let record = cached[sourceID] else {
            throw SourceError.sourceNotFound(sourceID)
        }
        if isFresh(record) {
            return record.altSource.apps
        }
        _ = try await refreshSource(id: sourceID)
        guard let updated = cached[sourceID] else {
            throw SourceError.sourceNotFound(sourceID)
        }
        return updated.altSource.apps
    }

    /// All versions of an app, newest first.
    public static func versions(for app: AltSourceApp) -> [AltSourceVersion] {
        app.sortedVersions
    }

    /// The newest version of an app, or nil when it lists no versions.
    public static func latestVersion(for app: AltSourceApp) -> AltSourceVersion? {
        app.latestVersion
    }

    // MARK: Download

    /// Downloads an app version through the download engine. When `version`
    /// is nil the newest version is used. The AltStore format carries no
    /// hash, so no hash is passed for verification; the downloaded file is
    /// still validated by HTTP status and Content-Length in DownloadEngine.
    /// The file is only downloaded — never executed.
    public func download(
        app: AltSourceApp,
        version: AltSourceVersion? = nil,
        using engine: (any SourceDownloadEngine)? = nil
    ) async throws -> DownloadTask {
        guard let resolvedVersion = version ?? Self.latestVersion(for: app) else {
            throw SourceError.noVersionsAvailable(app.bundleIdentifier)
        }
        let downloadURL = resolvedVersion.downloadURL
        guard downloadURL.scheme?.lowercased() == "https" else {
            throw SourceError.notHTTPS(downloadURL)
        }
        guard let downloadEngine = engine ?? self.downloadEngine else {
            throw SourceError.noDownloadEngine
        }
        let fileName = "\(app.bundleIdentifier)_\(resolvedVersion.version).ipa"
        return try await downloadEngine.enqueueDownload(
            url: downloadURL,
            fileName: fileName,
            expectedSHA256: nil
        )
    }

    // MARK: Internals

    private func isFresh(_ record: CachedSource) -> Bool {
        Date().timeIntervalSince(record.fetchedAt) < cacheTTL
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Normalizes a source URL for duplicate detection: lowercase host,
    /// path without a trailing slash, and query string.
    private static func normalizedURLString(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        var path = url.path
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        let query = url.query.map { "?\($0)" } ?? ""
        return host + path + query
    }

    /// Maps a `DecodingError` to a `SourceError` that names the offending
    /// field (full dotted path, e.g. `apps.0.versions.1.downloadURL`).
    private static func mapDecodingError(_ error: Error) -> SourceError {
        guard let decodingError = error as? DecodingError else {
            return .decodingFailed(field: "unknown", detail: error.localizedDescription)
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return .decodingFailed(
                field: fieldName(from: context, missingKey: key),
                detail: "Missing required key '\(key.stringValue)'."
            )
        case .typeMismatch(let type, let context):
            return .decodingFailed(
                field: fieldName(from: context, missingKey: nil),
                detail: "Type mismatch: expected \(type)."
            )
        case .valueNotFound(let type, let context):
            return .decodingFailed(
                field: fieldName(from: context, missingKey: nil),
                detail: "Missing value of type \(type)."
            )
        case .dataCorrupted(let context):
            return .decodingFailed(
                field: fieldName(from: context, missingKey: nil),
                detail: context.debugDescription
            )
        @unknown default:
            return .decodingFailed(field: "unknown", detail: error.localizedDescription)
        }
    }

    private static func fieldName(from context: DecodingError.Context, missingKey: CodingKey?) -> String {
        var path = context.codingPath.map { $0.stringValue }
        if let missingKey {
            path.append(missingKey.stringValue)
        }
        let joined = path.joined(separator: ".")
        return joined.isEmpty ? "unknown" : joined
    }
}
