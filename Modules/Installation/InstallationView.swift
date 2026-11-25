import SwiftUI
import UIKit

/// Local install server (InstallationEngine + NIO server, plain HTTP).
/// Serves an itms-services manifest for a signed IPA in
/// Documents/SignedApps. Start/stop go through the real engine; if the
/// server fails to start, the error is shown — never reported as running.
///
/// Two install destinations:
/// * **This device** — the server is advertised on loopback (127.0.0.1),
///   so it works without Wi-Fi: on cellular data or with no network at
///   all. Tapping it opens the itms-services URL right away, and a
///   background task keeps the server alive while iOS downloads the IPA.
/// * **Another device** — the server is advertised on the Wi-Fi (LAN)
///   address; the other device opens the shown link on the same network.
///   This one needs Wi-Fi, and fails with a clear error without it.
@MainActor
final class InstallationViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var installURLString = ""
    @Published var errorMessage: String?
    @Published var signedApps: [String] = []
    @Published var selectedApp = ""

    private let installationEngine: InstallationEngine
    private let ipaEngine: IPAEngineProtocol

    /// Background task keeping the install server alive while iOS
    /// downloads the IPA after the app is backgrounded by opening the
    /// itms-services URL. `.invalid` when no task is held.
    private var installBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

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

    /// Prepares an install for `destination` and shows its link.
    /// `.thisDevice` (loopback) needs no Wi-Fi; `.anotherDevice` needs
    /// the device on Wi-Fi and throws a clear error without it.
    func startServer(destination: InstallDestination = .anotherDevice) async {
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
                title: metadata.bundleDisplayName ?? metadata.name,
                destination: destination
            )
            isRunning = true
            installURLString = session.installURL.absoluteString
            errorMessage = nil
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    /// Installs the selected signed app on this device, without Wi-Fi:
    /// prepares a loopback session, holds a background task so the
    /// server survives while iOS downloads the IPA, then opens the
    /// itms-services URL. The link stays visible in the UI as a fallback
    /// if opening it fails.
    func installOnThisDevice() async {
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
                title: metadata.bundleDisplayName ?? metadata.name,
                destination: .thisDevice
            )
            isRunning = true
            installURLString = session.installURL.absoluteString
            errorMessage = nil
            beginInstallBackgroundTask()
            UIApplication.shared.open(session.installURL, options: [:], completionHandler: nil)
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stopServer() async {
        endInstallBackgroundTask()
        await installationEngine.stopServing()
        isRunning = false
        installURLString = ""
    }

    /// Holds a background task so the install server keeps running while
    /// iOS downloads the IPA after this app is backgrounded. Ends itself
    /// after two minutes at the latest; the loopback download takes
    /// seconds, and the server keeps running in the foreground if the
    /// user comes back to the app.
    private func beginInstallBackgroundTask() {
        endInstallBackgroundTask()
        installBackgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in
                self?.endInstallBackgroundTask()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            self?.endInstallBackgroundTask()
        }
    }

    private func endInstallBackgroundTask() {
        guard installBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(installBackgroundTaskID)
        installBackgroundTaskID = .invalid
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
                    Button(NSLocalizedString("install.thisdevice", comment: "")) { Task { await viewModel.installOnThisDevice() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("install.thisDevice")
                    Text(NSLocalizedString("install.thisdevice.note", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("install.otherdevice", comment: "")) { Task { await viewModel.startServer(destination: .anotherDevice) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("install.otherDevice")
                    Text(NSLocalizedString("install.otherdevice.note", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text(NSLocalizedString("install.sidestore.wifi", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
