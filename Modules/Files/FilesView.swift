import SwiftUI
import UniformTypeIdentifiers

/// Files tab (contract §C.4): browse the app sandbox starting at
/// `Documents/KsignNext`. Recursive push into subfolders (unbounded),
/// create folder, import, share, rename, delete. Tap rules per
/// extension: `.p12` / `.mobileprovision` → Certificates import flow
/// via the coordinator; every other file → action sheet with Share /
/// Rename / Delete. No fake editors, no "unsupported" alerts, and no
/// file is opened, parsed or previewed in Phase 1.
struct FilesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var viewModel: FilesViewModel
    @State private var showImporter = false
    @State private var showNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var fileForActions: FileSystemManager.FileEntry?
    @State private var fileToDelete: FileSystemManager.FileEntry?
    @State private var fileToRename: FileSystemManager.FileEntry?
    @State private var renameText = ""
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    /// Root browser (the Files tab). Subfolders use `init(directory:)`.
    init() {
        _viewModel = StateObject(wrappedValue: FilesViewModel(
            directory: FileSystemManager.shared.workspaceRoot
        ))
    }

    init(directory: URL) {
        _viewModel = StateObject(wrappedValue: FilesViewModel(directory: directory))
    }

    private var isRoot: Bool {
        viewModel.directory == FileSystemManager.shared.workspaceRoot
    }

    var body: some View {
        Group {
            if let errorMessage = viewModel.errorMessage, viewModel.entries.isEmpty {
                // Directory-read failure: an error row, never an
                // empty list (W-11).
                List {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityLabel(errorMessage)
                }
            } else if viewModel.entries.isEmpty {
                VStack {
                    Spacer()
                    Text(Loc.string("files.empty"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Loc.string("files.empty"))
                    Text(Loc.string("files.empty.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.entries, id: \.url) { entry in
                        row(for: entry)
                    }
                }
            }
        }
        .navigationTitle(isRoot ? Loc.string("tab.files") : viewModel.folderName)
        .dsLargeTitle()
        .dsSideMenuButton()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("files.import"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newFolderName = ""
                    showNewFolderDialog = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("files.newfolder"))
            }
        }
        .task { viewModel.refresh() }
        .task(id: coordinator.filesChangedToken) { viewModel.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                _ = viewModel.importFile(url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .alert(Loc.string("files.newfolder.title"), isPresented: $showNewFolderDialog) {
            TextField(Loc.string("files.folder.name"), text: $newFolderName)
            Button(Loc.string("common.create")) {
                _ = viewModel.createFolder(named: newFolderName)
            }
            Button(Loc.string("common.cancel"), role: .cancel) {}
        }
        .alert(Loc.string("files.rename.title"), isPresented: Binding(
            get: { fileToRename != nil },
            set: { if !$0 { fileToRename = nil } }
        )) {
            TextField(Loc.string("files.folder.name"), text: $renameText)
            Button(Loc.string("common.rename")) {
                if let entry = fileToRename {
                    _ = viewModel.rename(entry, to: renameText)
                }
                fileToRename = nil
            }
            Button(Loc.string("common.cancel"), role: .cancel) { fileToRename = nil }
        }
        .confirmationDialog(
            fileForActions?.name ?? "",
            isPresented: Binding(
                get: { fileForActions != nil },
                set: { if !$0 { fileForActions = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(Loc.string("common.share")) {
                if let entry = fileForActions {
                    shareURL = entry.url
                    showShareSheet = true
                }
                fileForActions = nil
            }
            Button(Loc.string("common.rename")) {
                if let entry = fileForActions {
                    renameText = entry.name
                    fileToRename = entry
                }
                fileForActions = nil
            }
            Button(Loc.string("common.delete"), role: .destructive) {
                if let entry = fileForActions { fileToDelete = entry }
                fileForActions = nil
            }
            Button(Loc.string("common.cancel"), role: .cancel) { fileForActions = nil }
        }
        .alert(Loc.string("common.delete.confirm"), isPresented: Binding(
            get: { fileToDelete != nil },
            set: { if !$0 { fileToDelete = nil } }
        )) {
            Button(Loc.string("common.delete"), role: .destructive) {
                if let entry = fileToDelete {
                    _ = viewModel.delete(entry)
                }
                fileToDelete = nil
            }
            Button(Loc.string("common.cancel"), role: .cancel) { fileToDelete = nil }
        }
        .alert(Loc.string("alert.error.title"), isPresented: Binding(
            get: { viewModel.errorMessage != nil && !viewModel.entries.isEmpty },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(Loc.string("common.ok"), role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    @ViewBuilder
    private func row(for entry: FileSystemManager.FileEntry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry.url) {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(DS.ColorPalette.accentBrand)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer()
                    if let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: DS.Accessibility.minTouchTarget)
            }
            .accessibilityLabel(entry.name)
            .swipeActions {
                Button(Loc.string("common.delete"), role: .destructive) { fileToDelete = entry }
                    .accessibilityLabel(Loc.string("common.delete"))
            }
        } else {
            Button {
                tapFile(entry)
            } label: {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(entry.name)
                            .lineLimit(1)
                        if let size = entry.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: DS.Accessibility.minTouchTarget)
            }
            .accessibilityLabel(entry.name)
            .swipeActions {
                Button(Loc.string("common.delete"), role: .destructive) { fileToDelete = entry }
                    .accessibilityLabel(Loc.string("common.delete"))
            }
        }
    }

    private func icon(for entry: FileSystemManager.FileEntry) -> String {
        switch entry.url.pathExtension.lowercased() {
        case "p12": return "key.fill"
        case "mobileprovision": return "doc.badge.gearshape"
        case "ipa", "tipa": return "app.badge"
        default: return "doc"
        }
    }

    /// Tap rules (§C.4). Certificate files route into the
    /// Certificates import flow; every other file gets the Share /
    /// Rename / Delete action sheet.
    private func tapFile(_ entry: FileSystemManager.FileEntry) {
        switch entry.url.pathExtension.lowercased() {
        case "p12":
            coordinator.pendingP12ImportURL = entry.url
            coordinator.presentedSheet = .p12PasswordPrompt(entry.url)
            coordinator.openCertificatesManager()
        case "mobileprovision":
            Task {
                let ok = await coordinator.certificatesViewModel.importProfile(url: entry.url)
                if !ok, let message = coordinator.certificatesViewModel.errorMessage {
                    coordinator.showErrorMessage(message)
                } else {
                    coordinator.openCertificatesManager()
                }
            }
        default:
            fileForActions = entry
        }
    }
}
