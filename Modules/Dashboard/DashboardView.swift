import SwiftUI

struct DashboardCounts: Equatable {
    var importedApps = 0, signedApps = 0, certificates = 0, downloads = 0, operations = 0
}

struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let date: Date
}

protocol DashboardDataProviding {
    func loadCounts() -> DashboardCounts
    func loadRecentActivity() -> [ActivityItem]
    func expiringCertificates() -> [String]
}

/// One expiring-certificate line: "<name> expires <date>".
/// Shared by the file scan below and the repository lookup in
/// `DashboardViewModel`, so both sources format identically.
func expiryItemText(name: String, date: Date) -> String {
    String(
        format: NSLocalizedString("dashboard.expiry.item", comment: ""),
        name,
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    )
}

/// Reads real on-disk state (Documents workspace); returns zero/empty when nothing exists.
final class LocalDashboardDataProvider: DashboardDataProviding {
    /// The persisted log file `LogsManager` writes
    /// (Application Support/KsignNext/logs.jsonl), read directly so
    /// this provider can stay synchronous.
    static var persistedLogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KsignNext/logs.jsonl")
    }

    /// Parses the persisted JSON-lines log file, oldest first.
    static func persistedLogEntries() -> [LogEntry] {
        guard let url = persistedLogURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LogEntry.self, from: data)
        }
    }

    func loadCounts() -> DashboardCounts {
        let fm = FileManager.default
        guard let docs = Workspace.documents else { return DashboardCounts() }
        func count(_ folder: String, ext: String? = nil) -> Int {
            let dir = docs.appendingPathComponent(folder, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if let ext { return items.filter { $0.pathExtension.lowercased() == ext }.count }
            return items.count
        }
        return DashboardCounts(
            importedApps: count("ImportedApps", ext: "ipa"),
            signedApps: count("SignedApps", ext: "ipa"),
            certificates: count("Certificates"),
            downloads: count("Downloads", ext: "ipa"),
            operations: Self.persistedLogEntries().count
        )
    }

    /// The 10 newest persisted log entries, with their real
    /// timestamps (never `Date()`).
    func loadRecentActivity() -> [ActivityItem] {
        Self.persistedLogEntries().suffix(10).reversed().map { entry in
            ActivityItem(
                title: String(entry.message.prefix(120)),
                detail: AppLogLevel(from: entry.level).title,
                date: entry.timestamp
            )
        }
    }

    /// Provisioning profiles in the Certificates folder whose parsed
    /// `ExpirationDate` falls within the next 7 days (already-expired
    /// ones included — they need action too). Only plain-plist
    /// profiles can be read here; CMS-wrapped profiles report no
    /// date, and .p12 expiry comes from the certificate repository
    /// (see `DashboardViewModel.refresh()`).
    func expiringCertificates() -> [String] {
        guard let dir = Workspace.folder("Certificates") else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let limit = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        var found: [(name: String, date: Date)] = []
        for url in items where url.pathExtension.lowercased() == "mobileprovision" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let expiry = plist["ExpirationDate"] as? Date,
                  expiry <= limit else { continue }
            found.append((url.deletingPathExtension().lastPathComponent, expiry))
        }
        return found.sorted { $0.date < $1.date }.map { expiryItemText(name: $0.name, date: $0.date) }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var counts = DashboardCounts()
    @Published var recentActivity: [ActivityItem] = []
    @Published var expiringCertificates: [String] = []
    @Published var isLoading = false
    /// True once the first load has finished; the empty state is only
    /// shown after this, so it never flashes while data is loading.
    @Published var hasLoaded = false
    @Published var errorMessage: String?
    private let provider: DashboardDataProviding
    /// Set by the view from the app container; when set, the
    /// repository's parsed P12 expiry dates are merged with the
    /// provisioning-profile scan above.
    var certificateRepository: CertificateRepository?

    init(provider: DashboardDataProviding = LocalDashboardDataProvider(), certificateRepository: CertificateRepository? = nil) {
        self.provider = provider
        self.certificateRepository = certificateRepository
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        errorMessage = nil
        counts = provider.loadCounts()
        recentActivity = provider.loadRecentActivity()
        var expiring = provider.expiringCertificates()
        if let repository = certificateRepository,
           let models = try? await repository.fetchAll() {
            let limit = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            for model in models {
                guard let expiry = model.expirationDate, expiry <= limit else { continue }
                let item = expiryItemText(name: model.name, date: expiry)
                if !expiring.contains(item) { expiring.append(item) }
            }
        }
        expiringCertificates = expiring.sorted()
    }
}

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.sectionSpacing) {
                    if !viewModel.expiringCertificates.isEmpty {
                        expiryBanner
                    }
                    countsGrid
                    shortcutsSection
                    recentSection
                }
                .padding(DS.Spacing.xl)
            }
            .refreshable { await viewModel.refresh() }
            .navigationTitle(NSLocalizedString("dashboard.title", comment: ""))
            .dsLargeTitle()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await viewModel.refresh() } } label: {
                        Label(NSLocalizedString("common.refresh", comment: ""), systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("dashboard.refresh")
                }
            }
            .task {
                viewModel.certificateRepository = coordinator.container.certificateRepository
                await viewModel.refresh()
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    private var expiryBanner: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(NSLocalizedString("dashboard.expiry.warning", comment: ""), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(viewModel.expiringCertificates, id: \.self) { Text($0).font(.caption) }
        }
        .padding(DS.cardPadding)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        .accessibilityIdentifier("dashboard.expiryBanner")
    }

    private var countsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.lg) {
            countCard(NSLocalizedString("dashboard.count.imported", comment: ""), value: viewModel.counts.importedApps, icon: "app.badge")
            countCard(NSLocalizedString("dashboard.count.signed", comment: ""), value: viewModel.counts.signedApps, icon: "checkmark.seal.fill")
            countCard(NSLocalizedString("dashboard.count.certs", comment: ""), value: viewModel.counts.certificates, icon: "key.fill")
            countCard(NSLocalizedString("dashboard.count.downloads", comment: ""), value: viewModel.counts.downloads, icon: "arrow.down.circle")
        }
        .accessibilityIdentifier("dashboard.counts")
    }

    private func countCard(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DS.rowSpacing) {
            Text(NSLocalizedString("dashboard.shortcuts", comment: "")).dsSectionHeader()
            shortcut(NSLocalizedString("tab.applications", comment: ""), icon: "app.badge", tab: .applications, id: "dashboard.shortcut.apps")
            shortcut(NSLocalizedString("tab.signing", comment: ""), icon: "signature", tab: .signing, id: "dashboard.shortcut.sign")
            shortcut(NSLocalizedString("tab.certificates", comment: ""), icon: "key.fill", tab: .certificates, id: "dashboard.shortcut.certs")
        }
    }

    private func shortcut(_ title: String, icon: String, tab: AppTab, id: String) -> some View {
        Button { coordinator.selectTab(tab) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .dsSecondaryButton()
        .accessibilityIdentifier(id)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DS.rowSpacing) {
            Text(NSLocalizedString("dashboard.recent", comment: "")).dsSectionHeader()
            if !viewModel.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(DS.Spacing.xl)
                    .accessibilityIdentifier("dashboard.recentLoading")
            } else if viewModel.recentActivity.isEmpty {
                EmptyStateView(
                    NSLocalizedString("dashboard.recent.empty", comment: ""),
                    systemImage: "clock",
                    description: Text(NSLocalizedString("dashboard.recent.empty.detail", comment: ""))
                ) {
                    Button(NSLocalizedString("tab.applications", comment: "")) {
                        coordinator.selectTab(.applications)
                    }
                    .dsPrimaryButton()
                    .accessibilityIdentifier("dashboard.recent.empty.import")
                }
                .accessibilityIdentifier("dashboard.recentEmpty")
            } else {
                VStack(alignment: .leading, spacing: DS.rowSpacing) {
                    ForEach(viewModel.recentActivity) { item in
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(item.title).font(.subheadline)
                            HStack(spacing: DS.Spacing.xs) {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if item.id != viewModel.recentActivity.last?.id { Divider() }
                    }
                }
                .dsCard()
            }
        }
    }
}
