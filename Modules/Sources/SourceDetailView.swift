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

    /// Downloads the app through the shared download engine, so the
    /// download is queued, limited, and visible in the Downloads tab.
    func downloadApp(_ app: SourceListingApp) async {
        guard let url = URL(string: app.downloadURLString), url.scheme == "https" else {
            errorMessage = NSLocalizedString("downloads.error.url", comment: ""); return
        }
        do {
            let fileName = url.lastPathComponent.isEmpty ? "\(app.name).ipa" : url.lastPathComponent
            _ = try await sourcesModel.enqueueDownload(url: url, fileName: fileName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SourceDetailView: View {
    let source: SourceItem
    @StateObject private var viewModel: SourceDetailViewModel

    init(source: SourceItem, sourcesModel: SourcesViewModel = SourcesViewModel()) {
        self.source = source
        _viewModel = StateObject(wrappedValue: SourceDetailViewModel(source: source, sourcesModel: sourcesModel))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView(NSLocalizedString("common.loading", comment: "")).accessibilityIdentifier("sourceDetail.loading")
            } else if viewModel.apps.isEmpty {
                EmptyStateView(
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
                            Task { await viewModel.downloadApp(app) }
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
}
