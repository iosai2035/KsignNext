import Foundation

public enum LogLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error
    case critical

    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// One structured log line. `operationID` ties entries from one user
/// operation (import, signing, download) together for filtering.
public struct LogEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let operationID: UUID?
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        operationID: UUID? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.operationID = operationID
        self.message = message
        self.metadata = metadata
    }
}
