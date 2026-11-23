import Foundation

/// `LogRepository` backed by the in-memory + file log store in
/// `LogsManager` (OperationLog is not persisted in Core Data; logs
/// live in their own JSON-lines file — see `LogsManager`).
/// This file exists because `DependencyContainer` wires a
/// `LogRepository`; it is a supporting adapter, not a Core Data repo.
public final class LogsManagerLogRepository: LogRepository, @unchecked Sendable {
    private let logs: LogsManager

    public init(logs: LogsManager = .shared) {
        self.logs = logs
    }

    public func fetchAll(limit: Int) async throws -> [OperationLogModel] {
        let entries = await logs.allEntries()
        return Array(entries.suffix(max(0, limit)).reversed()).map(OperationLogModel.init(from:))
    }

    public func fetch(forOperation operationID: UUID) async throws -> [OperationLogModel] {
        let entries = await logs.entries(forOperation: operationID)
        return entries.map(OperationLogModel.init(from:))
    }

    public func save(_ log: OperationLogModel) async throws {
        await logs.log(log.level, log.message, operationID: log.operationID, metadata: log.metadata)
    }

    public func deleteAll() async throws {
        await logs.clear()
    }
}
