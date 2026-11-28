import SwiftUI

struct SourceListingApp: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var bundleID: String
    var version: String
    /// Nil when the app lists no decodable version (SRC-1): the app
    /// is still listed, with a placeholder version and no Download.
    var downloadURLString: String?
    /// The source's own icon (SRC-3): shown as the row image.
    var iconURL: URL?
    var localizedDescription: String?
    var size: Int64?
    var date: Date?
}

struct SourceItem: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var urlString: String
    var lastRefreshed: Date?
    /// The id of the matching record in `SourcesEngine` (in-memory
    /// per launch); nil for sources stored before this change, which
    /// are registered with the engine lazily on first use.
    var engineID: UUID?
    /// Health as last reported by the engine; shown in the row.
    var status: SourceStatus
    /// App count as last reported by the engine.
    var appCount: Int

    init(id: UUID = UUID(), name: String, urlString: String, lastRefreshed: Date? = nil,
         engineID: UUID? = nil, status: SourceStatus = .active, appCount: Int = 0) {
        self.id = id; self.name = name; self.urlString = urlString; self.lastRefreshed = lastRefreshed
        self.engineID = engineID; self.status = status; self.appCount = appCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, urlString, lastRefreshed, engineID, status, appCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        urlString = try container.decode(String.self, forKey: .urlString)
        lastRefreshed = try container.decodeIfPresent(Date.self, forKey: .lastRefreshed)
        // New fields: items stored before this change predate them,
        // so they decode with defaults instead of dropping the
        // whole stored list.
        engineID = try container.decodeIfPresent(UUID.self, forKey: .engineID)
        status = try container.decodeIfPresent(SourceStatus.self, forKey: .status) ?? .active
        appCount = try container.decodeIfPresent(Int.self, forKey: .appCount) ?? 0
    }
}

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var sources: [SourceItem] = []
    @Published var newSourceName = ""
    @Published var newSourceURL = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let storageKey = "ksign.sources"

    /// The engine that owns sources end to end: registration,
    /// fetching and parsing, the 1-hour cache, health status and
    /// app lists. The view model owns only the persisted user list
    /// (UserDefaults) and the user's own display name; every fetch,
    /// refresh and app list goes through the engine, so the two can
    /// never drift apart (the old code kept its own list, called
    /// `fetchSource` uncached, and cleared the engine cache before
    /// every refresh — which dropped every registered source).
    private let engine: SourcesEngine
    private let downloadEngine: DownloadEngine

    /// - Parameter container: the app's container; nil builds fresh
    ///   engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        let container = container ?? DependencyContainer()
        self.engine = container.sourcesEngine
        self.downloadEngine = container.downloadEngine
        loadStored()
    }

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

    /// Validates the name and URL, then registers the source with
    /// the engine (which fetches and parses the document) and only
    /// then adds it to the stored list — so "added" always means
    /// the document parsed. A fetch failure leaves the list
    /// untouched and reports the real reason.
    func addSource() async {
        let name = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // The name and the URL are checked separately on purpose:
        // one combined guard blamed the URL when the name was the
        // empty field, so a valid URL was reported as invalid.
        guard !name.isEmpty else {
            errorMessage = NSLocalizedString("sources.error.name", comment: ""); return
        }
        guard let url = URL(string: urlString), url.scheme == "https",
              let host = url.host, !host.isEmpty else {
            errorMessage = NSLocalizedString("sources.error.url", comment: ""); return
        }
        guard !sources.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                || $0.urlString.localizedCaseInsensitiveCompare(urlString) == .orderedSame
        }) else {
            errorMessage = NSLocalizedString("sources.error.duplicate", comment: ""); return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let engineSource = try await engine.addSource(url: url)
            sources.append(SourceItem(
                name: name, urlString: urlString, lastRefreshed: Date(),
                engineID: engineSource.id, status: engineSource.status,
                appCount: engineSource.appCount))
            newSourceName = ""; newSourceURL = ""
            errorMessage = nil
            persist()
        } catch let error as SourceError {
            // The engine also rejects duplicates (same document
            // identifier under another URL); keep the local wording.
            if case .duplicateSource = error {
                errorMessage = NSLocalizedString("sources.error.duplicate", comment: "")
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the source from the stored list and from the engine.
    /// Async so the engine removal has completed when the call
    /// returns — otherwise a re-add of the same URL could hit the
    /// engine's duplicate check on the stale record.
    func remove(_ source: SourceItem) async {
        sources.removeAll { $0.id == source.id }
        persist()
        if let engineID = source.engineID {
            await engine.removeSource(id: engineID)
        }
    }

    func refresh(_ source: SourceItem) async {
        isLoading = true
        defer { isLoading = false }
        await performRefresh(source)
    }

    /// Refreshes every source, with a single loading state for the
    /// whole pass (used by pull-to-refresh). The per-source refresh
    /// above keeps its own flag so a swipe refresh still shows
    /// feedback.
    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        for source in sources {
            await performRefresh(source)
        }
    }

    /// Returns the engine id for a stored source, registering it
    /// with the engine first when it is not there yet (a source
    /// stored before this change, or a fresh engine after relaunch,
    /// carries no id). Registration is lazy — launch does no
    /// network — and reuses an existing engine record for the same
    /// URL instead of registering twice.
    private func ensureRegistered(_ source: SourceItem) async throws -> UUID {
        if let engineID = source.engineID, await engine.source(id: engineID) != nil {
            return engineID
        }
        guard let url = URL(string: source.urlString) else {
            throw SourceError.invalidURL(source.urlString)
        }
        if let existing = await engine.allSources().first(where: { $0.url == url }) {
            applyEngineSource(existing, to: source)
            return existing.id
        }
        let registered = try await engine.addSource(url: url)
        applyEngineSource(registered, to: source)
        return registered.id
    }

    /// Mirrors an engine record's id, health and app count onto the
    /// stored item (the user's own name is never overwritten by the
    /// document's name).
    private func applyEngineSource(_ engineSource: Source, to item: SourceItem) {
        guard let index = sources.firstIndex(where: { $0.id == item.id }) else { return }
        sources[index].engineID = engineSource.id
        sources[index].status = engineSource.status
        sources[index].appCount = engineSource.appCount
        persist()
    }

    /// The actual refresh, without touching `isLoading` (callers own
    /// the flag). Re-fetches through the engine, which keeps the
    /// cache and the health status; an explicit refresh uses the
    /// engine's per-source refresh, never `clearCache()` (that drops
    /// every registered source).
    private func performRefresh(_ source: SourceItem) async {
        do {
            let engineID = try await ensureRegistered(source)
            let updated = try await engine.refreshSource(id: engineID)
            applyEngineSource(updated, to: source)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastRefreshed = Date()
                persist()
            }
            errorMessage = nil
        } catch {
            // The engine already marked the record `.invalid` (a
            // parse failure) or `.unreachable` (network) and kept the
            // stale apps listable; mirror that status so the row
            // shows it instead of silently staying "active".
            if let engineID = source.engineID,
               let current = await engine.source(id: engineID) {
                applyEngineSource(current, to: source)
            }
            errorMessage = error.localizedDescription
        }
    }

    func fetchApps(for source: SourceItem) async -> [SourceListingApp] {
        do {
            let engineID = try await ensureRegistered(source)
            let apps = try await engine.apps(for: engineID)
            errorMessage = nil
            return apps.map { app in
                // SRC-1: never drop a version-less app — list it with
                // a placeholder version and no download URL, so the
                // list and the row count can never disagree.
                let latest = SourcesEngine.latestVersion(for: app)
                return SourceListingApp(
                    name: app.name,
                    bundleID: app.bundleIdentifier,
                    version: latest?.version ?? NSLocalizedString("sources.app.version.unknown", comment: ""),
                    downloadURLString: latest?.downloadURL.absoluteString,
                    iconURL: app.iconURL,
                    localizedDescription: app.localizedDescription ?? app.subtitle,
                    size: latest?.size,
                    date: latest?.date
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Queues an app download through the real download engine
    /// (queue, concurrency limit, progress), so source downloads
    /// show up in the Downloads tab instead of running as a hidden
    /// one-off `URLSession` task.
    func enqueueDownload(url: URL, fileName: String?) async throws -> DownloadTask {
        try await downloadEngine.enqueue(url: url, fileName: fileName)
    }
}

struct SourcesView: View {
    @StateObject private var viewModel: SourcesViewModel
    @State private var selectedSource: SourceItem?

    /// - Parameter container: the app's container; nil builds fresh
    ///   engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: SourcesViewModel(container: container))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(NSLocalizedString("sources.add.title", comment: "")) {
                    TextField(NSLocalizedString("sources.add.name", comment: ""), text: $viewModel.newSourceName)
                        .accessibilityIdentifier("sources.nameField")
                    TextField(NSLocalizedString("sources.add.url.placeholder", comment: ""), text: $viewModel.newSourceURL)
                        .autocapitalization(.none)
                        .accessibilityIdentifier("sources.urlField")
                    Button(NSLocalizedString("sources.add", comment: "")) { Task { await viewModel.addSource() } }
                        .dsPrimaryButton()
                        .accessibilityIdentifier("sources.add")
                }
            }
            .frame(maxHeight: 220)
            if viewModel.isLoading {
                ProgressView(NSLocalizedString("common.loading", comment: ""))
                    .padding(DS.Spacing.md)
                    .accessibilityIdentifier("sources.loading")
            }
            if viewModel.sources.isEmpty {
                EmptyStateView(
                    NSLocalizedString("sources.empty", comment: ""),
                    systemImage: "globe",
                    description: Text(NSLocalizedString("sources.empty.detail", comment: ""))
                )
            } else {
                List(viewModel.sources) { source in
                    Button { selectedSource = source } label: {
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(source.name)
                            Text(source.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: DS.Spacing.xs) {
                                Text(statusText(for: source.status))
                                    .font(.caption).foregroundStyle(statusColor(for: source.status))
                                Text("·").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: NSLocalizedString("sources.apps.count", comment: ""), source.appCount))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let refreshed = source.lastRefreshed {
                                    Text("·").font(.caption).foregroundStyle(.secondary)
                                    Text(refreshed, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("sources.row.\(source.name)")
                    .swipeActions {
                        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { Task { await viewModel.remove(source) } }
                        Button(NSLocalizedString("common.refresh", comment: "")) { Task { await viewModel.refresh(source) } }
                    }
                }
                .refreshable { await viewModel.refreshAll() }
            }
        }
        .navigationTitle(NSLocalizedString("tab.sources", comment: ""))
        .dsInlineTitle()
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
        // `navigationDestination(item:)` needs iOS 17; the `isPresented`
        // variant works from iOS 16.
        .navigationDestination(isPresented: Binding(get: { selectedSource != nil }, set: { if !$0 { selectedSource = nil } })) {
            if let source = selectedSource { SourceDetailView(source: source, sourcesModel: viewModel) }
        }
    }

    /// Localised health label for a source row, from the engine's
    /// last reported status.
    private func statusText(for status: SourceStatus) -> String {
        switch status {
        case .active:
            return NSLocalizedString("sources.status.active", comment: "")
        case .unreachable:
            return NSLocalizedString("sources.status.unreachable", comment: "")
        case .invalid:
            return NSLocalizedString("sources.status.invalid", comment: "")
        case .updating:
            return NSLocalizedString("sources.status.updating", comment: "")
        }
    }

    private func statusColor(for status: SourceStatus) -> Color {
        switch status {
        case .active: return .green
        case .unreachable: return .orange
        case .invalid: return .red
        case .updating: return .secondary
        }
    }
}
