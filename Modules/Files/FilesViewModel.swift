import Foundation

/// Files browser state (contract §C.4). Reads go through
/// `FileSystemManager.listDirectory`, whose failures throw — a
/// directory-read failure is surfaced in `errorMessage` and shown
/// as an error row, never as a silent empty list (`?? []` is
/// forbidden, W-11).
@MainActor
final class FilesViewModel: ObservableObject {
    @Published var entries: [FileSystemManager.FileEntry] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    let directory: URL
    private let files: FileSystemManager

    init(directory: URL, files: FileSystemManager = .shared) {
        self.directory = directory
        self.files = files
    }

    var folderName: String {
        directory.lastPathComponent
    }

    func refresh() {
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try files.listDirectory(at: directory)
            entries = listed.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            errorMessage = Loc.string("files.error.foldername")
            return false
        }
        let url = directory.appendingPathComponent(trimmed, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: FileSystemManager.FileEntry) -> Bool {
        do {
            try files.delete(at: entry.url)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ entry: FileSystemManager.FileEntry, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            errorMessage = Loc.string("files.error.rename")
            return false
        }
        let destination = entry.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try files.move(from: entry.url, to: destination)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Copies a picked file into the current folder. Returns false
    /// (with `errorMessage` set) on any failure.
    func importFile(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
