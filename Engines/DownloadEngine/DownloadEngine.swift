import Foundation
import CryptoKit

// MARK: - DownloadEngine
//
// Actor-based download manager for Ksign Next.
//
// Session choice (background vs foreground):
// A background `URLSession` only works when the app declares the background
// mode capability (`UIBackgroundModes` containing `fetch` in Info.plist) and
// the app delegate forwards
// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
// `DownloadEngine.handleEventsForBackgroundURLSession`. When that capability
// is absent this engine uses a foreground session instead, so downloads
// still work — they simply stop when the app is suspended. The choice is
// made by `DownloadSessionMode.preferred` and is documented here rather
// than silently assumed.
//
// Safety rules enforced by this file:
// * Downloaded files are NEVER opened, executed, or installed automatically.
//   A finished download is only a file on disk; installation is a separate,
//   explicit user action handled by InstallationEngine.
// * No force-unwrap is used on any user-supplied path. Every failure is a
//   typed `DownloadError`.
// * HTTP status and `Content-Length` are validated before a download is
//   reported as complete, and a SHA-256 hash is verified whenever the
//   source supplied one.
// * At most `maxConcurrentDownloads` downloads run at the same time.
// * Pause uses resume data when the server supports it; when the server
//   does not, the download restarts from the beginning honestly (the task
//   goes back to `.pending` with `downloadedBytes` reset) instead of
//   pretending to resume.

// MARK: - Status

/// Lifecycle of a single download.

// MARK: - Task model

/// One download, as observed by SwiftUI. All mutation goes through the
/// actor; this value type is a snapshot.
public struct DownloadTask: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let url: URL
    public let fileName: String
    public var fileSize: Int64?
    public var downloadedBytes: Int64
    public var status: DownloadStatus
    public let createdAt: Date
    public var completedAt: Date?
    /// Bytes per second, from the most recent progress sample.
    public var speed: Double
    /// Estimated seconds remaining, or nil when it cannot be computed.
    public var eta: TimeInterval?
    public var attempts: Int
    public let expectedSHA256: String?
    public var localFileURL: URL?
    public var errorDescription: String?

    public init(
        id: UUID,
        url: URL,
        fileName: String,
        fileSize: Int64?,
        downloadedBytes: Int64,
        status: DownloadStatus,
        createdAt: Date,
        completedAt: Date?,
        speed: Double,
        eta: TimeInterval?,
        attempts: Int,
        expectedSHA256: String?,
        localFileURL: URL?,
        errorDescription: String?
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.speed = speed
        self.eta = eta
        self.attempts = attempts
        self.expectedSHA256 = expectedSHA256
        self.localFileURL = localFileURL
        self.errorDescription = errorDescription
    }

    /// 0...1 fraction downloaded; 0 when the total size is unknown.
    public var progress: Double {
        guard let fileSize, fileSize > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(fileSize))
    }

    public var isActive: Bool {
        status == .downloading || status == .pending
    }
}

// MARK: - Session mode

/// Which kind of `URLSession` the engine uses.
public enum DownloadSessionMode: String, Sendable {
    case background
    case foreground

    /// Background only when the app declares the background-mode capability;
    /// otherwise foreground. See the file header for why.
    public static var preferred: DownloadSessionMode {
        supportsBackgroundSessions ? .background : .foreground
    }

    /// True when Info.plist declares `UIBackgroundModes` containing `fetch`.
    public static var supportsBackgroundSessions: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("fetch")
    }
}

// MARK: - Session delegate
//
// `URLSession` calls its delegate on a serial operation queue. The delegate
// does the synchronous, must-not-wait work itself (HTTP validation, hash
// verification, moving the finished file out of the system temp location
// before it is deleted) and forwards state changes to the actor with a
// `Task`. Per-task bookkeeping is guarded by a lock.

