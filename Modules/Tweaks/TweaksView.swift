import SwiftUI
import UniformTypeIdentifiers

struct StoredTweak: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var kind: String { url.pathExtension.lowercased() }
}

struct TweakAnalysis: Equatable {
    var architectures: [String] = []
    var dependencies: [String] = []
    var conflicts: [String] = []
    var summary = ""
}

@MainActor
final class TweaksViewModel: ObservableObject {
    @Published var tweaks: [StoredTweak] = []
    @Published var analysis: [UUID: TweakAnalysis] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showImporter = false

    func refresh() {
        guard let dir = Workspace.folder("Tweaks") else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        tweaks = items.filter { ["dylib", "deb", "framework", "bundle"].contains($0.pathExtension.lowercased()) }
            .map { StoredTweak(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func importTweak(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = NSLocalizedString("error.file.access", comment: ""); return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let destDir = Workspace.folder("Tweaks") else { return }
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Reads Mach-O magic bytes (first 4 bytes) to report the architecture; DEB/framework
    /// entries report honestly as not yet analysed instead of inventing data.
    func analyse(_ tweak: StoredTweak) {
        guard tweak.kind == "dylib" else {
            analysis[tweak.id] = TweakAnalysis(summary: NSLocalizedString("tweaks.analysis.unsupported", comment: ""))
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: tweak.url),
              let magic = try? handle.read(upToCount: 4) else {
            analysis[tweak.id] = TweakAnalysis(summary: NSLocalizedString("error.file.read", comment: ""))
            return
        }
        try? handle.close()
        let bytes = [UInt8](magic)
        var arch = NSLocalizedString("tweaks.arch.unknown", comment: "")
        if bytes == [0xCF, 0xFA, 0xED, 0xFE] { arch = "arm64" }
        else if bytes == [0xCE, 0xFA, 0xED, 0xFE] { arch = "armv7" }
        else if bytes == [0xCA, 0xFE, 0xBA, 0xBE] { arch = "fat (universal)" }
        analysis[tweak.id] = TweakAnalysis(architectures: [arch], summary: String(format: NSLocalizedString("tweaks.analysis.arch", comment: ""), arch))
    }

    func delete(_ tweak: StoredTweak) {
        do { try FileManager.default.removeItem(at: tweak.url); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    var injectionPlan: String {
        guard !tweaks.isEmpty else { return NSLocalizedString("tweaks.plan.empty", comment: "") }
        return tweaks.map { "• \($0.name)" }.joined(separator: "\n")
    }
}

struct TweaksView: View {
    @StateObject private var viewModel = TweaksViewModel()
    @State private var tweakToDelete: StoredTweak?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(NSLocalizedString("tweaks.stock.warning", comment: ""), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                .accessibilityIdentifier("tweaks.stockWarning")

                if viewModel.tweaks.isEmpty {
                    emptyState
                } else {
                    tweaksList
                }
            }
            .navigationTitle(NSLocalizedString("tab.tweaks", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("tweaks.import", comment: "")) { viewModel.showImporter = true }
                        .accessibilityIdentifier("tweaks.import")
                }
            }
            .fileImporter(isPresented: $viewModel.showImporter, allowedContentTypes: [.init(filenameExtension: "dylib") ?? .data, .init(filenameExtension: "deb") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): urls.first.map { viewModel.importTweak($0) }
                case .failure(let error): viewModel.errorMessage = error.localizedDescription
                }
            }
            .onAppear { viewModel.refresh() }
            .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: Binding(get: { tweakToDelete != nil }, set: { if !$0 { tweakToDelete = nil } })) {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                    if let t = tweakToDelete { viewModel.delete(t) }
                    tweakToDelete = nil
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { tweakToDelete = nil }
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }

    // Branches extracted so the type checker does not have to infer the
    // whole body as one expression (it timed out on the combined form).
    private var emptyState: some View {
        EmptyStateView(
            NSLocalizedString("tweaks.empty", comment: ""),
            systemImage: "wrench.and.screwdriver",
            description: Text(NSLocalizedString("tweaks.empty.detail", comment: ""))
        ) {
            Button(NSLocalizedString("tweaks.import", comment: "")) { viewModel.showImporter = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tweaks.import.empty")
        }
    }

    private var tweaksList: some View {
        Group {
            ForEach(viewModel.tweaks) { tweak in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tweak.name).lineLimit(1)
                        Spacer()
                        Text(tweak.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    if let result = viewModel.analysis[tweak.id] {
                        Text(result.summary).font(.caption).foregroundStyle(.secondary)
                        if !result.dependencies.isEmpty { Text(result.dependencies.joined(separator: ", ")).font(.caption) }
                        if !result.conflicts.isEmpty { Text(result.conflicts.joined(separator: ", ")).font(.caption).foregroundStyle(.red) }
                    }
                    HStack {
                        Button(NSLocalizedString("tweaks.analyse", comment: "")) { viewModel.analyse(tweak) }
                            .accessibilityIdentifier("tweaks.analyse.\(tweak.name)")
                        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { tweakToDelete = tweak }
                    }
                    .font(.caption)
                }
            }
            Section(NSLocalizedString("tweaks.plan.title", comment: "")) {
                Text(viewModel.injectionPlan).font(.caption.monospaced())
            }
        }
    }
}
