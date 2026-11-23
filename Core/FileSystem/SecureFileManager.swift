import Foundation

/// File access confined to the app workspace.
///
/// Every path is resolved (symlinks included) and checked to stay under
/// the workspace root before any read/write/delete. This is the defence
/// against path traversal in IPA entries, user-supplied paths and
/// downloaded files.
public final class SecureFileManager {
    public static let shared = SecureFileManager()

    /// Workspace limits (prompt §5/§19): reject oversized or over-numerous
    /// archives before extraction.
    public static let maxIPABytes: Int64 = 2_147_483_648 // 2 GiB
    public static let maxArchiveEntries = 50_000
    public static let maxDecompressedBytes: Int64 = 8_589_934_592 // 8 GiB
    public static let maxSingleFileBytes: Int64 = 1_073_741_824 // 1 GiB
    public static let maxDecompressionRatio: Double = 100.0

    public let workspaceRoot: URL
    private let fileManager = FileManager.default

    public init(workspaceRoot: URL? = nil) {
        if let workspaceRoot {
            self.workspaceRoot = workspaceRoot
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.workspaceRoot = documents.appendingPathComponent("KsignNext", isDirectory: true)
        }
    }

    // MARK: - Path safety

    /// Resolves symlinks and returns the URL only if it stays under the
    /// workspace root; otherwise throws `IPAError.pathTraversalAttempt`.
    public func validatedURL(forRelativePath relativePath: String) throws -> URL {
        let candidate = workspaceRoot.appendingPathComponent(relativePath)
        return try validatedURL(candidate)
    }

    public func validatedURL(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        let root = workspaceRoot.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
            throw IPAError.pathTraversalAttempt(entry: url.path)
        }
        return resolved
    }

    /// `true` if `url` (after symlink resolution) stays inside `directory`.
    public static func isPath(_ url: URL, inside directory: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let root = directory.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return resolved.path == root.path || resolved.path.hasPrefix(rootPath)
    }

    // MARK: - Workspace layout

    public enum WorkspaceFolder: String {
        case imported = "Imported"
        case signed = "Signed"
        case certificates = "Certificates"
        case downloads = "Downloads"
        case temp = "Temp"
        case tweaks = "Tweaks"
    }

    public func folder(_ folder: WorkspaceFolder) throws -> URL {
        let url = workspaceRoot.appendingPathComponent(folder.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func ensureWorkspaceExists() throws {
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        for folder in [WorkspaceFolder.imported, .signed, .certificates, .downloads, .temp, .tweaks] {
            _ = try self.folder(folder)
        }
    }

    // MARK: - Atomic writes / reads

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let safeURL = try validatedURL(url)
        try fileManager.createDirectory(at: safeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: safeURL, options: .atomic)
    }

    public func readData(at url: URL) throws -> Data {
        let safeURL = try validatedURL(url)
        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw IPAError.fileNotFound(path: safeURL.path)
        }
        do {
            return try Data(contentsOf: safeURL)
        } catch {
            throw IPAError.unreadable(path: safeURL.path)
        }
    }

    public func fileSize(at url: URL) throws -> Int64 {
        let safeURL = try validatedURL(url)
        let attributes = try fileManager.attributesOfItem(atPath: safeURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw IPAError.unreadable(path: safeURL.path)
        }
        return size.int64Value
    }

    public func delete(at url: URL) throws {
        let safeURL = try validatedURL(url)
        guard fileManager.fileExists(atPath: safeURL.path) else { return }
        try fileManager.removeItem(at: safeURL)
    }

    public func move(from source: URL, to destination: URL) throws {
        let safeDestination = try validatedURL(destination)
        try fileManager.createDirectory(at: safeDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: safeDestination.path) {
            try fileManager.removeItem(at: safeDestination)
        }
        try fileManager.moveItem(at: source, to: safeDestination)
    }

    // MARK: - Temp directories

    /// Creates a uniquely named temp directory inside the workspace temp
    /// folder. The caller owns cleanup via `cleanupTempDirectory(_:)`.
    public func createTempDirectory(named name: String? = nil) throws -> URL {
        let base = try folder(.temp)
        let directory = base.appendingPathComponent(name ?? UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func cleanupTempDirectory(_ url: URL) {
        guard let safeURL = try? validatedURL(url) else { return }
        try? fileManager.removeItem(at: safeURL)
    }

    /// Removes temp directories older than `maxAge` (default 24h).
    public func cleanupStaleTempDirectories(maxAge: TimeInterval = 86_400) {
        guard let base = try? folder(.temp),
              let contents = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for item in contents {
            if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    /// Free space (bytes) on the volume containing the workspace.
    public func freeSpaceBytes() -> Int64? {
        guard let values = try? workspaceRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }
}
