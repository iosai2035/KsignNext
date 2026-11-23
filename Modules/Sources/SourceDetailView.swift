import SwiftUI

@MainActor
final class SourceDetailViewModel: ObservableObject {
    @Published var apps: [SourceListingApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    let source: SourceItem
    private let sourcesModel: SourcesViewModel

    init(source: SourceItem, sourcesModel: SourcesViewModel = SourcesViewModel()) {
        self.source = source
        self.sourcesModel = sourcesModel
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        apps = await sourcesModel.fetchApps(for: source)
        errorMessage = sourcesModel.errorMessage
    }
}

struct SourceDetailView: View {
    let source: SourceItem
    @StateObject private var viewModel: SourceDetailViewModel

    init(source: SourceItem) {
        self.source = source
        _viewModel = StateObject(wrappedValue: SourceDetailViewModel(source: source))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView(NSLocalizedString("common.loading", comment: "")).accessibilityIdentifier("sourceDetail.loading")
            } else if viewModel.apps.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("sources.apps.empty", comment: ""),
                    systemImage: "app.badge",
                    description: Text(NSLocalizedString("sources.apps.empty.detail", comment: ""))
                )
            } else {
                List(viewModel.apps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                        Text("\(app.bundleID) • \(app.version)").font(.caption).foregroundStyle(.secondary)
                        Button(NSLocalizedString("sources.download", comment: "")) {
                            download(app)
                        }
                        .font(.caption)
                        .accessibilityIdentifier("sourceDetail.download.\(app.name)")
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private func download(_ app: SourceListingApp) {
        guard let url = URL(string: app.downloadURLString), url.scheme == "https" else {
            viewModel.errorMessage = NSLocalizedString("downloads.error.url", comment: "")
            return
        }
        guard let destDir = Workspace.folder("Downloads") else { return }
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let dest = destDir.appendingPathComponent(url.lastPathComponent.isEmpty ? "\(app.name).ipa" : url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: tempURL, to: dest)
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}
