import Foundation

/// Actor-based structured logger. The ONE log source in the app.
///
/// - Keeps an in-memory ring buffer (bounded, so logging can never grow
///   without limit) and persists entries to a JSON-lines file.
/// - Every entry carries an operation ID when one is supplied.
/// - Secrets are never logged: messages and metadata values are passed
///   through `redact(_:)` before storage. Callers must still avoid
///   passing secrets in the first place; redaction is a safety net.
/// - Logging never crashes the app: persistence failures are swallowed
///   by design, except `clear()`, whose removal failure is thrown
///   (W-19) so the caller can surface it.
/// - A failed persist sets a one-shot flag; the next successful persist
///   retries the trim of the persisted file (W-20).
public actor AppLogger {
    public static let shared = AppLogger()

    public static let maxInMemoryEntries = 1_000
    public static let maxPersistedEntries = 10_000

    private var entries: [LogEntry] = []
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Set when a persist fails; cleared by the next successful persist,
    /// which retries the trim (W-20).
    private var persistNeedsTrimRetry = false

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
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
                } catch {
                    // A broken pattern must never break logging; skip it.
                    continue
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

    /// Removes all in-memory entries and deletes the persisted log file.
    /// A missing file is success, not an error; any other removal failure
    /// is thrown (W-19) and the caller must surface it.
    public func clear() throws {
        entries.removeAll()
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                return
            }
            throw AppError.storage(.deleteFailed(reason: error.localizedDescription))
        }
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
                defer {
                    do {
                        try handle.close()
                    } catch {
                        // Logging must never crash the app or recurse into itself.
                    }
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            // A previous persist failed: this successful persist retries
            // the trim (W-20). The flag is one-shot.
            persistNeedsTrimRetry = false
            trimPersistedFileIfNeeded()
        } catch {
            // Logging must never crash the app or recurse into itself.
            // Swallow the persistence failure silently by design, but
            // remember to retry the trim on the next successful persist.
            persistNeedsTrimRetry = true
        }
    }

    private func trimPersistedFileIfNeeded() {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > Self.maxPersistedEntries else { return }
            let kept = lines.suffix(Self.maxPersistedEntries)
            let trimmed = kept.joined(separator: "\n") + "\n"
            try trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort trim only; a failure here must never surface,
            // but the flag is set again so the next successful persist
            // retries the trim (W-20).
            persistNeedsTrimRetry = true
        }
    }

    /// Loads persisted entries back into the in-memory buffer (newest last).
    public func loadPersistedEntries() {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            var loaded: [LogEntry] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8) else { continue }
                do {
                    let entry = try decoder.decode(LogEntry.self, from: data)
                    loaded.append(entry)
                } catch {
                    continue
                }
            }
            entries = Array(loaded.suffix(Self.maxInMemoryEntries))
        } catch {
            // No persisted log (or unreadable): start with an empty buffer.
        }
    }
}
