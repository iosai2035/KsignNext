import SwiftUI

/// Local install server (InstallationEngine + NIO server, plain HTTP).
/// Serves an itms-services manifest for a signed IPA in
/// Documents/SignedApps. Start/stop go through the real engine; if the
/// server fails to start, the error is shown — never reported as running.
@MainActor
final class InstallationViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var installURLString = ""
    @Published var errorMessage: String?
    @Published var signedApps: [String] = []
    @Published var selectedApp = ""

    private let installationEngine: InstallationEngine
    private let ipaEngine: IPAEngineProtocol

    /// - Parameters:
    ///   - installationEngine: nil builds `InstallationEngine(server:
    ///     NIOInstallationServer())`; the app passes the coordinator's
    ///     container engine.
    ///   - ipaEngine: nil builds a plain `IPAEngine()`; used to read the
    ///     selected IPA's bundle identifier / version / title.
    init(installationEngine: InstallationEngine? = nil, ipaEngine: IPAEngineProtocol? = nil) {
        self.installationEngine = installationEngine ?? InstallationEngine(server: NIOInstallationServer())
        self.ipaEngine = ipaEngine ?? IPAEngine()
    }

    func refreshSignedApps() {
        guard let docs = Workspace.documents else { return }
        let dir = docs.appendingPathComponent("SignedApps", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        signedApps = items.filter { $0.pathExtension.lowercased() == "ipa" }.map(\.lastPathComponent).sorted()
        if selectedApp.isEmpty { selectedApp = signedApps.first ?? "" }
    }

    func startServer() async {
        guard !selectedApp.isEmpty else {
            errorMessage = NSLocalizedString("install.error.noapp", comment: ""); return
        }
        guard let docs = Workspace.documents else { return }
        let ipaURL = docs.appendingPathComponent("SignedApps/\(selectedApp)")
        do {
            let metadata = try await ipaEngine.readAppMetadata(at: ipaURL)
            let session = try await installationEngine.prepareInstall(
                ipaURL: ipaURL,
                bundleIdentifier: metadata.bundleIdentifier,
                bundleVersion: metadata.version,
                title: metadata.bundleDisplayName ?? metadata.name
            )
            isRunning = true
            installURLString = session.installURL.absoluteString
            errorMessage = nil
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopServer() async {
        await installationEngine.stopServing()
        isRunning = false
        installURLString = ""
    }

    var sideStoreSteps: [String] {
        (1...5).map { String(format: NSLocalizedString("install.sidestore.step", comment: ""), $0) }
    }

    func sideStoreExportURL() -> URL? {
        guard !selectedApp.isEmpty, let docs = Workspace.documents else { return nil }
        return docs.appendingPathComponent("SignedApps/\(selectedApp)")
    }
}

struct InstallationView: View {
    @StateObject private var viewModel: InstallationViewModel

    /// - Parameter container: the app's container (from the
    ///   coordinator); nil builds fresh engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: InstallationViewModel(
            installationEngine: container?.installationEngine,
            ipaEngine: container?.ipaEngine
        ))
    }

    var body: some View {
        List {
            Section(NSLocalizedString("install.section.server", comment: "")) {
                Picker(NSLocalizedString("install.pick.app", comment: ""), selection: $viewModel.selectedApp) {
                    ForEach(viewModel.signedApps, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("install.appPicker")
                HStack {
                    Text(NSLocalizedString("install.status", comment: ""))
                    Spacer()
                    Text(viewModel.isRunning ? NSLocalizedString("install.running", comment: "") : NSLocalizedString("install.stopped", comment: ""))
                        .foregroundStyle(viewModel.isRunning ? .green : .secondary)
                }
                if viewModel.isRunning {
                    Text(viewModel.installURLString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("install.linkText")
                    Button(NSLocalizedString("install.stop", comment: ""), role: .destructive) { Task { await viewModel.stopServer() } }
                        .accessibilityIdentifier("install.stop")
                } else {
                    Button(NSLocalizedString("install.start", comment: "")) { Task { await viewModel.startServer() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("install.start")
                }
            }
            Section(NSLocalizedString("install.section.sidestore", comment: "")) {
                if let url = viewModel.sideStoreExportURL() {
                    ShareLink(item: url, preview: SharePreview(viewModel.selectedApp)) {
                        Label(NSLocalizedString("install.sidestore.export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("install.sidestoreExport")
                } else {
                    Text(NSLocalizedString("install.error.noapp", comment: "")).foregroundStyle(.secondary)
                }
                ForEach(viewModel.sideStoreSteps.indices, id: \.self) { index in
                    Text(viewModel.sideStoreSteps[index]).font(.caption)
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(NSLocalizedString("tab.installation", comment: ""))
        .onAppear { viewModel.refreshSignedApps() }
        .onDisappear { Task { if viewModel.isRunning { await viewModel.stopServer() } } }
    }
}
