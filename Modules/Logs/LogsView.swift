import SwiftUI

enum AppLogLevel: String, CaseIterable, Identifiable {
    case debug, info, warning, error
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AppLogEntry: Identifiable, Equatable {
    let id = UUID()
    var level: AppLogLevel
    var message: String
    var date: Date
}

@MainActor
final class LogsViewModel: ObservableObject {
    @Published var entries: [AppLogEntry] = []
    @Published var selectedLevel: AppLogLevel?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    var logURL: URL? {
        Workspace.folder("Logs")?.appendingPathComponent("app.log")
    }

    var filteredEntries: [AppLogEntry] {
        var list = entries
        if let level = selectedLevel { list = list.filter { $0.level == level } }
        if !searchText.isEmpty { list = list.filter { $0.message.localizedCaseInsensitiveContains(searchText) } }
        return list
    }

    func refresh() {
        isLoading = true
        defer { isLoading = false }
        guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            entries = []
            return
        }
        entries = text.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            let level = parts.count > 1 ? (AppLogLevel(rawValue: parts[1].lowercased()) ?? .info) : .info
            return AppLogEntry(level: level, message: String(line), date: Date())
        }
    }

    func append(level: AppLogLevel, message: String) {
        guard let url = logURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level.rawValue.uppercased()) \(message)\n"
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        refresh()
    }

    func exportURL() -> URL? { logURL }

    func clear() {
        guard let url = logURL else { return }
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            entries = []
        } catch { errorMessage = error.localizedDescription }
    }
}

struct LogsView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(NSLocalizedString("logs.filter", comment: ""), selection: $viewModel.selectedLevel) {
                    Text(NSLocalizedString("logs.filter.all", comment: "")).tag(AppLogLevel?.none)
                    ForEach(AppLogLevel.allCases) { Text($0.title).tag(AppLogLevel?.some($0)) }
                }
                .pickerStyle(.segmented)
                .padding()
                if viewModel.filteredEntries.isEmpty {
                    EmptyStateView(
                        NSLocalizedString("logs.empty", comment: ""),
                        systemImage: "list.bullet.rectangle",
                        description: Text(NSLocalizedString("logs.empty.detail", comment: ""))
                    )
                } else {
                    List(viewModel.filteredEntries) { entry in
                        HStack(alignment: .top) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(levelColor(entry.level))
                                .frame(width: 64, alignment: .leading)
                            Text(entry.message).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tab.logs", comment: ""))
            .searchable(text: $viewModel.searchText, prompt: NSLocalizedString("logs.search", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let url = viewModel.exportURL() {
                        ShareLink(item: url, preview: SharePreview("app.log")) {
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
            .onAppear { viewModel.refresh() }
            .alert(NSLocalizedString("logs.clear.confirm", comment: ""), isPresented: $showClearConfirm) {
                Button(NSLocalizedString("logs.clear", comment: ""), role: .destructive) { viewModel.clear() }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    private func levelColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
