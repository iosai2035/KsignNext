import Foundation
import Combine

// MARK: - DownloadManager
//
// `@MainActor` SwiftUI-facing wrapper over the `DownloadEngine` actor.
// It owns no download state of its own: it mirrors the engine's snapshots
// (via the engine's `updates()` stream) into `@Published` properties so
// views can observe them, and forwards user actions to the engine.

@MainActor
public final class DownloadManager: ObservableObject {

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var lastError: String?

    public let engine: DownloadEngine

    public init(engine: DownloadEngine = DownloadEngine()) {
        self.engine = engine
        startObserving()
        Task { await refresh() }
    }

    // MARK: Observation

    private func startObserving() {
        let engine = self.engine
        Task { [weak self] in
            let stream = await engine.updates()
            for await updated in stream {
                guard let self else { break }
                self.tasks = updated
            }
        }
    }

    /// Re-reads the engine's current snapshots (e.g. after returning to
    /// the foreground, when stream delivery may have been coalesced).
    public func refresh() async {
        tasks = await engine.allTasks()
    }

    // MARK: Actions

    @discardableResult
    public func enqueue(url: URL, fileName: String? = nil, expectedSHA256: String? = nil) async throws -> DownloadTask {
        do {
            let task = try await engine.enqueue(url: url, fileName: fileName, expectedSHA256: expectedSHA256)
            await refresh()
            return task
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func pause(id: UUID) async {
        await engine.pause(id: id)
        await refresh()
    }

    public func resume(id: UUID) async {
        await engine.resume(id: id)
        await refresh()
    }

    public func cancel(id: UUID) async {
        await engine.cancel(id: id)
        await refresh()
    }

    public func retry(id: UUID) async {
        await engine.retry(id: id)
        await refresh()
    }

    /// Removes a finished record and deletes its downloaded file.
    public func remove(id: UUID) async throws {
        do {
            try await engine.removeTask(id: id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Deletes stale temp files left behind by interrupted downloads.
    public func pruneTemporaryFiles(olderThan age: TimeInterval = 86_400) async {
        await engine.pruneTemporaryFiles(olderThan: age)
    }

    // MARK: Derived state

    /// Number of downloads currently queued or running.
    public var activeDownloadCount: Int {
        tasks.filter { $0.isActive }.count
    }

    /// Number of downloads currently transferring bytes.
    public var downloadingCount: Int {
        tasks.filter { $0.status == .downloading }.count
    }

    /// Total bytes downloaded across all tracked tasks.
    public var totalDownloadedBytes: Int64 {
        tasks.reduce(0) { $0 + $1.downloadedBytes }
    }

    /// Overall progress across tasks with a known total size, weighted by
    /// size. Returns 0 when no task reports a size.
    public var overallProgress: Double {
        let known = tasks.compactMap { task -> (Int64, Int64)? in
            guard let size = task.fileSize, size > 0 else { return nil }
            return (task.downloadedBytes, size)
        }
        let totalBytes = known.reduce(0) { $0 + $1.1 }
        guard totalBytes > 0 else { return 0 }
        let downloaded = known.reduce(0) { $0 + $1.0 }
        return min(1, Double(downloaded) / Double(totalBytes))
    }

    /// Combined current transfer speed of all running downloads, in bytes
    /// per second.
    public var combinedSpeed: Double {
        tasks.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speed }
    }
}
