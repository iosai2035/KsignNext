import Foundation

/// Actor tracking cancellable background tasks by UUID.
///
/// Engines and use cases register long-running work here so the UI (or
/// a new operation) can cancel it by id, and so abandoned tasks are
/// cleaned up instead of leaking.
public actor TaskManager {
    public static let shared = TaskManager()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var namedTasks: [String: UUID] = [:]

    public init() {}

    /// Registers a task and returns its id. The task is removed from the
    /// registry when it finishes.
    @discardableResult
    public func register(name: String? = nil, _ operation: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        let task = Task {
            await operation()
            await self.unregister(id)
        }
        tasks[id] = task
        if let name { namedTasks[name] = id }
        return id
    }

    /// Registers an already-created task (e.g. one created by an engine).
    public func registerExisting(_ task: Task<Void, Never>, name: String? = nil) -> UUID {
        let id = UUID()
        tasks[id] = task
        if let name { namedTasks[name] = id }
        return id
    }

    public func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
    }

    public func cancel(name: String) {
        guard let id = namedTasks[name] else { return }
        cancel(id: id)
        namedTasks.removeValue(forKey: name)
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        namedTasks.removeAll()
    }

    public func isRunning(id: UUID) -> Bool {
        tasks[id] != nil
    }

    public func runningCount() -> Int { tasks.count }

    private func unregister(_ id: UUID) {
        tasks.removeValue(forKey: id)
        for (name, storedID) in namedTasks where storedID == id {
            namedTasks.removeValue(forKey: name)
        }
    }
}
