import SwiftUI
import UniformTypeIdentifiers

struct StoredApp: Identifiable, Equatable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var size: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
    var isSigned: Bool { url.path.contains("SignedApps") }
}

enum AppSort: String, CaseIterable { case name, size, date }

@MainActor
final class ApplicationsViewModel: ObservableObject {
    @Published var apps: [StoredApp] = []
    @Published var searchText = ""
    @Published var sort: AppSort = .name
    @Published var showSignedOnly = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showImporter = false

    /// The app's container, exposed so the view can hand it to the
    /// detail screen (real inspection + sign navigation).
    let container: DependencyContainer

    /// - Parameter container: the app's container; nil builds a fresh
    ///   one (tests / previews).
    init(container: DependencyContainer? = nil) {
        self.container = container ?? DependencyContainer()
    }

    var filteredApps: [StoredApp] {
        var list = apps
        if showSignedOnly { list = list.filter(\.isSigned) }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
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
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        guard let docs = Workspace.documents else { errorMessage = NSLocalizedString("error.documents.unavailable", comment: ""); return }
        var found: [StoredApp] = []
        for folder in ["ImportedApps", "SignedApps"] {
            let dir = docs.appendingPathComponent(folder, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { $0.pathExtension.lowercased() == "ipa" }.map { StoredApp(url: $0) }
        }
        apps = found
    }

    /// Imports an IPA through `ImportIPAUseCase`: the engine validates
    /// the ZIP structure and reads its metadata, and the use case
    /// saves the `ImportedApplication` record (previously importing
    /// copied the file and created no record at all). The validated
    /// file is then also copied into Documents/ImportedApps, which is
    /// where the app list and the Signing Center look for apps.
    func importIPA(_ url: URL) async {
        do {
            _ = try await container.makeImportIPAUseCase().execute(url: url)
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = NSLocalizedString("error.file.access", comment: ""); return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let destDir = Workspace.folder("ImportedApps") else { return }
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ app: StoredApp) {
        do {
            try FileManager.default.removeItem(at: app.url)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func exportURL(for app: StoredApp) -> URL { app.url }
}

struct ApplicationsView: View {
    @StateObject private var viewModel: ApplicationsViewModel
    @State private var appToDelete: StoredApp?
    @State private var selectedApp: StoredApp?

    /// - Parameter container: the app's container; nil builds a fresh
    ///   one (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: ApplicationsViewModel(container: container))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView(NSLocalizedString("common.loading", comment: "")).accessibilityIdentifier("apps.loading")
                } else if viewModel.filteredApps.isEmpty {
                    EmptyStateView(
                        NSLocalizedString("apps.empty", comment: ""),
                        systemImage: "app.badge",
                        description: Text(NSLocalizedString("apps.empty.detail", comment: ""))
                    ) {
                        Button(NSLocalizedString("apps.import", comment: "")) { viewModel.showImporter = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("apps.import.empty")
                    }
                } else {
                    List(viewModel.filteredApps) { app in
                        Button { selectedApp = app } label: {
                            HStack {
                                Image(systemName: app.isSigned ? "checkmark.seal.fill" : "app.badge")
                                    .foregroundStyle(app.isSigned ? .green : .accentColor)
                                VStack(alignment: .leading) {
                                    Text(app.name).lineLimit(1)
                                    Text(Workspace.fileSizeString(app.size)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.isSigned { Text(NSLocalizedString("apps.signed", comment: "")).font(.caption).foregroundStyle(.green) }
                            }
                        }
                        .accessibilityIdentifier("apps.row.\(app.name)")
                        .swipeActions {
                            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { appToDelete = app }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tab.applications", comment: ""))
            .searchable(text: $viewModel.searchText, prompt: NSLocalizedString("apps.search", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker(NSLocalizedString("apps.sort", comment: ""), selection: $viewModel.sort) {
                            ForEach(AppSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle(NSLocalizedString("apps.signed.only", comment: ""), isOn: $viewModel.showSignedOnly)
                    } label: { Label(NSLocalizedString("apps.sort", comment: ""), systemImage: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("apps.import", comment: "")) { viewModel.showImporter = true }
                        .accessibilityIdentifier("apps.import")
                }
            }
            .fileImporter(isPresented: $viewModel.showImporter, allowedContentTypes: [.init(filenameExtension: "ipa") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await viewModel.importIPA(url) } }
                case .failure(let error): viewModel.errorMessage = error.localizedDescription
                }
            }
            .onAppear { viewModel.refresh() }
            .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: Binding(get: { appToDelete != nil }, set: { if !$0 { appToDelete = nil } })) {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                    if let app = appToDelete { viewModel.delete(app) }
                    appToDelete = nil
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { appToDelete = nil }
            } message: { Text(appToDelete?.name ?? "") }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
            // `navigationDestination(item:)` needs iOS 17; the `isPresented`
            // variant works from iOS 16.
            .navigationDestination(isPresented: Binding(get: { selectedApp != nil }, set: { if !$0 { selectedApp = nil } })) {
                if let app = selectedApp { ApplicationDetailView(app: app, container: viewModel.container, onDeleted: { viewModel.refresh() }) }
            }
        }
    }
}
