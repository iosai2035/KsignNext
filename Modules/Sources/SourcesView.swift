import SwiftUI

struct SourceListingApp: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var bundleID: String
    var version: String
    var downloadURLString: String
}

struct SourceItem: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var urlString: String
    var lastRefreshed: Date?
    init(id: UUID = UUID(), name: String, urlString: String, lastRefreshed: Date? = nil) {
        self.id = id; self.name = name; self.urlString = urlString; self.lastRefreshed = lastRefreshed
    }
}

private struct SourceFeed: Decodable {
    var apps: [SourceFeedApp]?
    struct SourceFeedApp: Decodable { var name: String?; var bundleID: String?; var version: String?; var downloadURL: String? }
}

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var sources: [SourceItem] = []
    @Published var newSourceName = ""
    @Published var newSourceURL = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let storageKey = "ksign.sources"

    init() { loadStored() }

    private func loadStored() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SourceItem].self, from: data) else { return }
        sources = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func addSource() {
        let name = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = URL(string: urlString), url.scheme == "https" else {
            errorMessage = NSLocalizedString("sources.error.url", comment: ""); return
        }
        sources.append(SourceItem(name: name, urlString: urlString))
        newSourceName = ""; newSourceURL = ""
        persist()
    }

    func remove(_ source: SourceItem) {
        sources.removeAll { $0.id == source.id }
        persist()
    }

    func refresh(_ source: SourceItem) async {
        guard let url = URL(string: source.urlString) else {
            errorMessage = NSLocalizedString("sources.error.url", comment: ""); return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            _ = try JSONDecoder().decode(SourceFeed.self, from: data)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastRefreshed = Date()
                persist()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchApps(for source: SourceItem) async -> [SourceListingApp] {
        guard let url = URL(string: source.urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let feed = try JSONDecoder().decode(SourceFeed.self, from: data)
            return (feed.apps ?? []).compactMap { app in
                guard let name = app.name, let downloadURL = app.downloadURL else { return nil }
                return SourceListingApp(name: name, bundleID: app.bundleID ?? "", version: app.version ?? "", downloadURLString: downloadURL)
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }
}

struct SourcesView: View {
    @StateObject private var viewModel = SourcesViewModel()
    @State private var selectedSource: SourceItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section(NSLocalizedString("sources.add.title", comment: "")) {
                        TextField(NSLocalizedString("sources.add.name", comment: ""), text: $viewModel.newSourceName)
                            .accessibilityIdentifier("sources.nameField")
                        TextField("https://example.com/apps.json", text: $viewModel.newSourceURL)
                            .autocapitalization(.none)
                            .accessibilityIdentifier("sources.urlField")
                        Button(NSLocalizedString("sources.add", comment: "")) { viewModel.addSource() }
                            .accessibilityIdentifier("sources.add")
                    }
                }
                .frame(maxHeight: 220)
                if viewModel.sources.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("sources.empty", comment: ""),
                        systemImage: "globe",
                        description: Text(NSLocalizedString("sources.empty.detail", comment: ""))
                    )
                } else {
                    List(viewModel.sources) { source in
                        Button { selectedSource = source } label: {
                            VStack(alignment: .leading) {
                                Text(source.name)
                                Text(source.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let refreshed = source.lastRefreshed {
                                    Text(refreshed, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("sources.row.\(source.name)")
                        .swipeActions {
                            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { viewModel.remove(source) }
                            Button(NSLocalizedString("common.refresh", comment: "")) { Task { await viewModel.refresh(source) } }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tab.sources", comment: ""))
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
            .navigationDestination(item: $selectedSource) { source in SourceDetailView(source: source) }
        }
    }
}
