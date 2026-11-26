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
    @Published var errorMessage: String?
    @Published var showImporter = false

    /// Imported IPAs the plan can target, and the selected one.
    @Published var availableApps: [String] = []
    @Published var selectedAppName = ""
    /// The last computed plan, if any. Nil until `computePlan` runs.
    @Published var plan: InjectionPlan?
    @Published var isPlanning = false

    private let container: DependencyContainer?

    /// - Parameter container: the app's container; nil builds fresh
    ///   engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        self.container = container
        refresh()
    }

    func refresh() {
        guard let dir = Workspace.folder("Tweaks") else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        tweaks = items.filter { ["dylib", "deb", "framework", "bundle"].contains($0.pathExtension.lowercased()) }
            .map { StoredTweak(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        availableApps = listImportedIPAs()
        if !selectedAppName.isEmpty, !availableApps.contains(selectedAppName) {
            selectedAppName = ""
            plan = nil
        }
    }

    private func listImportedIPAs() -> [String] {
        guard let docs = Workspace.documents else { return [] }
        let dir = docs.appendingPathComponent("ImportedApps", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "ipa" }.map(\.lastPathComponent).sorted()
    }

    func importTweak(_ url: URL) {
        guard ["dylib", "deb", "framework", "bundle"].contains(url.pathExtension.lowercased()) else {
            errorMessage = NSLocalizedString("tweaks.import.unsupported", comment: ""); return
        }
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

    /// Computes the real injection plan for the selected imported app
    /// with `InjectionEngine.plan`: destination paths, per-item status
    /// (ready / skipped with a reason), and warnings. Planning only
    /// reads the app and the tweaks — nothing is copied or modified.
    /// The heavy work (extraction + planning) runs off the main actor.
    func computePlan() async {
        guard !selectedAppName.isEmpty else {
            errorMessage = NSLocalizedString("tweaks.plan.selectApp", comment: ""); return
        }
        guard !tweaks.isEmpty else { return }
        guard let docs = Workspace.documents else { return }
        let ipaURL = docs.appendingPathComponent("ImportedApps/\(selectedAppName)")
        let models = tweaks.map { tweak in
            TweakModel(
                name: tweak.name,
                architecture: analysis[tweak.id]?.architectures.first ?? "arm64",
                injectionType: InjectionType(rawValue: tweak.kind) ?? .unknown,
                fileURL: tweak.url
            )
        }
        let engine = container?.injectionEngine ?? InjectionEngine(adapter: ZsignAdapter(backend: ZsignBridgeBackend()))
        isPlanning = true
        defer { isPlanning = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("KsignNext-tweak-plan-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try ArchiveEngine().extractAll(from: ipaURL, to: tmp)
                let payload = tmp.appendingPathComponent("Payload", isDirectory: true)
                let items = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                guard let appURL = items.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                    throw SigningError.invalidIPA(reason: "No .app bundle under Payload/.")
                }
                return try engine.plan(tweaks: models, appBundleURL: appURL)
            }.value
            plan = result
            errorMessage = nil
        } catch {
            plan = nil
            errorMessage = error.localizedDescription
        }
    }
}

struct TweaksView: View {
    @StateObject private var viewModel: TweaksViewModel
    @State private var tweakToDelete: StoredTweak?

    /// - Parameter container: the app's container; nil builds fresh
    ///   engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: TweaksViewModel(container: container))
    }

    var body: some View {
        List {
            Section {
                Label(NSLocalizedString("tweaks.stock.warning", comment: ""), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            .accessibilityIdentifier("tweaks.stockWarning")

            Section {
                Text(NSLocalizedString("tweaks.injection.note", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.tweaks.isEmpty {
                emptyState
            } else {
                tweaksList
            }
        }
        .navigationTitle(NSLocalizedString("tab.tweaks", comment: ""))
        .dsInlineTitle()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("tweaks.import", comment: "")) { viewModel.showImporter = true }
                    .accessibilityIdentifier("tweaks.import")
            }
        }
        // Frameworks and bundles are directory packages, so the
        // importer also accepts folders; importTweak rejects anything
        // that is not dylib / deb / framework / bundle.
        .fileImporter(isPresented: $viewModel.showImporter, allowedContentTypes: [.init(filenameExtension: "dylib") ?? .data, .init(filenameExtension: "deb") ?? .data, .folder], allowsMultipleSelection: false) { result in
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

    // Branches extracted so the type checker does not have to infer the
    // whole body as one expression (it timed out on the combined form).
    private var emptyState: some View {
        EmptyStateView(
            NSLocalizedString("tweaks.empty", comment: ""),
            systemImage: "wrench.and.screwdriver",
            description: Text(NSLocalizedString("tweaks.empty.detail", comment: ""))
        ) {
            Button(NSLocalizedString("tweaks.import", comment: "")) { viewModel.showImporter = true }
                .dsPrimaryButton()
                .accessibilityIdentifier("tweaks.import.empty")
        }
    }

    private var tweaksList: some View {
        Group {
            ForEach(viewModel.tweaks) { tweak in
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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
                            .dsPlainButton()
                            .accessibilityIdentifier("tweaks.analyse.\(tweak.name)")
                        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { tweakToDelete = tweak }
                            .dsPlainButton()
                    }
                    .font(.caption)
                }
            }
            Section(NSLocalizedString("tweaks.plan.title", comment: "")) {
                Picker(NSLocalizedString("tweaks.plan.app", comment: ""), selection: $viewModel.selectedAppName) {
                    Text(NSLocalizedString("tweaks.plan.selectApp", comment: "")).tag("")
                    ForEach(viewModel.availableApps, id: \.self) { name in Text(name).tag(name) }
                }
                Button(NSLocalizedString("tweaks.plan.compute", comment: "")) {
                    Task { await viewModel.computePlan() }
                }
                .dsPrimaryButton()
                .disabled(viewModel.selectedAppName.isEmpty || viewModel.isPlanning)
                if viewModel.isPlanning { ProgressView() }
                if let plan = viewModel.plan {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(item.name).font(.caption)
                            Text(item.destinationRelativePath).font(.caption).foregroundStyle(.secondary)
                            if let reason = item.skipReason {
                                Text(reason).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    ForEach(plan.warnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                    Text(plan.stockIOSWarning).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
