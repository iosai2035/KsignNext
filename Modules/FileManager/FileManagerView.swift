import SwiftUI

struct WorkspaceFile: Identifiable, Equatable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
    var size: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

enum FileSort: String, CaseIterable { case name, size, date }

@MainActor
final class FileManagerViewModel: ObservableObject {
    @Published var currentDirectory: URL
    @Published var files: [WorkspaceFile] = []
    @Published var searchText = ""
    @Published var sort: FileSort = .name
    @Published var selectedFiles: Set<WorkspaceFile> = []
    @Published var isEditingSelection = false
    @Published var errorMessage: String?
    @Published var newFolderName = ""
    @Published var showNewFolderSheet = false
    @Published var fileToRename: WorkspaceFile?
    @Published var renameText = ""
    @Published var showDeleteConfirm = false

    init() {
        currentDirectory = Workspace.documents ?? FileManager.default.temporaryDirectory
        refresh()
    }

    var filteredFiles: [WorkspaceFile] {
        var list = files
        if !searchText.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        switch sort {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: list.sort { $0.size > $1.size }
        case .date:
            list.sort {
                let a = (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.modificationDate] as? Date) ?? .distantPast
                let b = (try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.modificationDate] as? Date) ?? .distantPast
                return a > b
            }
        }
        return list
    }

    func refresh() {
        let items = (try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        files = items.map { WorkspaceFile(url: $0) }
    }

    func open(_ file: WorkspaceFile) {
        if file.isDirectory { currentDirectory = file.url; refresh() }
    }

    func goUp() {
        guard let docs = Workspace.documents, currentDirectory != docs else { return }
        currentDirectory = currentDirectory.deletingLastPathComponent()
        refresh()
    }

    func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = NSLocalizedString("files.error.foldername", comment: ""); return
        }
        do {
            try FileManager.default.createDirectory(at: currentDirectory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            newFolderName = ""
            showNewFolderSheet = false
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ file: WorkspaceFile) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = NSLocalizedString("files.error.rename", comment: ""); return
        }
        do {
            try FileManager.default.moveItem(at: file.url, to: file.url.deletingLastPathComponent().appendingPathComponent(name))
            fileToRename = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ file: WorkspaceFile) {
        do { try FileManager.default.removeItem(at: file.url); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSelected() {
        for file in selectedFiles { try? FileManager.default.removeItem(at: file.url) }
        selectedFiles.removeAll()
        isEditingSelection = false
        refresh()
    }
}

struct FileManagerView: View {
    @StateObject private var viewModel = FileManagerViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.filteredFiles.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("files.empty", comment: ""),
                        systemImage: "folder",
                        description: Text(NSLocalizedString("files.empty.detail", comment: ""))
                    )
                } else {
                    List(viewModel.filteredFiles, selection: $viewModel.selectedFiles) { file in
                        Button { viewModel.open(file) } label: {
                            HStack {
                                Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                                VStack(alignment: .leading) {
                                    Text(file.name).lineLimit(1)
                                    if !file.isDirectory {
                                        Text(Workspace.fileSizeString(file.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("files.row.\(file.name)")
                        .swipeActions {
                            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { viewModel.delete(file) }
                            Button(NSLocalizedString("files.rename", comment: "")) {
                                viewModel.fileToRename = file
                                viewModel.renameText = file.name
                            }
                        }
                    }
                    .environment(\.editMode, .constant(viewModel.isEditingSelection ? .active : .inactive))
                }
            }
            .navigationTitle(viewModel.currentDirectory.lastPathComponent)
            .searchable(text: $viewModel.searchText, prompt: NSLocalizedString("files.search", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("files.up", comment: "")) { viewModel.goUp() }
                        .disabled(viewModel.currentDirectory == Workspace.documents)
                        .accessibilityIdentifier("files.up")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker(NSLocalizedString("apps.sort", comment: ""), selection: $viewModel.sort) {
                            ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label(NSLocalizedString("apps.sort", comment: ""), systemImage: "arrow.up.arrow.down") }
                    Button(viewModel.isEditingSelection ? NSLocalizedString("common.done", comment: "") : NSLocalizedString("common.select", comment: "")) {
                        viewModel.isEditingSelection.toggle()
                        if !viewModel.isEditingSelection { viewModel.selectedFiles.removeAll() }
                    }
                    .accessibilityIdentifier("files.select")
                    Button(NSLocalizedString("files.newfolder", comment: "")) { viewModel.showNewFolderSheet = true }
                        .accessibilityIdentifier("files.newFolder")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isEditingSelection && !viewModel.selectedFiles.isEmpty {
                    Button(role: .destructive) { viewModel.showDeleteConfirm = true } label: {
                        Text(String(format: NSLocalizedString("files.delete.selected", comment: ""), viewModel.selectedFiles.count))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding()
                    .accessibilityIdentifier("files.deleteSelected")
                }
            }
            .onAppear { viewModel.refresh() }
            .sheet(isPresented: $viewModel.showNewFolderSheet) {
                NavigationStack {
                    Form {
                        TextField(NSLocalizedString("files.folder.name", comment: ""), text: $viewModel.newFolderName)
                            .accessibilityIdentifier("files.folderNameField")
                    }
                    .navigationTitle(NSLocalizedString("files.newfolder", comment: ""))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("common.cancel", comment: "")) { viewModel.showNewFolderSheet = false } }
                        ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("common.create", comment: "")) { viewModel.createFolder() } }
                    }
                }
            }
            .alert(NSLocalizedString("files.rename", comment: ""), isPresented: Binding(get: { viewModel.fileToRename != nil }, set: { if !$0 { viewModel.fileToRename = nil } })) {
                TextField(NSLocalizedString("files.rename", comment: ""), text: $viewModel.renameText)
                Button(NSLocalizedString("common.save", comment: "")) {
                    if let file = viewModel.fileToRename { viewModel.rename(file) }
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { viewModel.fileToRename = nil }
            }
            .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: $viewModel.showDeleteConfirm) {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { viewModel.deleteSelected() }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }
}