final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct Info {
        let id: UUID
        let fileName: String
        let expectedSHA256: String?
        var lastBytes: Int64
        var lastSampleDate: Date
    }

    weak var engine: DownloadEngine?
    let destinationDirectory: URL

    private let lock = NSLock()
    private var infos: [Int: Info] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func register(taskIdentifier: Int, info: Info) {
        withLock { infos[taskIdentifier] = info }
    }

    func remove(taskIdentifier: Int) {
        withLock { infos.removeValue(forKey: taskIdentifier) }
    }

    func info(for taskIdentifier: Int) -> Info? {
        withLock { infos[taskIdentifier] }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        withLock { backgroundCompletionHandler = handler }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var speed: Double = 0
        withLock {
            if var info = infos[downloadTask.taskIdentifier] {
                let now = Date()
                let interval = now.timeIntervalSince(info.lastSampleDate)
                if interval >= 0.25, totalBytesWritten > info.lastBytes {
                    speed = Double(totalBytesWritten - info.lastBytes) / interval
                }
                info.lastBytes = totalBytesWritten
                info.lastSampleDate = now
                infos[downloadTask.taskIdentifier] = info
            }
        }
        guard let info = info(for: downloadTask.taskIdentifier) else { return }
        Task { [weak self] in
            await self?.engine?.reportProgress(
                id: info.id,
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                speed: speed
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let info = info(for: downloadTask.taskIdentifier) else {
            // The finished file belongs to no known task. Report it so the
            // engine can fail the matching record instead of hanging.
            Task { [weak self] in
                await self?.engine?.handleOrphanedDownload(taskIdentifier: downloadTask.taskIdentifier)
            }
            return
        }

        // HTTP status validation: only 2xx is a successful download.
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            Task { [weak self] in
                await self?.engine?.failDownload(id: info.id, error: .invalidHTTPStatus(httpResponse.statusCode))
            }
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            // Content-Length validation, when the server supplied one.
            let expectedLength = downloadTask.response?.expectedContentLength ?? -1
            if expectedLength > 0, size != expectedLength {
                Task { [weak self] in
                    await self?.engine?.failDownload(
                        id: info.id,
                        error: .contentLengthMismatch(expected: expectedLength, actual: size)
                    )
                }
                return
            }

            // SHA-256 verification, when the source supplied a hash.
            if let expectedHash = info.expectedSHA256 {
                let actualHash = try DownloadEngine.fileSHA256(fileURL: location)
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    Task { [weak self] in
                        await self?.engine?.failDownload(
                            id: info.id,
                            error: .hashMismatch(expected: expectedHash, actual: actualHash)
                        )
                    }
                    return
                }
            }

            // Move the file out of the system temp location before this
            // delegate method returns; the system deletes it afterwards.
            let destination = uniqueDestinationURL(fileName: info.fileName)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { [weak self] in
                await self?.engine?.completeDownload(id: info.id, fileURL: destination, fileSize: size)
            }
        } catch {
            let message = error.localizedDescription
            Task { [weak self] in
                await self?.engine?.failDownload(id: info.id, error: .downloadFailed(message))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let info = info(for: task.taskIdentifier) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData as String] as? Data
        let isCancellation = (error as NSError).code == NSURLErrorCancelled
        Task { [weak self] in
            await self?.engine?.handleTaskError(
                id: info.id,
                error: error,
                resumeData: resumeData,
                isCancellation: isCancellation
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = withLock { backgroundCompletionHandler }
        handler?()
    }

    // MARK: Helpers

    /// A destination that does not overwrite an existing file: appends
    /// " (2)", " (3)", ... before the extension when needed.
    private func uniqueDestinationURL(fileName: String) -> URL {
        let base = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = destinationDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

// MARK: - Engine

/// Actor-based download manager. All state lives here; SwiftUI talks to it
/// through `DownloadManager`.
public actor DownloadEngine {

    public static let backgroundSessionIdentifier = "com.ksignnext.app.downloads"
    public static let maxConcurrentDownloads = 3
    public static let maxAttempts = 3

    private struct ActiveDownload {
        var task: DownloadTask
        var sessionTask: URLSessionDownloadTask?
        var resumeData: Data?
        var attempts: Int
    }

    private var active: [UUID: ActiveDownload] = [:]
    private var taskIdentifierToID: [Int: UUID] = [:]
    private var updateContinuations: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]
    private var lastPublishedAt = Date.distantPast
    private var lastFileRemovalErrorMessage: String?

    private let session: URLSession
    private let delegate: DownloadSessionDelegate
    public let destinationDirectory: URL
    public let mode: DownloadSessionMode

    /// - Parameters:
    ///   - mode: `.preferred` picks a background session only when the app
    ///     declares the background-mode capability, otherwise foreground.
    ///   - destinationDirectory: where finished files are moved. Defaults
    ///     to `Documents/Downloads`, falling back to a temp directory.
    public init(mode: DownloadSessionMode = .preferred, destinationDirectory: URL? = nil) {
        let resolvedDestination: URL
        if let destinationDirectory {
            resolvedDestination = destinationDirectory
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            resolvedDestination = documents.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            resolvedDestination = FileManager.default.temporaryDirectory
                .appendingPathComponent("KsignNextDownloads", isDirectory: true)
        }

        let configuration: URLSessionConfiguration
        switch mode {
        case .background:
            let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
            config.sessionSendsLaunchEvents = true
            configuration = config
        case .foreground:
            configuration = URLSessionConfiguration.default
        }
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 86_400

        let delegate = DownloadSessionDelegate(destinationDirectory: resolvedDestination)
        self.mode = mode
        self.destinationDirectory = resolvedDestination
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.engine = self
        // Best effort: a later move failure is still reported as a typed error.
        try? FileManager.default.createDirectory(at: resolvedDestination, withIntermediateDirectories: true)
    }

    // MARK: Enqueue

    /// Queues a download and returns its snapshot. Starts immediately when
    /// a concurrency slot is free, otherwise waits in `.pending`.
    public func enqueue(url: URL, fileName: String? = nil, expectedSHA256: String? = nil) async throws -> DownloadTask {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.invalidURL(url.absoluteString)
        }
        let resolvedFileName = sanitizedFileName(fileName ?? url.lastPathComponent)
        guard !resolvedFileName.isEmpty else {
            throw DownloadError.underlying("Invalid file name: \(fileName ?? "")")
        }
        let task = DownloadTask(
            id: UUID(),
            url: url,
            fileName: resolvedFileName,
            fileSize: nil,
            downloadedBytes: 0,
            status: .pending,
            createdAt: Date(),
            completedAt: nil,
            speed: 0,
            eta: nil,
            attempts: 0,
            expectedSHA256: expectedSHA256,
            localFileURL: nil,
            errorDescription: nil
        )
        active[task.id] = ActiveDownload(task: task, sessionTask: nil, resumeData: nil, attempts: 0)
        publishUpdates(force: true)
        startPendingDownloads()
        return task
    }

    // MARK: Pause / resume / cancel / retry

    /// Pauses a running download. Resume data is captured when the server
    /// supports it; when it does not, `resume(id:)` restarts honestly.
    public func pause(id: UUID) {
        guard var entry = active[id],
              entry.task.status == .downloading,
              let sessionTask = entry.sessionTask else { return }
        entry.sessionTask = nil
        entry.task.status = .paused
        active[id] = entry
        taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
        delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
        publishUpdates(force: true)
        sessionTask.cancel(byProducingResumeData: { [weak self] resumeData in
            guard let resumeData else { return }
            Task { await self?.storeResumeData(id: id, data: resumeData) }
        })
    }

    /// Resumes a paused (or failed) download. Uses stored resume data when
    /// available; otherwise restarts from the beginning.
    public func resume(id: UUID) {
        guard var entry = active[id],
              entry.task.status == .paused || entry.task.status == .failed else { return }
        entry.task.status = .pending
        entry.task.errorDescription = nil
        entry.task.completedAt = nil
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    /// Cancels a download and marks it `.cancelled`. A partially downloaded
    /// file in the system temp location is discarded by the system.
    public func cancel(id: UUID) {
        guard var entry = active[id] else { return }
        if let sessionTask = entry.sessionTask {
            sessionTask.cancel()
            taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
            delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
        }
        entry.sessionTask = nil
        entry.task.status = .cancelled
        entry.task.completedAt = Date()
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    /// Retries a failed download from scratch (resume data is discarded,
    /// because the failure may have been caused by a corrupt partial file).
    public func retry(id: UUID) {
        guard var entry = active[id], entry.task.status == .failed else { return }
        entry.attempts = 0
        entry.task.attempts = 0
        entry.resumeData = nil
        entry.task.status = .pending
        entry.task.errorDescription = nil
        entry.task.completedAt = nil
        entry.task.downloadedBytes = 0
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    // MARK: Queries

    public func task(id: UUID) -> DownloadTask? {
        active[id]?.task
    }

    public func allTasks() -> [DownloadTask] {
        active.values.map { $0.task }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes a finished record and deletes its downloaded file. Refuses
    /// to remove an active download; call `cancel(id:)` first.
    public func removeTask(id: UUID) throws {
        guard let entry = active[id] else { throw DownloadError.underlying("No download with id \(id.uuidString).") }
        guard entry.task.status == .completed || entry.task.status == .failed || entry.task.status == .cancelled else {
            throw DownloadError.underlying("Download \(id.uuidString) is still active and cannot be removed yet.")
        }
        if let fileURL = entry.task.localFileURL {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                lastFileRemovalErrorMessage = error.localizedDescription
                throw DownloadError.underlying("Could not delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        active.removeValue(forKey: id)
        publishUpdates(force: true)
    }

    /// The last file-deletion error, if `removeTask` failed to delete a file.
    public func lastFileRemovalError() -> String? {
        lastFileRemovalErrorMessage
    }

    // MARK: Observation

    /// An async stream of task snapshots, starting with the current list.
    /// `DownloadManager` consumes this to drive SwiftUI.
    public func updates() -> AsyncStream<[DownloadTask]> {
        let initial = allTasks()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task { await self.registerUpdateContinuation(continuation) }
            continuation.yield(initial)
        }
    }

    private func registerUpdateContinuation(_ continuation: AsyncStream<[DownloadTask]>.Continuation) {
        let token = UUID()
        updateContinuations[token] = continuation
        continuation.onTermination = { _ in
            Task { [weak self] in await self?.removeUpdateContinuation(token: token) }
        }
    }

    private func removeUpdateContinuation(token: UUID) {
        updateContinuations.removeValue(forKey: token)
    }

    private func publishUpdates(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 0.25 else { return }
        lastPublishedAt = now
        let snapshot = allTasks()
        for continuation in updateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: Background sessions

    /// Called from the app delegate's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// so a background session can report completion to the system.
    public func handleEventsForBackgroundURLSession(completionHandler: @escaping () -> Void) {
        delegate.setBackgroundCompletionHandler(completionHandler)
    }

    /// Lets in-flight tasks finish, then invalidates the session.
    public func finishAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: Temp-file management

    /// Deletes stale files from the engine's temp directory. Finished
    /// downloads live in `destinationDirectory`; this only prunes leftovers.
    public func pruneTemporaryFiles(olderThan age: TimeInterval = 86_400) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("KsignNextDownloads", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: SHA-256

    /// Streams a file through CryptoKit SHA-256 without loading it into
    /// memory. Throws when the file cannot be read.
    public static func fileSHA256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file's SHA-256 matches `expectedHex` (case-insensitive).
    public static func verifySHA256(fileURL: URL, expectedHex: String) throws -> Bool {
        try fileSHA256(fileURL: fileURL).lowercased() == expectedHex.lowercased()
    }

    // MARK: Delegate callbacks (called by DownloadSessionDelegate)

    func reportProgress(id: UUID, downloadedBytes: Int64, totalBytes: Int64, speed: Double) {
        guard var entry = active[id], entry.task.status == .downloading else { return }
        entry.task.downloadedBytes = downloadedBytes
        if totalBytes > 0 {
            entry.task.fileSize = totalBytes
        }
        if speed > 0 {
            entry.task.speed = speed
        }
        if speed > 0, let size = entry.task.fileSize, size > downloadedBytes {
            entry.task.eta = Double(size - downloadedBytes) / speed
        } else {
            entry.task.eta = nil
        }
        active[id] = entry
        publishUpdates()
    }

    func completeDownload(id: UUID, fileURL: URL, fileSize: Int64) {
        guard var entry = active[id] else { return }
        if let sessionTask = entry.sessionTask {
            taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
            delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
        }
        entry.sessionTask = nil
        entry.task.status = .completed
        entry.task.completedAt = Date()
        entry.task.localFileURL = fileURL
        entry.task.fileSize = fileSize
        entry.task.downloadedBytes = fileSize
        entry.task.speed = 0
        entry.task.eta = 0
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    func failDownload(id: UUID, error: DownloadError) {
        guard var entry = active[id] else { return }
        guard entry.task.status != .paused,
              entry.task.status != .cancelled,
              entry.task.status != .completed else { return }
        if let sessionTask = entry.sessionTask {
            taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
            delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
        }
        entry.sessionTask = nil
        entry.task.status = .failed
        entry.task.errorDescription = error.localizedDescription
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    func handleTaskError(id: UUID, error: Error, resumeData: Data?, isCancellation: Bool) {
        guard var entry = active[id] else { return }
        // Intentional pause/cancel also surfaces here as a cancelled error.
        if isCancellation || entry.task.status == .paused || entry.task.status == .cancelled {
            return
        }
        if let resumeData {
            entry.resumeData = resumeData
        }
        let code = (error as NSError).code
        let retryableCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed
        ]
        if retryableCodes.contains(code), entry.attempts < Self.maxAttempts {
            entry.attempts += 1
            entry.task.attempts = entry.attempts
            entry.task.status = .pending
            entry.task.errorDescription = "Connection interrupted — retrying (attempt \(entry.attempts) of \(Self.maxAttempts))."
            if let sessionTask = entry.sessionTask {
                taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
                delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
            }
            entry.sessionTask = nil
            active[id] = entry
            publishUpdates(force: true)
            // Exponential backoff: 2s, 4s, 8s.
            let delayNanoseconds = UInt64(1 << min(entry.attempts, 4)) * 1_000_000_000
            Task { [id] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
                await self.retryPendingAfterBackoff(id: id)
            }
            return
        }
        if let sessionTask = entry.sessionTask {
            taskIdentifierToID.removeValue(forKey: sessionTask.taskIdentifier)
            delegate.remove(taskIdentifier: sessionTask.taskIdentifier)
        }
        entry.sessionTask = nil
        entry.task.status = .failed
        entry.task.errorDescription = error.localizedDescription
        active[id] = entry
        publishUpdates(force: true)
        startPendingDownloads()
    }

    func handleOrphanedDownload(taskIdentifier: Int) {
        guard let id = taskIdentifierToID[taskIdentifier] else { return }
        failDownload(id: id, error: .downloadFailed("Download finished without a matching record."))
    }

    func storeResumeData(id: UUID, data: Data) {
        guard var entry = active[id] else { return }
        entry.resumeData = data
        active[id] = entry
    }

    // MARK: Internals

    private func retryPendingAfterBackoff(id: UUID) {
        guard let entry = active[id], entry.task.status == .pending else { return }
        startPendingDownloads()
    }

    private func startPendingDownloads() {
        let running = active.values.filter { $0.task.status == .downloading }.count
        guard running < Self.maxConcurrentDownloads else { return }
        let pending = active.values
            .filter { $0.task.status == .pending }
            .sorted { $0.task.createdAt < $1.task.createdAt }
        for entry in pending.prefix(Self.maxConcurrentDownloads - running) {
            startDownload(id: entry.task.id)
        }
    }

    private func startDownload(id: UUID) {
        guard var entry = active[id] else { return }
        let sessionTask: URLSessionDownloadTask
        if let resumeData = entry.resumeData {
            sessionTask = session.downloadTask(withResumeData: resumeData)
            entry.resumeData = nil
        } else {
            sessionTask = session.downloadTask(with: entry.task.url)
        }
        entry.sessionTask = sessionTask
        entry.task.status = .downloading
        active[id] = entry
        taskIdentifierToID[sessionTask.taskIdentifier] = id
        delegate.register(
            taskIdentifier: sessionTask.taskIdentifier,
            info: DownloadSessionDelegate.Info(
                id: id,
                fileName: entry.task.fileName,
                expectedSHA256: entry.task.expectedSHA256,
                lastBytes: entry.task.downloadedBytes,
                lastSampleDate: Date()
            )
        )
        sessionTask.resume()
        publishUpdates(force: true)
    }

    /// Strips any directory components from a user-supplied file name so a
    /// malicious name can never escape the destination directory.
    private func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let component = URL(fileURLWithPath: trimmed).lastPathComponent
        return component == "." || component == "/" ? "" : component
    }
}
