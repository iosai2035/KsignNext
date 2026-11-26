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
final class InstallationViewModel: ObservableObject, TwoFactorAnswering {
    @Published var isRunning = false
    @Published var installURLString = ""
    @Published var errorMessage: String?
    @Published var signedApps: [String] = []
    @Published var selectedApp = ""
    @Published var signatureExpiryText: String?
    @Published var signatureExpired = false
    @Published var appleIDEmail: String?
    @Published var exportedURL: URL?
    private var lastExportedApp = ""
    @Published var isRefreshing = false
    @Published var refreshStatus = ""

    /// 2FA state for the real refresh's sign-in (same sheet as the
    /// Settings sign-in, driven by this view model's own gate).
    @Published var twoFactorPrompt: TwoFactorPrompt?
    @Published var showing2FA = false
    @Published var twoFactorCode = ""
    @Published var codeRequested = false
    @Published var selectedNumberID: Int?
    private let twoFactorGate = TwoFactorPromptGate()

    /// The pasted device UDID for real refresh (manual fallback — no
    /// automatic lookup exists for a free Apple ID). The sign-in flow
    /// reads `udidStore.savedUDID` when registering this device.
    let udidStore = DeviceUDIDStore()

    /// The container, exposed so the view can build the Apple ID
    /// sign-in screen from it. Nil in tests / previews.
    let container: DependencyContainer?
    private let installationEngine: InstallationEngine
    private let ipaEngine: IPAEngineProtocol

