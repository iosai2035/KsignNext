import SwiftUI

@MainActor
final class SourceDetailViewModel: ObservableObject {
    @Published var apps: [SourceListingApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Load failure for the inline error state (distinct from
    /// `errorMessage`, which is the download-failure alert).
    @Published var loadError: String?
    /// Download URLs already enqueued, so the Download button can be
    /// disabled and the same app cannot be enqueued twice.
    @Published var enqueuedDownloadURLs: Set<String> = []
    let source: SourceItem
    private let sourcesModel: SourcesViewModel

    init(source: SourceItem, sourcesModel: SourcesViewModel = SourcesViewModel()) {
        self.source = source
        self.sourcesModel = sourcesModel
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        errorMessage = nil
        apps = await sourcesModel.fetchApps(for: source)
        // A successful load clears any stale error (fetchApps clears
        // the shared model's error on success); a failure surfaces
        // inline with a Retry button instead of an empty list.
        loadError = sourcesModel.errorMessage
    }

    /// Downloads the app through the shared download engine, so the
    /// download is queued, limited, and visible in the Downloads tab.
    func downloadApp(_ app: SourceListingApp) async {
        guard !enqueuedDownloadURLs.contains(app.downloadURLString) else { return }
        guard let url = URL(string: app.downloadURLString), url.scheme == "https" else {
            errorMessage = NSLocalizedString("downloads.error.url", comment: ""); return
        }
        enqueuedDownloadURLs.insert(app.downloadURLString)
        do {
            let fileName = url.lastPathComponent.isEmpty ? "\(app.name).ipa" : url.lastPathComponent
            _ = try await sourcesModel.enqueueDownload(url: url, fileName: fileName)
        } catch {
            enqueuedDownloadURLs.remove(app.downloadURLString)
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
            } else if let loadError = viewModel.loadError {
                EmptyStateView(
                    NSLocalizedString("sources.apps.loadError", comment: ""),
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                ) {
                    Button(NSLocalizedString("downloads.retry", comment: "")) {
                        Task { await viewModel.load() }
                    }
                    .dsPrimaryButton()
                    .accessibilityIdentifier("sourceDetail.retry")
                }
            } else if viewModel.apps.isEmpty {
                EmptyStateView(
                    NSLocalizedString("sources.apps.empty", comment: ""),
                    systemImage: "app.badge",
                    description: Text(NSLocalizedString("sources.apps.empty.detail", comment: ""))
                ) {
                    Button(NSLocalizedString("common.refresh", comment: "")) {
                        Task { await viewModel.load() }
                    }
                    .dsSecondaryButton()
                    .accessibilityIdentifier("sourceDetail.refresh.empty")
                }
            } else {
                List(viewModel.apps) { app in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(app.name)
                        Text("\(app.bundleID) • \(app.version)").font(.caption).foregroundStyle(.secondary)
                        Button(NSLocalizedString("sources.download", comment: "")) {
                            Task { await viewModel.downloadApp(app) }
                        }
                        .font(.caption)
                        .dsSecondaryButton()
                        .disabled(viewModel.enqueuedDownloadURLs.contains(app.downloadURLString))
                        .accessibilityIdentifier("sourceDetail.download.\(app.name)")
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .dsInlineTitle()
        .task { await viewModel.load() }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }
}
