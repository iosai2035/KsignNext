import Foundation

/// File access confined to the app workspace.
///
/// Every path is resolved (symlinks included) and checked to stay under
/// the workspace root before any read/write/delete. This is the defence
/// against path traversal in IPA entries, user-supplied paths and
/// downloaded files.
///
/// All failures throw `AppError` (normalised from the bare `IPAError`
/// the old code threw, per the Phase 1 contract §B.1).
public final class FileSystemManager: @unchecked Sendable {
    public static let shared = FileSystemManager()

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
    /// workspace root; otherwise throws
    /// `AppError.ipa(.pathTraversalAttempt)`.
    public func validatedURL(forRelativePath relativePath: String) throws -> URL {
        let candidate = workspaceRoot.appendingPathComponent(relativePath)
        return try validatedURL(candidate)
    }

    public func validatedURL(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        let root = workspaceRoot.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
            throw AppError.ipa(.pathTraversalAttempt(entry: url.path))
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
        case inbox = "Inbox"
    }

    public func folder(_ folder: WorkspaceFolder) throws -> URL {
        let url = workspaceRoot.appendingPathComponent(folder.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func ensureWorkspaceExists() throws {
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        for folder in [WorkspaceFolder.imported, .signed, .certificates, .downloads, .temp, .tweaks, .inbox] {
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
            throw AppError.ipa(.fileNotFound(path: safeURL.path))
        }
        do {
            return try Data(contentsOf: safeURL)
        } catch {
            throw AppError.ipa(.unreadable(path: safeURL.path))
        }
    }

    public func fileSize(at url: URL) throws -> Int64 {
        let safeURL = try validatedURL(url)
        let attributes = try fileManager.attributesOfItem(atPath: safeURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw AppError.ipa(.unreadable(path: safeURL.path))
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

    // MARK: - Directory listing

    public struct FileEntry: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let isDirectory: Bool
        public let size: Int64?
        public let modificationDate: Date?
    }

    /// Lists a directory inside the workspace. Read errors throw — the
    /// caller must surface them, never render an empty list (W-11).
    public func listDirectory(at url: URL) throws -> [FileEntry] {
        let safeURL = try validatedURL(url)
        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw AppError.ipa(.fileNotFound(path: safeURL.path))
        }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: safeURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
        } catch {
            throw AppError.ipa(.unreadable(path: safeURL.path))
        }
        return contents.map { item in
            var isDirectory = false
            var size: Int64?
            var modificationDate: Date?
            do {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                isDirectory = values.isDirectory ?? false
                if let fileSize = values.fileSize {
                    size = Int64(fileSize)
                }
                modificationDate = values.contentModificationDate
            } catch {
                // Per-entry metadata is best-effort; the entry itself
                // is still listed. A failed directory read throws above.
            }
            return FileEntry(
                url: item,
                name: item.lastPathComponent,
                isDirectory: isDirectory,
                size: size,
                modificationDate: modificationDate
            )
        }
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
        do {
            let safeURL = try validatedURL(url)
            try fileManager.removeItem(at: safeURL)
        } catch {
            // Best-effort cleanup only; failures are ignored by design.
        }
    }

    /// Removes temp directories older than `maxAge` (default 24h).
    public func cleanupStaleTempDirectories(maxAge: TimeInterval = 86_400) {
        do {
            let base = try folder(.temp)
            let contents = try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])
            let cutoff = Date().addingTimeInterval(-maxAge)
            for item in contents {
                do {
                    let date = try item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if let date, date < cutoff {
                        try fileManager.removeItem(at: item)
                    }
                } catch {
                    // One stale entry failing must not stop the sweep.
                    continue
                }
            }
        } catch {
            // No temp folder (or unreadable): nothing to clean.
        }
    }

    /// Free space (bytes) on the volume containing the workspace.
    /// `nil` means unknown; never throws.
    public func freeSpaceBytes() -> Int64? {
        do {
            let values = try workspaceRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
    }
}
