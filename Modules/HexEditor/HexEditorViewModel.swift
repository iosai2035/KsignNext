import Foundation

/// Hex editor view model. Files are paged in 64 KB chunks — huge files are never
/// loaded fully into memory. Editing is disabled for executables unless the user
/// explicitly switches off read-only mode.
@MainActor
final class HexEditorViewModel: ObservableObject {
    static let chunkSize = 64 * 1024

    @Published var fileURL: URL?
    @Published var fileSize: Int64 = 0
    @Published var currentPage = 0
    @Published var pageData: Data = Data()
    @Published var isReadOnly = true
    @Published var searchText = ""
    @Published var searchResults: [Int64] = []
    @Published var errorMessage: String?
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var editedOffsets: [Int64: UInt8] = [:]

    private var undoStack: [(offset: Int64, oldValue: UInt8, newValue: UInt8)] = []
    private var redoStack: [(offset: Int64, oldValue: UInt8, newValue: UInt8)] = []

    var pageCount: Int {
        guard fileSize > 0 else { return 0 }
        return Int((fileSize + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))
    }

    var isExecutable: Bool {
        guard let url = fileURL else { return false }
        return ["", "dylib"].contains(url.pathExtension.lowercased()) || url.lastPathComponent.contains("Payload")
    }

    func open(_ url: URL) {
        fileURL = url
        fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        currentPage = 0
        editedOffsets.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        isReadOnly = true
        loadPage(0)
    }

    func loadPage(_ page: Int) {
        guard let url = fileURL, page >= 0, page < pageCount else { return }
        currentPage = page
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            errorMessage = NSLocalizedString("error.file.read", comment: ""); return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(page * Self.chunkSize))
            pageData = try handle.read(upToCount: Self.chunkSize) ?? Data()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goToOffset(_ offset: Int64) {
        guard offset >= 0, offset < fileSize else {
            errorMessage = NSLocalizedString("hex.error.offset", comment: ""); return
        }
        loadPage(Int(offset) / Self.chunkSize)
    }

    func search(_ needle: String) {
        searchResults = []
        guard let url = fileURL, !needle.isEmpty else { return }
        let bytes = [UInt8](needle.utf8)
        guard !bytes.isEmpty else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var offset: Int64 = 0
        var previousTail = Data()
        while offset < fileSize {
            guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            let combined = previousTail + chunk
            let combinedBytes = [UInt8](combined)
            if combinedBytes.count >= bytes.count {
                for i in 0...(combinedBytes.count - bytes.count) {
                    if Array(combinedBytes[i..<(i + bytes.count)]) == bytes {
                        searchResults.append(offset - Int64(previousTail.count) + Int64(i))
                        if searchResults.count >= 100 { return }
                    }
                }
            }
            previousTail = chunk.suffix(bytes.count - 1)
            offset += Int64(chunk.count)
        }
    }

    func byte(at absoluteOffset: Int64) -> UInt8? {
        if let edited = editedOffsets[absoluteOffset] { return edited }
        let page = Int(absoluteOffset) / Self.chunkSize
        guard page == currentPage else { return nil }
        let index = Int(absoluteOffset) % Self.chunkSize
        guard index < pageData.count else { return nil }
        return pageData[index]
    }

    func editByte(at absoluteOffset: Int64, to newValue: UInt8) {
        guard !isReadOnly else {
            errorMessage = NSLocalizedString("hex.error.readonly", comment: ""); return
        }
        guard absoluteOffset >= 0, absoluteOffset < fileSize else { return }
        let oldValue = byte(at: absoluteOffset) ?? 0
        editedOffsets[absoluteOffset] = newValue
        undoStack.append((offset: absoluteOffset, oldValue: oldValue, newValue: newValue))
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        editedOffsets[last.offset] = last.oldValue
        redoStack.append(last)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        editedOffsets[last.offset] = last.newValue
        undoStack.append(last)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    func save() throws {
        guard let url = fileURL, !editedOffsets.isEmpty else { return }
        guard !isReadOnly else { throw HexEditorError.readOnly }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for (offset, value) in editedOffsets {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data([value]))
        }
        editedOffsets.removeAll()
        loadPage(currentPage)
    }

    enum HexEditorError: LocalizedError {
        case readOnly
        var errorDescription: String? { NSLocalizedString("hex.error.readonly", comment: "") }
    }
}
