import SwiftUI

/// Diagnostics view (contract §C.5): live `AppLogger` stream with
/// search, export (text/JSON file via the share sheet) and clear.
/// A clear failure is surfaced in the error alert (W-19) — never
/// swallowed.
struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showClearConfirm = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.md) {
                TextField(Loc.string("logs.search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Loc.string("logs.search"))
                Button(Loc.string("common.refresh")) {
                    Task { await load() }
                }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("common.refresh"))
            }
            .padding()
            if entries.isEmpty {
                VStack {
                    Spacer()
                    Text(Loc.string("logs.empty"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Loc.string("logs.empty"))
                    Text(Loc.string("logs.empty.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        HStack(spacing: DS.Spacing.md) {
                            Text(levelText(entry.level))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(levelColor(entry.level))
                                .frame(minWidth: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(entry.message)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(levelText(entry.level)): \(entry.message)")
                    }
                }
                .listStyle(.plain)
            }
            HStack(spacing: DS.Spacing.md) {
                Button(Loc.string("settings.diagnostics.export.text")) {
                    Task { await exportText() }
                }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("settings.diagnostics.export.text"))
                Button(Loc.string("settings.diagnostics.export.json")) {
                    Task { await exportJSON() }
                }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("settings.diagnostics.export.json"))
                Spacer()
                Button(Loc.string("logs.clear"), role: .destructive) {
                    showClearConfirm = true
                }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("logs.clear"))
            }
            .padding()
        }
        .navigationTitle(Loc.string("settings.diagnostics.title"))
        .dsInlineTitle()
        .task { await load() }
        .task(id: searchText) { await load() }
        .task {
            // Live stream: refresh every 2 seconds while visible.
            // The AppLogger contract exposes no push stream, so this
            // short poll is the live view (Gemini's AsyncStream
            // suggestion was rejected — no such API exists in §B.2).
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                await load()
            }
        }
        .alert(Loc.string("logs.clear.confirm"), isPresented: $showClearConfirm) {
            Button(Loc.string("logs.clear"), role: .destructive) {
                Task { await clearLogs() }
            }
            Button(Loc.string("common.cancel"), role: .cancel) {}
        }
        .alert(Loc.string("alert.error.title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(Loc.string("common.ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func load() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            entries = Array(await AppLogger.shared.allEntries().reversed())
        } else {
            entries = Array(await AppLogger.shared.search(trimmed).reversed())
        }
    }

    private func clearLogs() async {
        do {
            try await AppLogger.shared.clear()
            await load()
        } catch {
            // W-19: a clear failure is thrown and surfaced, never
            // swallowed — the user must know the logs are still there.
            errorMessage = error.localizedDescription
        }
    }

    private func exportText() async {
        let text = await AppLogger.shared.exportText()
        await share(data: Data(text.utf8), fileName: "KsignNext-logs.txt")
    }

    private func exportJSON() async {
        do {
            let data = try await AppLogger.shared.exportJSON()
            await share(data: data, fileName: "KsignNext-logs.json")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the export into a managed temp file (the old text/JSON
    /// file export via share sheet — never a .zip, §C.5) and shares
    /// it. The Temp folder is purged by the stale-temp cleanup.
    private func share(data: Data, fileName: String) async {
        do {
            let files = FileSystemManager.shared
            let tempDir = try files.createTempDirectory(named: "diagnostics-export")
            let url = tempDir.appendingPathComponent(fileName)
            try files.writeAtomically(data, to: url)
            shareURL = url
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func levelText(_ level: LogLevel) -> String {
        switch level {
        case .debug: return Loc.string("logs.level.debug")
        case .info: return Loc.string("logs.level.info")
        case .warning: return Loc.string("logs.level.warning")
        case .error: return Loc.string("logs.level.error")
        case .critical: return Loc.string("logs.level.critical")
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
}
