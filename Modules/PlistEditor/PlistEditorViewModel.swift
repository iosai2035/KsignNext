import Foundation

/// Plist editor view model. Supports XML and binary plists. A save is refused
/// unless the document round-trips through PropertyListSerialization.
@MainActor
final class PlistEditorViewModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var root: [String: Any] = [:]
    @Published var isArrayRoot = false
    @Published var arrayRoot: [Any] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var lastValidationError: String?

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []

    var isEmpty: Bool { root.isEmpty && arrayRoot.isEmpty }

    func open(_ url: URL) {
        fileURL = url
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = NSLocalizedString("error.file.read", comment: ""); return
        }
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            if let dict = plist as? [String: Any] { root = dict; isArrayRoot = false }
            else if let array = plist as? [Any] { arrayRoot = array; isArrayRoot = true }
            else { errorMessage = NSLocalizedString("plist.error.root", comment: "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func snapshot() {
        if let data = try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0) {
            undoStack.append(data)
            canUndo = true
            redoStack.removeAll()
            canRedo = false
        }
    }

    func currentPlist() -> Any { isArrayRoot ? arrayRoot : root }

    func setValue(key: String, value: Any) {
        snapshot()
        root[key] = value
    }

    func deleteKey(_ key: String) {
        snapshot()
        root.removeValue(forKey: key)
    }

    func addKey(_ key: String, value: Any = "") {
        guard !key.isEmpty, root[key] == nil else {
            errorMessage = NSLocalizedString("plist.error.key", comment: ""); return
        }
        snapshot()
        root[key] = value
    }

    func validate() -> Bool {
        do {
            _ = try PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0)
            lastValidationError = nil
            return true
        } catch {
            lastValidationError = error.localizedDescription
            return false
        }
    }

    func save() -> Bool {
        guard validate() else {
            errorMessage = lastValidationError ?? NSLocalizedString("plist.error.invalid", comment: "")
            return false
        }
        guard let url = fileURL else { return false }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func exportData() -> Data? {
        guard validate() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0)
    }

    func undo() {
        guard let data = undoStack.popLast() else { return }
        if let current = try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0) {
            redoStack.append(current)
        }
        apply(data)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let data = redoStack.popLast() else { return }
        if let current = try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0) {
            undoStack.append(current)
        }
        apply(data)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
        if let dict = plist as? [String: Any] { root = dict; isArrayRoot = false }
        else if let array = plist as? [Any] { arrayRoot = array; isArrayRoot = true }
    }
}
