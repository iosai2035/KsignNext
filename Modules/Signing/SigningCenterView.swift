import SwiftUI

/// 12-step signing wizard. Each step validates before advancing.
enum SigningStep: Int, CaseIterable, Identifiable {
    case app = 1, certificate, provisioning, bundleID, nameVersion, entitlements, tweaks, summary, start, progress, verification, export
    var id: Int { rawValue }
    var titleKey: String { "signing.step.\(rawValue)" }
    var accessibilityID: String { "signing.step.\(rawValue)" }
}

enum SigningBackendError: LocalizedError, Equatable {
    case backendNotLinked
    case noAppSelected
    case noCertificateSelected
    var errorDescription: String? {
        switch self {
        case .backendNotLinked: return NSLocalizedString("signing.error.backend", comment: "")
        case .noAppSelected: return NSLocalizedString("signing.error.noapp", comment: "")
        case .noCertificateSelected: return NSLocalizedString("signing.error.nocert", comment: "")
        }
    }
}

/// Kept intentionally: the tests assert the honest "backend not
/// linked" error through this service (SigningStateTests,
/// ImportSignExportFlowTests). The wizard itself no longer uses it —
/// it runs the real `SignApplicationUseCase` now.
protocol SigningServiceProtocol {
    func sign(appURL: URL, certificateName: String, bundleID: String) async throws -> URL
}

/// Honest default: the native zsign backend is not linked in this build, so signing
/// reports that instead of faking success.
struct UnavailableSigningService: SigningServiceProtocol {
    func sign(appURL: URL, certificateName: String, bundleID: String) async throws -> URL {
        throw SigningBackendError.backendNotLinked
    }
}

/// Bundle-ID rules shared by the wizard and the tests (reverse-DNS, no leading digit in a label).
struct WizardBundleIDValidator {
    static func isValid(_ id: String) -> Bool {
        // Keep empty labels: split omits them by default, which let a
        // leading dot (".com.example") slip through as a valid ID.
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !(part.first?.isNumber ?? false)
        }
    }
}

@MainActor
final class SigningCenterViewModel: ObservableObject {
    @Published var step: SigningStep = .app
    @Published var selectedAppName = ""
    @Published var selectedCertificateName = ""
    @Published var selectedProvisionName = ""
    @Published var bundleID = ""
    @Published var appName = ""
    @Published var appVersion = "1.0"
    @Published var entitlementsText = ""
    @Published var selectedTweakNames: [String] = []
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var logLines: [String] = []
    @Published var isSigning = false
    @Published var errorMessage: String?
    @Published var signedOutputURL: URL?
    @Published var verificationPassed: Bool?
    @Published var showAppPicker = false
    @Published var showCertPicker = false
    @Published var showProvisionPicker = false

    private let container: DependencyContainer
    private let signUseCase: SignApplicationUseCase
    private let verifyUseCase: VerifySignatureUseCase
    private let verificationEngine: VerificationEngine

    /// - Parameters:
    ///   - container: when nil, a fresh `DependencyContainer()` is built
    ///     and its factories are used (so no-arg construction in tests
    ///     keeps working); the app passes the coordinator's container.
    ///   - signUseCase / verifyUseCase / verificationEngine: injectable
    ///     overrides; nil falls back to the container's factories.
    init(
        container: DependencyContainer? = nil,
        signUseCase: SignApplicationUseCase? = nil,
        verifyUseCase: VerifySignatureUseCase? = nil,
        verificationEngine: VerificationEngine? = nil
    ) {
        let container = container ?? DependencyContainer()
        self.container = container
        self.signUseCase = signUseCase ?? container.makeSignApplicationUseCase()
        self.verifyUseCase = verifyUseCase ?? container.makeVerifySignatureUseCase()
        self.verificationEngine = verificationEngine ?? container.verificationEngine
    }

