import Foundation

public enum DownloadStatus: String, Codable, CaseIterable {
    case pending
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public struct DownloadTaskModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var url: URL
    public var fileName: String
    public var destinationURL: URL?
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var currentStage: String
    public var progress: Double // 0.0...1.0
    public var status: DownloadStatus
    public var error: String?
    public var expectedChecksum: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        destinationURL: URL? = nil,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        currentStage: String = "Queued",
        progress: Double = 0,
        status: DownloadStatus = .queued,
        error: String? = nil,
        expectedChecksum: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.destinationURL = destinationURL
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.currentStage = currentStage
        self.progress = progress
        self.status = status
        self.error = error
        self.expectedChecksum = expectedChecksum
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Bytes per second over the elapsed time, if measurable.
    public func speedBytesPerSecond(now: Date = Date()) -> Double? {
        guard let startedAt, status == .downloading else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        return Double(downloadedBytes) / elapsed
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard let totalBytes, totalBytes > downloadedBytes,
              let speed = speedBytesPerSecond(), speed > 0 else { return nil }
        return Double(totalBytes - downloadedBytes) / speed
    }
}
