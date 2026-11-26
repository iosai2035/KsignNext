import SwiftUI

enum AppLogLevel: String, CaseIterable, Identifiable {
    case debug, info, warning, error, critical
    var id: String { rawValue }

    /// Localized level name (keys: `logs.level.<rawValue>`).
    var title: String {
        NSLocalizedString("logs.level.\(rawValue)", comment: "")
    }

    init(from level: LogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        case .critical: self = .critical
        }
    }
}

struct AppLogEntry: Identifiable, Equatable {
    let id: UUID
    var level: AppLogLevel
    var message: String
    var date: Date

    init(id: UUID = UUID(), level: AppLogLevel, message: String, date: Date) {
        self.id = id
        self.level = level
        self.message = message
        self.date = date
    }

    init(from entry: LogEntry) {
        self.init(id: entry.id, level: AppLogLevel(from: entry.level), message: entry.message, date: entry.timestamp)
    }
}

@MainActor
final class LogsViewModel: ObservableObject {
    @Published var entries: [AppLogEntry] = []
    @Published var selectedLevel: AppLogLevel?
    @Published var searchText = ""
    @Published var isLoading = false
    /// True once the first load has finished; the empty state is only
    /// shown after this, so it never flashes while data is loading.
    @Published var hasLoaded = false
    @Published var errorMessage: String?
    /// Shareable export of the loaded entries, written to a temp file
    /// on each refresh (the persisted log file itself is not shared).
    @Published var exportURL: URL?

    var filteredEntries: [AppLogEntry] {
        var list = entries
        if let level = selectedLevel { list = list.filter { $0.level == level } }
        if !searchText.isEmpty { list = list.filter { $0.message.localizedCaseInsensitiveContains(searchText) } }
        return list
    }

    /// Reads the real persisted entries from `LogsManager`
    /// (Application Support/KsignNext/logs.jsonl), newest first.
    /// The in-memory buffer is empty on a fresh launch until
    /// `loadPersistedEntries()` runs, so this always loads first.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        await LogsManager.shared.loadPersistedEntries()
        let loaded = await LogsManager.shared.allEntries()
        entries = loaded.reversed().map(AppLogEntry.init(from:))
        exportURL = makeExportURL()
    }

    /// Clears the persisted log through `LogsManager` (in-memory
    /// entries and the logs.jsonl file).
    func clear() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        await LogsManager.shared.clear()
        entries = []
        exportURL = nil
    }

    private func makeExportURL() -> URL? {
        let text = entries.reversed().map { entry in
            "\(ISO8601DateFormatter().string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KsignNext-logs.txt")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }
}

struct LogsView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var showClearConfirm = false

    // No NavigationStack here: this screen is pushed from Settings
    // ("More"), which provides the navigation stack.
    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Picker(NSLocalizedString("logs.filter", comment: ""), selection: $viewModel.selectedLevel) {
                Text(NSLocalizedString("logs.filter.all", comment: "")).tag(AppLogLevel?.none)
                ForEach(AppLogLevel.allCases) { Text($0.title).tag(AppLogLevel?.some($0)) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.Spacing.xl)
            if !viewModel.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("logs.loading")
            } else if viewModel.filteredEntries.isEmpty {
                EmptyStateView(
                    NSLocalizedString("logs.empty", comment: ""),
                    systemImage: "list.bullet.rectangle",
                    description: Text(NSLocalizedString("logs.empty.detail", comment: ""))
                ) {
                    Button(NSLocalizedString("common.refresh", comment: "")) {
                        Task { await viewModel.refresh() }
                    }
                    .dsSecondaryButton()
                    .accessibilityIdentifier("logs.refresh.empty")
                }
            } else {
                List(viewModel.filteredEntries) { entry in
                    HStack(alignment: .top, spacing: DS.Spacing.md) {
                        Text(entry.level.title)
                            .font(.caption.bold())
                            .foregroundStyle(levelColor(entry.level))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(entry.message).font(.caption.monospaced())
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.refresh() }
            }
        }
        .navigationTitle(NSLocalizedString("tab.logs", comment: ""))
        .dsInlineTitle()
        .searchable(text: $viewModel.searchText, prompt: NSLocalizedString("logs.search", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if let url = viewModel.exportURL {
                    ShareLink(item: url, preview: SharePreview("KsignNext-logs.txt")) {
                        Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("logs.export")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("logs.clear", comment: ""), role: .destructive) { showClearConfirm = true }
                    .accessibilityIdentifier("logs.clear")
            }
        }
        .task { await viewModel.refresh() }
        .alert(NSLocalizedString("logs.clear.confirm", comment: ""), isPresented: $showClearConfirm) {
            Button(NSLocalizedString("logs.clear", comment: ""), role: .destructive) {
                Task { await viewModel.clear() }
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private func levelColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
}
