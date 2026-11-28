import Foundation

/// Registry of active tasks feeding the global progress HUD (§C.7).
///
/// Display state only: the registry tracks a task's label, progress and
/// destination screen. The operation that owns the work cancels its own
/// `Task`; `cancel(id:)` removes the item from the list so the HUD stops
/// showing it. No fake tasks, no simulated progress.
///
/// Main-actor isolated: `@Published` updates must publish on the main
/// actor, so background work calls these methods with `await`.
@MainActor
public final class TaskRegistry: ObservableObject {
    public struct TaskItem: Identifiable, Sendable {
        public let id: UUID
        public let label: String
        public var progress: Double?
        public let destination: TaskDestination

        public init(id: UUID = UUID(), label: String, progress: Double? = nil, destination: TaskDestination) {
            self.id = id
            self.label = label
            self.progress = progress
            self.destination = destination
        }
    }

    public enum TaskDestination: Sendable {
        case certificates
        case files
        case dashboard
    }

    @Published public private(set) var tasks: [TaskItem] = []

    public init() {}

    /// Registers a task and returns its id. The HUD shows the first
    /// active task and a "+N more" counter for the rest.
    @discardableResult
    public func register(label: String, destination: TaskDestination) -> UUID {
        let item = TaskItem(label: label, destination: destination)
        tasks.append(item)
        return item.id
    }

    /// Updates the progress of a registered task (`nil` = indeterminate).
    /// A no-op when the id is not registered.
    public func update(id: UUID, progress: Double?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].progress = progress
    }

    /// Removes a task from the list (the owning operation cancels its
    /// own work). A no-op when the id is not registered.
    public func cancel(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    /// Removes a finished task from the list. A no-op when the id is
    /// not registered.
    public func finish(id: UUID) {
        tasks.removeAll { $0.id == id }
    }
}
