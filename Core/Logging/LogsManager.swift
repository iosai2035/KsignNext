import Foundation

/// Actor-based structured logger.
///
/// - Keeps an in-memory ring buffer (bounded, so logging can never grow
///   without limit) and persists entries to a JSON-lines file.
/// - Every entry carries an operation ID when one is supplied.
/// - Secrets are never logged: messages and metadata values are passed
///   through `redact(_:)` before storage. Callers must still avoid
///   passing secrets in the first place; redaction is a safety net.
public actor LogsManager {
    public static let shared = LogsManager()

    public static let maxInMemoryEntries = 1_000
    public static let maxPersistedEntries = 10_000

    private var entries: [LogEntry] = []
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Keys whose values are secrets and must never be written to a log.
    public static let secretKeys: Set<String> = [
        "password", "passphrase", "privatekey", "private_key",
        "token", "accesstoken", "access_token", "secret",
        "apikey", "api_key", "authorization", "bearer",
        "p12password", "p12_password", "certificatepassword"
    ]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = directory.appendingPathComponent("KsignNext/logs.jsonl")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Logging

    public func log(_ level: LogLevel, _ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        let entry = LogEntry(
            level: level,
            operationID: operationID,
            message: Self.redact(message),
            metadata: Self.redactMetadata(metadata)
        )
        entries.append(entry)
        if entries.count > Self.maxInMemoryEntries {
            entries.removeFirst(entries.count - Self.maxInMemoryEntries)
        }
        persist(entry)
    }

    public func debug(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        log(.debug, message, operationID: operationID, metadata: metadata)
    }

    public func info(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        log(.info, message, operationID: operationID, metadata: metadata)
    }

    public func warning(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        log(.warning, message, operationID: operationID, metadata: metadata)
    }

    public func error(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        log(.error, message, operationID: operationID, metadata: metadata)
    }

    public func critical(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:]) {
        log(.critical, message, operationID: operationID, metadata: metadata)
    }

    /// Logs an error value without ever logging its underlying secret data.
    public func logError(_ error: Error, operationID: UUID? = nil, context: String = "") {
        let message = context.isEmpty ? error.localizedDescription : "\(context): \(error.localizedDescription)"
        log(.error, message, operationID: operationID)
    }

    // MARK: - Redaction

    /// Replaces values that look like secrets. Any `key=value` / `key: value`
    /// pair whose key is in `secretKeys` is replaced with `[REDACTED]`.
    public static func redact(_ text: String) -> String {
        var result = text
        for key in secretKeys {
            // key=value, key: value and "key": "value" forms.
            let patterns = [
                "(\(key)\\s*[=:]\\s*)[^\\s,;\"}]+",
                "(\"\(key)\"\\s*:\\s*\")[^\"]*"
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
                }
            }
        }
        return result
    }

    public static func redactMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            if secretKeys.contains(key.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "_")) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = redact(value)
            }
        }
        return result
    }

    // MARK: - Querying

    public func allEntries() -> [LogEntry] { entries }

    public func entries(matchingLevel minimum: LogLevel) -> [LogEntry] {
        entries.filter { $0.level >= minimum }
    }

    public func entries(forOperation operationID: UUID) -> [LogEntry] {
        entries.filter { $0.operationID == operationID }
    }

    public func search(_ query: String) -> [LogEntry] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.message.lowercased().contains(needle)
                || $0.metadata.values.contains { $0.lowercased().contains(needle) }
        }
    }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Export

    /// Returns the in-memory entries as JSON data (ISO-8601 dates).
    public func exportJSON() throws -> Data {
        try encoder.encode(entries)
    }

    /// Returns the entries as human-readable text, one line per entry.
    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            let operation = entry.operationID.map { " op=\($0.uuidString.prefix(8))" } ?? ""
            return "\(formatter.string(from: entry.timestamp)) [\(entry.level.rawValue.uppercased())]\(operation) \(entry.message)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func persist(_ entry: LogEntry) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = try encoder.encode(entry)
            var data = line
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            trimPersistedFileIfNeeded()
        } catch {
            // Logging must never crash the app or recurse into itself.
            // Swallow the persistence failure silently by design.
        }
    }

    private func trimPersistedFileIfNeeded() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.maxPersistedEntries else { return }
        let kept = lines.suffix(Self.maxPersistedEntries)
        let trimmed = kept.joined(separator: "\n") + "\n"
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Loads persisted entries back into the in-memory buffer (newest last).
    public func loadPersistedEntries() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var loaded: [LogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LogEntry.self, from: data) else { continue }
            loaded.append(entry)
        }
        entries = Array(loaded.suffix(Self.maxInMemoryEntries))
    }
}