    /// Background task keeping the install server alive while iOS
    /// downloads the IPA after the app is backgrounded by opening the
    /// itms-services URL. `.invalid` when no task is held.
    private var installBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Refresh needs the container (signing use case, repositories,
    /// provisioning engine). Nil in tests / previews, where the
    /// refresh button is hidden.
    var canRefresh: Bool { container != nil }

    private var refreshUseCase: RefreshApplicationUseCase? {
        guard let container else { return nil }
        return RefreshApplicationUseCase(
            signedRepository: container.signedApplicationRepository,
            certificateRepository: container.certificateRepository,
            provisioningEngine: ProvisioningEngine(keychain: container.keychain, fileManager: container.files),
            ipaEngine: ipaEngine
        )
    }

    /// - Parameters:
    ///   - container: the app's container (from the coordinator); nil
    ///     builds fresh engines (tests / previews) and disables refresh.
    ///   - installationEngine: nil uses the container's engine, else a
    ///     fresh `InstallationEngine(server: NIOInstallationServer())`.
    ///   - ipaEngine: nil uses the container's engine, else a plain
    ///     `IPAEngine()`; used to read the selected IPA's bundle
    ///     identifier / version / title.
    init(container: DependencyContainer? = nil, installationEngine: InstallationEngine? = nil, ipaEngine: IPAEngineProtocol? = nil) {
        self.container = container
        self.installationEngine = installationEngine ?? container?.installationEngine ?? InstallationEngine(server: NIOInstallationServer())
        self.ipaEngine = ipaEngine ?? container?.ipaEngine ?? IPAEngine()
    }

    func refreshSignedApps() {
        guard let docs = Workspace.documents else { return }
        let dir = docs.appendingPathComponent("SignedApps", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        signedApps = items.filter { $0.pathExtension.lowercased() == "ipa" }.map(\.lastPathComponent).sorted()
        if selectedApp.isEmpty { selectedApp = signedApps.first ?? "" }
        if selectedApp != lastExportedApp { exportedURL = nil }
        appleIDEmail = container?.appleIDSessionStore.loadSession()?.email
        Task { await loadSignatureExpiry() }
    }

    /// Reads the embedded provisioning profile of the selected signed
    /// app and shows its expiry ("expires in N days" / "expired").
    /// Nil text when there is no selected app, no container, or no
    /// embedded profile (ad-hoc).
    func loadSignatureExpiry() async {
        guard !selectedApp.isEmpty,
              let docs = Workspace.documents,
              let refreshUseCase else {
            signatureExpiryText = nil
            signatureExpired = false
            return
        }
        let ipaURL = docs.appendingPathComponent("SignedApps/\(selectedApp)")
        do {
            guard let expiry = try await refreshUseCase.profileExpiration(signedIPAURL: ipaURL) else {
                signatureExpiryText = NSLocalizedString("install.expiry.unknown", comment: "")
                signatureExpired = false
                return
            }
            if expiry < Date() {
                signatureExpiryText = NSLocalizedString("install.expiry.expired", comment: "")
                signatureExpired = true
            } else {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                signatureExpiryText = String(format: NSLocalizedString("install.expiry.days", comment: ""), days)
                signatureExpired = false
            }
        } catch {
            signatureExpiryText = nil
            signatureExpired = false
        }
    }

    /// Refreshes the selected signed app on this device, without Wi-Fi.
    /// When an Apple ID is signed in, this is the REAL refresh: a
    /// fresh provisioning profile is fetched from Apple, the app is
    /// re-signed with the fresh certificate + profile, and the new
    /// file is installed over loopback — so it also fixes an EXPIRED
    /// profile. When nobody is signed in, it falls back to the legacy
    /// same-profile re-sign (repairs a broken signature, but the
    /// profile must still be valid and expiry does not move).
    func refreshSelectedApp() async {
        guard !selectedApp.isEmpty else {
            errorMessage = NSLocalizedString("install.error.noapp", comment: ""); return
        }
        guard let docs = Workspace.documents else { return }
        guard let container, let refreshUseCase else {
            errorMessage = NSLocalizedString("install.refresh.error.nocontainer", comment: ""); return
        }
        let ipaURL = docs.appendingPathComponent("SignedApps/\(selectedApp)")
        isRefreshing = true
        refreshStatus = NSLocalizedString("install.refreshing", comment: "")
        errorMessage = nil
        defer {
            isRefreshing = false
            showing2FA = false
            twoFactorPrompt = nil
        }
        do {
            let signedURL: URL
            if container.appleIDSessionStore.loadSession() != nil {
                signedURL = try await realRefreshSignedURL(
                    ipaURL: ipaURL, container: container, refreshUseCase: refreshUseCase)
            } else {
                let plan = try await refreshUseCase.plan(signedIPAURL: ipaURL)
                let signUseCase = container.makeSignApplicationUseCase()
                let result = try await signUseCase.execute(plan.request) { [weak self] progressEvent in
                    // The progress closure is @Sendable/nonisolated; hop
                    // back to the main actor to touch @Published state.
                    Task { @MainActor in
                        self?.refreshStatus = progressEvent.message
                    }
                }
                signedURL = result.signedFileURL
            }
            refreshStatus = NSLocalizedString("install.refresh.installing", comment: "")
            try await installFile(signedURL)
            refreshStatus = NSLocalizedString("install.refresh.done", comment: "")
            refreshSignedApps()
            selectedApp = signedURL.lastPathComponent
            await loadSignatureExpiry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The real refresh for one signed app: fresh profile from
    /// Apple via `RealRefreshUseCase`, returning the re-signed IPA.
    /// Throws `.missingUDID` when the device UDID was never pasted
    /// (the UDID section on this screen is where to paste it).
    private func realRefreshSignedURL(ipaURL: URL,
                                      container: DependencyContainer,
                                      refreshUseCase: RefreshApplicationUseCase) async throws -> URL {
        guard let udid = udidStore.savedUDID else {
            throw RealRefreshError.missingUDID
        }
        let metadata = try await ipaEngine.readAppMetadata(at: ipaURL)
        let signInUseCase = container.makeAppleIDSignInUseCase()
        // 2FA for the silent sign-in inside the refresh, if Apple
        // asks for one: same gate pattern as the Settings sign-in.
        codeRequested = false
        await twoFactorGate.setPromptHandler { [weak self] prompt in
            self?.twoFactorPrompt = prompt
            self?.twoFactorCode = ""
            self?.selectedNumberID = prompt.selectedNumberID ?? prompt.numbers.first?.id
            self?.showing2FA = true
        }
        // Capture the gate (not self) in the @Sendable handler.
        let gate = twoFactorGate
        let handler: @Sendable (TwoFactorPrompt) async -> TwoFactorResponse = { prompt in
            await gate.waitForAnswer(to: prompt)
        }
        let realRefresh = RealRefreshUseCase(
            signInUseCase: signInUseCase,
            developerService: DeveloperServiceUseCase(signInUseCase: signInUseCase),
            certificateEngine: container.certificateEngine,
            certificateRepository: container.certificateRepository,
            refreshUseCase: refreshUseCase,
            signUseCase: container.makeSignApplicationUseCase())
        let result = try await realRefresh.execute(
            signedIPAURL: ipaURL,
            bundleID: metadata.bundleIdentifier,
            appName: metadata.bundleDisplayName ?? metadata.name,
            udid: udid,
            deviceName: UIDevice.current.name,
            twoFactorHandler: handler,
            onProgress: { [weak self] message in
                Task { @MainActor in
                    self?.refreshStatus = message
                }
            })
        return result.signedFileURL
    }

    // MARK: - 2FA answers (TwoFactorAnswering)

    func submitCode() {
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await twoFactorGate.answer(.code(code)) }
    }

    func requestCodeBySMS() {
        guard let id = selectedNumberID else { return }
        codeRequested = true
        Task { await twoFactorGate.answer(.sms(id: id)) }
    }

    func requestCodeOnDevices() {
        codeRequested = true
        Task { await twoFactorGate.answer(.devices) }
    }

    func resendCode() {
        Task { await twoFactorGate.answer(.resend) }
    }

    func cancel2FA() {
        Task { await twoFactorGate.answer(.abort) }
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
            try await installFile(ipaURL)
            errorMessage = nil
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    /// Prepares a loopback install session for `ipaURL`, shows its link,
    /// holds the background task, and opens the itms-services URL.
    /// Shared by "Install on this device" and by refresh (which signs
    /// a fresh file first, then installs it the same way).
    private func installFile(_ ipaURL: URL) async throws {
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
        beginInstallBackgroundTask()
        UIApplication.shared.open(session.installURL, options: [:], completionHandler: nil)
    }

    /// Starts the install server on entry when the Settings toggle
    /// `ksign.install.autoStartServer` is on. Does nothing when the
    /// toggle is off, when no app is selected, or when the server is
    /// already running; a start failure is reported through
    /// `errorMessage` by `startServer` itself.
    func autoStartServerIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: "ksign.install.autoStartServer"),
              !isRunning, !selectedApp.isEmpty else { return }
        await startServer()
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

    var installerGuide: ExternalInstallerGuide { installationEngine.installerGuide() }

    /// Copies the selected signed IPA into the Files-visible
    /// IPAExports folder. A numbered name is used when the file
    /// already exists; the ShareLink shares the exported copy.
    func exportSelectedApp() {
        guard !selectedApp.isEmpty, let docs = Workspace.documents else { return }
        let ipaURL = docs.appendingPathComponent("SignedApps/\(selectedApp)")
        do {
            let record = try installationEngine.exportIPA(ipaURL: ipaURL)
            exportedURL = record.fileURL
            lastExportedApp = selectedApp
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct InstallationView: View {
    @StateObject private var viewModel: InstallationViewModel

    /// - Parameter container: the app's container (from the
    ///   coordinator); nil builds fresh engines (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: InstallationViewModel(container: container))
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
                    if let expiry = viewModel.signatureExpiryText {
                        Text(expiry)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("install.expiryText")
                    }
                    if viewModel.canRefresh {
                        Button(NSLocalizedString("install.refresh", comment: "")) { Task { await viewModel.refreshSelectedApp() } }
                            .buttonStyle(.bordered)
                            // An expired profile blocks only the legacy
                            // same-profile refresh; the real refresh
                            // (signed in) fetches a fresh profile, so
                            // it stays enabled when signed in.
                            .disabled(viewModel.isRefreshing || viewModel.selectedApp.isEmpty || (viewModel.signatureExpired && viewModel.appleIDEmail == nil))
                            .accessibilityIdentifier("install.refresh")
                        if viewModel.isRefreshing {
                            ProgressView(viewModel.refreshStatus)
                                .accessibilityIdentifier("install.refreshProgress")
                        }
                    }
                    if let container = viewModel.container {
                        NavigationLink {
                            AppleIDSignInView(useCase: container.makeAppleIDSignInUseCase())
                        } label: {
                            HStack {
                                Text(NSLocalizedString("appleid.title", comment: ""))
                                Spacer()
                                Text(viewModel.appleIDEmail
                                     ?? NSLocalizedString("appleid.notsignedin", comment: ""))
                                    .font(.caption)
                                    .foregroundColor(viewModel.appleIDEmail == nil ? .secondary : .green)
                            }
                        }
                        .accessibilityIdentifier("install.appleid")
                    }
                }
            }
            DeviceUDIDSection(store: viewModel.udidStore)
            Section(NSLocalizedString("install.section.export", comment: "")) {
                if viewModel.selectedApp.isEmpty {
                    Text(NSLocalizedString("install.error.noapp", comment: "")).foregroundStyle(.secondary)
                } else {
                    Button(NSLocalizedString("install.export", comment: "")) { viewModel.exportSelectedApp() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("install.export")
                    if let url = viewModel.exportedURL {
                        ShareLink(item: url, preview: SharePreview(viewModel.selectedApp)) {
                            Label(NSLocalizedString("install.export.share", comment: ""), systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("install.exportShare")
                    }
                }
                Text(viewModel.installerGuide.introduction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(viewModel.installerGuide.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(step.order). \(step.title)").font(.caption).bold()
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(viewModel.installerGuide.limits, id: \.name) { limit in
                    Text("\(limit.name): \(limit.value) — \(limit.note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(NSLocalizedString("install.export.wifi", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(NSLocalizedString("tab.installation", comment: ""))
        .sheet(isPresented: $viewModel.showing2FA) {
            if let prompt = viewModel.twoFactorPrompt {
                TwoFactorSheet(prompt: prompt, viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.refreshSignedApps()
            Task { await viewModel.autoStartServerIfEnabled() }
        }
        .onChange(of: viewModel.selectedApp) { _ in Task { await viewModel.loadSignatureExpiry() } }
        .onDisappear { Task { if viewModel.isRunning { await viewModel.stopServer() } } }
    }
}
