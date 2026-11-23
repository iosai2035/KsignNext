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

/// Reads real on-disk state (Documents workspace); returns zero/empty when nothing exists.
final class LocalDashboardDataProvider: DashboardDataProviding {
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
            operations: (try? fm.contentsOfDirectory(at: docs.appendingPathComponent("Logs", isDirectory: true), includingPropertiesForKeys: nil).count) ?? 0
        )
    }
    func loadRecentActivity() -> [ActivityItem] {
        let fm = FileManager.default
        guard let docs = Workspace.documents else { return [] }
        let logURL = docs.appendingPathComponent("Logs/app.log")
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(10).reversed().map {
            ActivityItem(title: String($0.prefix(120)), detail: "", date: Date())
        }
    }
    func expiringCertificates() -> [String] { [] } // Filled by Certificates module once a cert is imported.
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var counts = DashboardCounts()
    @Published var recentActivity: [ActivityItem] = []
    @Published var expiringCertificates: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let provider: DashboardDataProviding

    init(provider: DashboardDataProviding = LocalDashboardDataProvider()) {
        self.provider = provider
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        counts = provider.loadCounts()
        recentActivity = provider.loadRecentActivity()
        expiringCertificates = provider.expiringCertificates()
        isLoading = false
    }
}

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !viewModel.expiringCertificates.isEmpty {
                        expiryBanner
                    }
                    countsGrid
                    shortcutsSection
                    recentSection
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("dashboard.title", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { viewModel.refresh() } label: {
                        Label(NSLocalizedString("common.refresh", comment: ""), systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("dashboard.refresh")
                }
            }
            .onAppear { viewModel.refresh() }
            .refreshable { viewModel.refresh() }
            .overlay { if viewModel.isLoading { ProgressView().accessibilityIdentifier("dashboard.loading") } }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    private var expiryBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(NSLocalizedString("dashboard.expiry.warning", comment: ""), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(viewModel.expiringCertificates, id: \.self) { Text($0).font(.caption) }
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("dashboard.expiryBanner")
    }

    private var countsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            countCard(NSLocalizedString("dashboard.count.imported", comment: ""), value: viewModel.counts.importedApps, icon: "app.badge")
            countCard(NSLocalizedString("dashboard.count.signed", comment: ""), value: viewModel.counts.signedApps, icon: "checkmark.seal.fill")
            countCard(NSLocalizedString("dashboard.count.certs", comment: ""), value: viewModel.counts.certificates, icon: "key.fill")
            countCard(NSLocalizedString("dashboard.count.downloads", comment: ""), value: viewModel.counts.downloads, icon: "arrow.down.circle")
        }
        .accessibilityIdentifier("dashboard.counts")
    }

    private func countCard(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.shortcuts", comment: "")).font(.headline)
            shortcut(NSLocalizedString("tab.applications", comment: ""), icon: "app.badge", tab: .applications, id: "dashboard.shortcut.apps")
            shortcut(NSLocalizedString("tab.signing", comment: ""), icon: "signature", tab: .signing, id: "dashboard.shortcut.sign")
            shortcut(NSLocalizedString("tab.certificates", comment: ""), icon: "key.fill", tab: .certificates, id: "dashboard.shortcut.certs")
            shortcut(NSLocalizedString("tab.downloads", comment: ""), icon: "arrow.down.circle", tab: .downloads, id: "dashboard.shortcut.downloads")
            shortcut(NSLocalizedString("tab.files", comment: ""), icon: "folder", tab: .files, id: "dashboard.shortcut.files")
        }
    }

    private func shortcut(_ title: String, icon: String, tab: AppTab, id: String) -> some View {
        Button { coordinator.selectTab(tab) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.recent", comment: "")).font(.headline)
            if viewModel.recentActivity.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("dashboard.recent.empty", comment: ""),
                    systemImage: "clock",
                    description: Text(NSLocalizedString("dashboard.recent.empty.detail", comment: ""))
                )
                .accessibilityIdentifier("dashboard.recentEmpty")
            } else {
                ForEach(viewModel.recentActivity) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).font(.subheadline)
                        Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}
