import Foundation

/// Domain view of a log entry (the persistent form is `LogEntry` in
/// Core/Logging; this model is what repositories and the Logs UI use).
public struct OperationLogModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var operationID: UUID?
    public var timestamp: Date
    public var level: LogLevel
    public var message: String
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        operationID: UUID? = nil,
        timestamp: Date = Date(),
        level: LogLevel,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.operationID = operationID
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.metadata = metadata
    }

    public init(from entry: LogEntry) {
        self.init(
            id: entry.id,
            operationID: entry.operationID,
            timestamp: entry.timestamp,
            level: entry.level,
            message: entry.message,
            metadata: entry.metadata
        )
    }

    public var logEntry: LogEntry {
        LogEntry(id: id, timestamp: timestamp, level: level, operationID: operationID, message: message, metadata: metadata)
    }
}
