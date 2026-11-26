import Foundation

/// Plist editor view model. Supports XML and binary plists. A save is refused
/// unless the document round-trips through PropertyListSerialization.
@MainActor
final class PlistEditorViewModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var root: [String: Any] = [:]
    @Published var isArrayRoot = false
    @Published var arrayRoot: [Any] = []
    @Published var errorMessage: String?
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var lastValidationError: String?
    /// Increments on every committed document change, so the view can
    /// clear transient UI (e.g. the "saved" banner) on the next edit.
    @Published var revision = 0

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    /// True while a text field is being edited: the snapshot is taken
    /// once when editing begins, not once per keystroke.
    private var editSessionOpen = false

    var isEmpty: Bool { root.isEmpty && arrayRoot.isEmpty }

    func open(_ url: URL) {
        fileURL = url
        // Synchronous local read: no loading state is shown for it.
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

    /// Begins a text-edit session: takes the undo snapshot once. A
    /// matching `endEdit()` closes the session. `setValue` outside a
    /// session still snapshots, so single programmatic edits keep one
    /// undo step each.
    func beginEdit() {
        guard !editSessionOpen else { return }
        editSessionOpen = true
        snapshot()
    }

    func endEdit() { editSessionOpen = false }

    func setValue(key: String, value: Any) {
        if !editSessionOpen { snapshot() }
        root[key] = value
        revision += 1
    }

    /// Edits one scalar item of an array-root plist.
    func setArrayValue(index: Int, value: Any) {
        guard arrayRoot.indices.contains(index) else { return }
        if !editSessionOpen { snapshot() }
        arrayRoot[index] = value
        revision += 1
    }

    func deleteKey(_ key: String) {
        snapshot()
        root.removeValue(forKey: key)
        revision += 1
    }

    func addKey(_ key: String, value: Any = "") {
        guard !key.isEmpty, root[key] == nil else {
            errorMessage = NSLocalizedString("plist.error.key", comment: ""); return
        }
        snapshot()
        root[key] = value
        revision += 1
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

    /// Writes the current plist to a real `.plist` file in the temp
    /// directory (named after the edited file), so sharing carries a
    /// filename and the `.plist` type instead of anonymous raw data.
    func exportURL() -> URL? {
        guard let data = exportData() else { return nil }
        let name = fileURL?.lastPathComponent ?? "export.plist"
        let fileName = name.lowercased().hasSuffix(".plist") ? name : "\(name).plist"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func undo() {
        guard let data = undoStack.popLast() else { return }
        if let current = try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0) {
            redoStack.append(current)
        }
        apply(data)
        revision += 1
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let data = redoStack.popLast() else { return }
        if let current = try? PropertyListSerialization.data(fromPropertyList: currentPlist(), format: .xml, options: 0) {
            undoStack.append(current)
        }
        apply(data)
        revision += 1
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
        if let dict = plist as? [String: Any] { root = dict; isArrayRoot = false }
        else if let array = plist as? [Any] { arrayRoot = array; isArrayRoot = true }
    }
}
