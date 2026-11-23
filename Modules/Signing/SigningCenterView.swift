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

    private let signingService: SigningServiceProtocol
    init(signingService: SigningServiceProtocol = UnavailableSigningService()) {
        self.signingService = signingService
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
        do {
            progress = 0.3
            stage = NSLocalizedString("signing.stage.signing", comment: "")
            logLines.append(stage)
            let output = try await signingService.sign(appURL: appURL, certificateName: selectedCertificateName, bundleID: bundleID)
            signedOutputURL = output
            progress = 1
            stage = NSLocalizedString("signing.stage.done", comment: "")
            logLines.append(stage)
            step = .verification
            verificationPassed = true
        } catch {
            errorMessage = error.localizedDescription
            stage = NSLocalizedString("signing.stage.failed", comment: "")
            logLines.append(stage)
            verificationPassed = false
        }
        isSigning = false
    }

    func verifySignedApp() {
        guard let output = signedOutputURL else { verificationPassed = false; return }
        verificationPassed = FileManager.default.fileExists(atPath: output.path)
        if verificationPassed == true { step = .export }
    }

    func exportSignedApp() -> URL? { signedOutputURL }
}

struct SigningCenterView: View {
    @StateObject private var viewModel = SigningCenterViewModel()

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