    /// The Settings toggle `ksign.signing.verifyAfterSign` (default
    /// true): when on, the engine verifies the signature inside the
    /// signing run in addition to the wizard's explicit verification
    /// step.
    private var verifyAfterSigningEnabled: Bool {
        UserDefaults.standard.object(forKey: "ksign.signing.verifyAfterSign") as? Bool ?? true
    }

    var availableApps: [String] { listNames(folder: "ImportedApps", ext: "ipa") }
    var availableCertificates: [String] { listNames(folder: "Certificates", ext: nil) }
    var availableProvisions: [String] { listNames(folder: "Certificates", ext: "mobileprovision") }
    var availableTweaks: [String] { listNames(folder: "Tweaks", ext: nil) }

    private func listNames(folder: String, ext: String?) -> [String] {
        guard let docs = Workspace.documents else { return [] }
        let dir = docs.appendingPathComponent(folder, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { ext == nil || $0.pathExtension.lowercased() == ext }
            .map(\.lastPathComponent).sorted()
    }

    func canAdvance(from current: SigningStep) -> Bool {
        switch current {
        case .app: return !selectedAppName.isEmpty
        case .certificate: return !selectedCertificateName.isEmpty
        case .provisioning: return true // Optional: a provisioning profile is not always required.
        case .bundleID: return WizardBundleIDValidator.isValid(bundleID)
        case .nameVersion: return !appName.isEmpty && !appVersion.isEmpty
        case .entitlements: return true
        case .tweaks: return true
        case .summary: return true
        case .start: return true
        case .progress: return !isSigning
        case .verification: return verificationPassed == true
        case .export: return signedOutputURL != nil
        }
    }

    func validationMessage(for current: SigningStep) -> String? {
        if canAdvance(from: current) { return nil }
        switch current {
        case .app: return NSLocalizedString("signing.error.noapp", comment: "")
        case .certificate: return NSLocalizedString("signing.error.nocert", comment: "")
        case .bundleID: return NSLocalizedString("signing.error.bundleid", comment: "")
        case .nameVersion: return NSLocalizedString("signing.error.nameversion", comment: "")
        case .verification: return NSLocalizedString("signing.error.verify", comment: "")
        case .export: return NSLocalizedString("signing.error.nooutput", comment: "")
        default: return nil
        }
    }

    func next() {
        guard let message = validationMessage(for: step) else {
            if let next = SigningStep(rawValue: step.rawValue + 1) { step = next }
            return
        }
        errorMessage = message
    }

    func back() {
        if let prev = SigningStep(rawValue: step.rawValue - 1) { step = prev }
    }

    func startSigning() async {
        guard let docs = Workspace.documents else { return }
        let appURL = docs.appendingPathComponent("ImportedApps/\(selectedAppName)")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            errorMessage = SigningBackendError.noAppSelected.localizedDescription; return
        }
        isSigning = true
        progress = 0
        stage = NSLocalizedString("signing.stage.preparing", comment: "")
        logLines = [stage]
        step = .progress
        errorMessage = nil
        do {
            let request = try await buildSigningRequest(appURL: appURL, docs: docs)
            let result = try await signUseCase.execute(request) { [weak self] progressEvent in
                // The progress closure is @Sendable/nonisolated; hop back
                // to the main actor to touch @Published state.
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = progressEvent.progress
                    self.stage = progressEvent.message
                    self.logLines.append(progressEvent.message)
                }
            }
            signedOutputURL = result.signedFileURL
            progress = 1
            stage = NSLocalizedString("signing.stage.done", comment: "")
            logLines.append(stage)
            step = .verification
            // verificationPassed stays nil until verifySignedApp() runs:
            // signing success is not verification success.
        } catch {
            errorMessage = error.localizedDescription
            stage = NSLocalizedString("signing.stage.failed", comment: "")
            logLines.append(stage)
            verificationPassed = false
        }
        isSigning = false
    }

    /// Builds the full signing request from the wizard's fields,
    /// resolving the picked names to repository records where the
    /// repositories are the source of truth.
    private func buildSigningRequest(appURL: URL, docs: URL) async throws -> SigningRequest {
        // Imported record (only when the app came in through the import
        // flow); otherwise a fresh correlation id — the use case does
        // not look the imported id up, it only carries it into the
        // persisted signing result.
        let importedIPAID: UUID
        if let records = try? await container.importedApplicationRepository.fetchAll(),
           let match = records.first(where: { $0.fileURL.lastPathComponent == selectedAppName }) {
            importedIPAID = match.id
        } else {
            importedIPAID = UUID()
        }

        // Certificate record. Importing a P12 in the Certificates tab
        // registers it in the repository (see CertificatesViewModel),
        // so a certificate picked here normally resolves; a file that
        // was only copied into the workspace without registering
        // cannot resolve, and the use case then refuses with a typed
        // error instead of signing with the wrong identity.
        var certificateID: UUID?
        if !selectedCertificateName.isEmpty {
            let certificates = (try? await container.certificateRepository.fetchAll()) ?? []
            certificateID = certificates.first(where: {
                $0.fileURL?.lastPathComponent == selectedCertificateName || $0.name == selectedCertificateName
            })?.id
        }

        // Provisioning profile: parse the picked file to get its stable
        // id (the engine's resolver matches profiles by this id).
        var provisioningProfileID: UUID?
        if !selectedProvisionName.isEmpty {
            let provisionURL = docs.appendingPathComponent("Certificates/\(selectedProvisionName)")
            let provisioningEngine = ProvisioningEngine(keychain: container.keychain, fileManager: container.files)
            if let profile = try? await provisioningEngine.parseProvisioningProfile(at: provisionURL) {
                provisioningProfileID = profile.id
            }
        }

        // Entitlements: write the wizard text to a temp .entitlements
        // file when the user entered any.
        var entitlementsURL: URL?
        if !entitlementsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("KsignNext-entitlements-\(UUID().uuidString).entitlements")
            try entitlementsText.write(to: url, atomically: true, encoding: .utf8)
            entitlementsURL = url
        }

        let injectionFiles: [URL] = selectedTweakNames.compactMap { name in
            let url = docs.appendingPathComponent("Tweaks/\(name)")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let configuration = SigningConfiguration(
            certificateID: certificateID,
            provisioningProfileID: provisioningProfileID,
            bundleIdentifier: bundleID,
            displayName: appName.isEmpty ? nil : appName,
            version: appVersion.isEmpty ? nil : appVersion,
            entitlementsURL: entitlementsURL,
            // The wizard also verifies explicitly in the verification
            // step (verifySignedApp). The Settings toggle
            // `ksign.signing.verifyAfterSign` asks the engine to
            // verify inside the signing run as well.
            verifyAfterSigning: verifyAfterSigningEnabled,
            injectionFiles: injectionFiles
        )
        return SigningRequest(
            importedIPAID: importedIPAID,
            sourceURL: appURL,
            configuration: configuration
        )
    }

    /// Real post-sign verification of the signed IPA. Runs the
    /// structural verification report AND the signing engine's own
    /// verification, and passes only when both agree the signature is
    /// present and matches the bundle id. The report's
    /// provisioning-profile checks are deliberately NOT in the gate:
    /// an ad-hoc signature has no profile and is still a valid
    /// signature (the engine check above is the pass/fail for "the
    /// signature is present and matches the bundle id").
    func verifySignedApp() {
        guard let output = signedOutputURL else { verificationPassed = false; return }
        verificationPassed = nil
        errorMessage = nil
        Task {
            do {
                // The signed output is an IPA file, so verifyIPA (not
                // verifyApp, which takes an extracted .app bundle).
                let report = try await verificationEngine.verifyIPA(at: output)
                let outcome = try await verifyUseCase.execute(signedURL: output, bundleIdentifier: bundleID)
                let signatureCheckNames: Set<String> = [
                    "info-plist-valid",
                    "executable-exists",
                    "code-signature-load-command",
                    "code-resources",
                    "bundle-id-matches-profile"
                ]
                let signatureChecks = report.checks.filter { signatureCheckNames.contains($0.name) }
                let signatureOK = !signatureChecks.isEmpty && signatureChecks.allSatisfy(\.passed)
                let passed = outcome.isValid && signatureOK
                verificationPassed = passed
                if passed {
                    step = .export
                } else {
                    errorMessage = report.errors.first ?? NSLocalizedString("signing.error.verify", comment: "")
                }
            } catch {
                verificationPassed = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportSignedApp() -> URL? { signedOutputURL }
}

struct SigningCenterView: View {
    @StateObject private var viewModel: SigningCenterViewModel

    /// - Parameter container: the app's container (from the
    ///   coordinator); nil builds a fresh one (tests / previews).
    /// - Parameter preselectedAppName: file name (with extension) of
    ///   an imported IPA to pre-select in the wizard, e.g. when coming
    ///   from an app's detail screen. Nil starts with no app chosen.
    init(container: DependencyContainer? = nil, preselectedAppName: String? = nil) {
        let viewModel = SigningCenterViewModel(container: container)
        if let preselectedAppName { viewModel.selectedAppName = preselectedAppName }
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(viewModel.step.rawValue), total: 12)
                    .padding(.horizontal)
                    .accessibilityIdentifier("signing.progress")
                Text(NSLocalizedString(viewModel.step.titleKey, comment: ""))
                    .font(.headline)
                    .padding(.top, 8)
                    .accessibilityIdentifier(viewModel.step.accessibilityID)
                ScrollView {
                    stepContent
                        .padding()
                }
                HStack {
                    if viewModel.step.rawValue > 1 {
                        Button(NSLocalizedString("common.back", comment: "")) { viewModel.back() }
                            .accessibilityIdentifier("signing.back")
                    }
                    Spacer()
                    if viewModel.step == .start {
                        Button(NSLocalizedString("signing.start", comment: "")) {
                            Task { await viewModel.startSigning() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("signing.start")
                    } else if viewModel.step == .verification {
                        Button(NSLocalizedString("signing.verify", comment: "")) { viewModel.verifySignedApp() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("signing.verify")
                    } else if viewModel.step != .progress {
                        Button(NSLocalizedString("common.next", comment: "")) { viewModel.next() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("signing.next")
                    }
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("tab.signing", comment: ""))
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
            .sheet(isPresented: $viewModel.showAppPicker) { pickerSheet(title: NSLocalizedString("signing.pick.app", comment: ""), items: viewModel.availableApps) { viewModel.selectedAppName = $0 } }
            .sheet(isPresented: $viewModel.showCertPicker) { pickerSheet(title: NSLocalizedString("signing.pick.cert", comment: ""), items: viewModel.availableCertificates) { viewModel.selectedCertificateName = $0 } }
            .sheet(isPresented: $viewModel.showProvisionPicker) { pickerSheet(title: NSLocalizedString("signing.pick.provision", comment: ""), items: viewModel.availableProvisions) { viewModel.selectedProvisionName = $0 } }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .app:
            pickRow(NSLocalizedString("signing.pick.app", comment: ""), value: viewModel.selectedAppName, empty: NSLocalizedString("apps.empty", comment: "")) { viewModel.showAppPicker = true }
        case .certificate:
            pickRow(NSLocalizedString("signing.pick.cert", comment: ""), value: viewModel.selectedCertificateName, empty: NSLocalizedString("certs.empty", comment: "")) { viewModel.showCertPicker = true }
        case .provisioning:
            pickRow(NSLocalizedString("signing.pick.provision", comment: ""), value: viewModel.selectedProvisionName, empty: NSLocalizedString("signing.provision.optional", comment: "")) { viewModel.showProvisionPicker = true }
        case .bundleID:
            TextField("com.example.app", text: $viewModel.bundleID)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .accessibilityIdentifier("signing.bundleID")
            Text(NSLocalizedString("signing.bundleid.help", comment: "")).font(.caption).foregroundStyle(.secondary)
        case .nameVersion:
            TextField(NSLocalizedString("signing.appname", comment: ""), text: $viewModel.appName)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("signing.appName")
            TextField(NSLocalizedString("signing.appversion", comment: ""), text: $viewModel.appVersion)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("signing.appVersion")
        case .entitlements:
            TextEditor(text: $viewModel.entitlementsText)
                .frame(minHeight: 160)
                .border(Color.secondary.opacity(0.3))
                .accessibilityIdentifier("signing.entitlements")
            Text(NSLocalizedString("signing.entitlements.help", comment: "")).font(.caption).foregroundStyle(.secondary)
        case .tweaks:
            if viewModel.availableTweaks.isEmpty {
                Text(NSLocalizedString("tweaks.empty", comment: "")).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.availableTweaks, id: \.self) { tweak in
                    Toggle(tweak, isOn: Binding(
                        get: { viewModel.selectedTweakNames.contains(tweak) },
                        set: { on in
                            if on { viewModel.selectedTweakNames.append(tweak) }
                            else { viewModel.selectedTweakNames.removeAll { $0 == tweak } }
                        }
                    ))
                }
            }
        case .summary:
            summaryView
        case .start:
            Text(NSLocalizedString("signing.start.detail", comment: ""))
        case .progress:
            SigningProgressView(progress: viewModel.progress, stage: viewModel.stage, logLines: viewModel.logLines)
        case .verification:
            if let passed = viewModel.verificationPassed {
                Label(passed ? NSLocalizedString("signing.verify.passed", comment: "") : NSLocalizedString("signing.verify.failed", comment: ""),
                      systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(passed ? .green : .red)
                    .accessibilityIdentifier("signing.verificationResult")
            } else {
                Text(NSLocalizedString("signing.verify.pending", comment: ""))
            }
        case .export:
            if let url = viewModel.signedOutputURL {
                ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                    Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("signing.export")
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("signing.error.nooutput", comment: ""))
            }
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow(NSLocalizedString("signing.pick.app", comment: ""), viewModel.selectedAppName)
            summaryRow(NSLocalizedString("signing.pick.cert", comment: ""), viewModel.selectedCertificateName)
            summaryRow(NSLocalizedString("signing.pick.provision", comment: ""), viewModel.selectedProvisionName)
            summaryRow(NSLocalizedString("signing.bundleid", comment: ""), viewModel.bundleID)
            summaryRow(NSLocalizedString("signing.appname", comment: ""), viewModel.appName)
            summaryRow(NSLocalizedString("signing.appversion", comment: ""), viewModel.appVersion)
            summaryRow(NSLocalizedString("tab.tweaks", comment: ""), viewModel.selectedTweakNames.joined(separator: ", "))
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "—" : value) }
    }

    private func pickRow(_ label: String, value: String, empty: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            Text(value.isEmpty ? empty : value).foregroundStyle(value.isEmpty ? .secondary : .primary)
            Button(NSLocalizedString("common.choose", comment: ""), action: action)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("signing.choose")
        }
    }

    private func pickerSheet(title: String, items: [String], onPick: @escaping (String) -> Void) -> some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    EmptyStateView(title, systemImage: "tray", description: Text(NSLocalizedString("common.no.items", comment: "")))
                } else {
                    ForEach(items, id: \.self) { item in
                        Button(item) { onPick(item) }
                            .accessibilityIdentifier("signing.picker.\(item)")
                    }
                }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("common.cancel", comment: "")) { dismissPicker() } } }
        }
    }

    private func dismissPicker() {
        viewModel.showAppPicker = false
        viewModel.showCertPicker = false
        viewModel.showProvisionPicker = false
    }
}
