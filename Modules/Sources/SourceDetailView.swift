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
        // SRC-1: an app with no version has no download URL — the
        // row's button is disabled, and this is a no-op guard.
        guard let urlString = app.downloadURLString,
              !enqueuedDownloadURLs.contains(urlString) else { return }
        guard let url = URL(string: urlString), url.scheme == "https" else {
            errorMessage = NSLocalizedString("downloads.error.url", comment: ""); return
        }
        enqueuedDownloadURLs.insert(urlString)
        do {
            let fileName = url.lastPathComponent.isEmpty ? "\(app.name).ipa" : url.lastPathComponent
            _ = try await sourcesModel.enqueueDownload(url: url, fileName: fileName)
        } catch {
            enqueuedDownloadURLs.remove(urlString)
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
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        // SRC-3: the source's own icon (56×56; a
                        // placeholder glyph while loading, on failure,
                        // or when the source gives no icon at all).
                        AsyncImage(url: app.iconURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure, .empty:
                                Image(systemName: "app.badge")
                                    .foregroundStyle(.secondary)
                            @unknown default:
                                Image(systemName: "app.badge")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .background(DS.ColorPalette.cardBackground, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
                        .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius))
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(app.name)
                            Text("\(app.bundleID) • \(app.version)").font(.caption).foregroundStyle(.secondary)
                            if let description = app.localizedDescription, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if let size = app.size, size > 0, let date = app.date {
                                Text("\(Workspace.fileSizeString(size)) • \(date, style: .date)").font(.caption).foregroundStyle(.secondary)
                            } else if let size = app.size, size > 0 {
                                Text(Workspace.fileSizeString(size)).font(.caption).foregroundStyle(.secondary)
                            } else if let date = app.date {
                                Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Button(NSLocalizedString("sources.download", comment: "")) {
                                Task { await viewModel.downloadApp(app) }
                            }
                            .font(.caption)
                            .dsSecondaryButton()
                            .disabled(app.downloadURLString == nil || viewModel.enqueuedDownloadURLs.contains(app.downloadURLString ?? ""))
                            .accessibilityIdentifier("sourceDetail.download.\(app.name)")
                        }
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
