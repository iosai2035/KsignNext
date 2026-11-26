import SwiftUI
import UniformTypeIdentifiers

struct StoredCertificate: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var kind: String { url.pathExtension.lowercased() == "p12" ? "P12" : "mobileprovision" }
}

@MainActor
final class CertificatesViewModel: ObservableObject {
    @Published var certificates: [StoredCertificate] = []
    @Published var errorMessage: String?
    @Published var showP12Importer = false
    @Published var showProvisionImporter = false
    @Published var pendingP12URL: URL?
    @Published var p12Password = "" // Held in memory only; never logged, never written to disk.

    /// Development certificates on the Apple account (Phase 2),
    /// listed live from Apple's developer service when signed in.
    @Published var devCertificates: [DevelopmentCertificate] = []
    @Published var devCertificatesLoading = false
    /// True once the first dev-certificate load has finished (success
    /// or failure). The list screen waits for this before showing an
    /// empty state, so a signed-in user never sees a flashing
    /// "no certificates" state while the load is still in flight.
    @Published var devCertificatesLoaded = false
    @Published var isCreatingDevCertificate = false

    /// True when an Apple ID session exists (the live client is
    /// what the developer-services calls run on).
    var isSignedIn: Bool { container.appleIDSessionStore.loadSession() != nil }

    private func developerService() -> DeveloperServiceUseCase {
        DeveloperServiceUseCase(signInUseCase: container.makeAppleIDSignInUseCase())
    }

    /// Lists the account's iOS development certificates from Apple.
    /// A live sign-in is required; without one the list is empty.
    /// (A background refresh, not a user action, so not being signed
    /// in stays silent here; a missing team on a signed-in account
    /// is a real error and is reported.)
    func loadDevCertificates() async {
        guard isSignedIn else { devCertificates = []; return }
        devCertificatesLoaded = false
        devCertificatesLoading = true
        defer {
            devCertificatesLoading = false
            devCertificatesLoaded = true
        }
        do {
            let service = developerService()
            guard let team = try await service.firstTeam() else {
                devCertificates = []
                errorMessage = NSLocalizedString("certs.error.noTeam", comment: "")
                return
            }
            devCertificates = try await service.listCertificates(teamID: team.teamID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates (or reuses) the on-device development certificate
    /// and imports its .p12 into the Certificates store, so it can
    /// sign apps. On the certificate limit (7460) this fails with
    /// the limit message — revoke an old certificate below first.
    func createDevCertificate() async {
        guard isSignedIn else {
            errorMessage = NSLocalizedString("certs.error.notSignedIn", comment: "")
            return
        }
        isCreatingDevCertificate = true
        defer { isCreatingDevCertificate = false }
        do {
            let service = developerService()
            guard let team = try await service.firstTeam() else {
                errorMessage = NSLocalizedString("certs.error.noTeam", comment: "")
                return
            }
            guard let email = container.appleIDSessionStore.loadSession()?.email else {
                errorMessage = NSLocalizedString("certs.error.noEmail", comment: "")
                return
            }
            let created = try await service.createCertificate(teamID: team.teamID, email: email)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("KsignNext-Development-\(UUID().uuidString).p12")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try created.p12Data.write(to: tempURL, options: [.atomic])
            let model = try await certificateEngine.importP12(at: tempURL, password: created.p12Password)
            try await certificateRepository.save(model)
            refresh()
            await loadDevCertificates()
        } catch {
            // AppleRefreshError already carries the plain 7460
            // limit message ("revoke an old certificate…").
            errorMessage = error.localizedDescription
        }
    }

    /// Revokes one development certificate on the account (by
    /// serial number). The matching local .p12, if any, stays —
    /// delete it from the list above when it is no longer needed.
    func revokeDevCertificate(_ cert: DevelopmentCertificate) async {
        guard isSignedIn else {
            errorMessage = NSLocalizedString("certs.error.notSignedIn", comment: "")
            return
        }
        guard let serial = cert.serialNumber else {
            errorMessage = NSLocalizedString("certs.error.noSerial", comment: "")
            return
        }
        do {
            let service = developerService()
            guard let team = try await service.firstTeam() else {
                errorMessage = NSLocalizedString("certs.error.noTeam", comment: "")
                return
            }
            try await service.revokeCertificate(teamID: team.teamID, serialNumber: serial)
            await loadDevCertificates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private let container: DependencyContainer
    private let certificateEngine: CertificateEngineProtocol
    private let certificateRepository: CertificateRepository

    /// - Parameters:
    ///   - container: when nil, a fresh `DependencyContainer()` is built
    ///     and its engine/repository are used (so no-arg construction in
    ///     tests keeps working); the app passes the coordinator's
    ///     container.
    init(
        container: DependencyContainer? = nil,
        certificateEngine: CertificateEngineProtocol? = nil,
        certificateRepository: CertificateRepository? = nil
    ) {
        let container = container ?? DependencyContainer()
        self.container = container
        self.certificateEngine = certificateEngine ?? container.certificateEngine
        self.certificateRepository = certificateRepository ?? container.certificateRepository
    }

    /// Synchronous directory listing — it is a fast local read, so
    /// there is no loading state here (a spinner around it only
    /// flashed). The async loads above keep their own flags.
    func refresh() {
        guard let dir = Workspace.folder("Certificates") else {
            errorMessage = NSLocalizedString("certs.error.storage", comment: "")
            return
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        certificates = items.filter { ["p12", "mobileprovision"].contains($0.pathExtension.lowercased()) }
            .map { StoredCertificate(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func importFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = NSLocalizedString("error.file.access", comment: ""); return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let destDir = Workspace.folder("Certificates") else {
            errorMessage = NSLocalizedString("certs.error.storage", comment: "")
            return
        }
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            refresh()
        } catch { errorMessage = error.localizedDescription; return }
        // A P12 imported with its password is also REGISTERED: the
        // engine parses it, stores the password in the Keychain and
        // returns the model, which is saved in the certificate
        // repository. Without this the signing flow cannot resolve the
        // certificate (it looks it up by id in the repository) and
        // refuses to sign. The engine copies the file to its own
        // stored location (<base>-<id>.p12) in the same folder, so the
        // plain copy above is removed afterwards.
        if dest.pathExtension.lowercased() == "p12", !p12Password.isEmpty {
            let password = p12Password
            p12Password = ""
            Task {
                do {
                    let model = try await certificateEngine.importP12(at: dest, password: password)
                    try await certificateRepository.save(model)
                    try? FileManager.default.removeItem(at: dest)
                } catch {
                    errorMessage = error.localizedDescription
                }
                refresh()
            }
        }
    }

    func delete(_ cert: StoredCertificate) {
        do {
            try FileManager.default.removeItem(at: cert.url)
            refresh()
        } catch { errorMessage = error.localizedDescription }
        // Also drop the repository record (and its Keychain password)
        // when the deleted file was a registered certificate, so a
        // stale record can never make signing pick a missing identity.
        Task {
            let records = (try? await certificateRepository.fetchAll()) ?? []
            if let match = records.first(where: { $0.fileURL == cert.url }) {
                try? await certificateRepository.delete(id: match.id)
                if let account = match.keychainAccount {
                    try? container.keychain.delete(account: account)
                }
            }
            refresh()
        }
    }

    /// Validates a P12 with the in-memory password via SecPKCS12Import. Password is never stored.
    /// The password is deliberately NOT cleared here: the sheet's
    /// confirm action calls `importFile` right after a successful
    /// validation, and `importFile` reads `p12Password` to register
    /// the certificate (engine import + repository save + Keychain).
    /// Clearing it here used to make every manual P12 import silently
    /// skip registration. `importFile` clears it once consumed.
    /// On failure the password is kept so the user can retry.
    func validateP12() -> Result<String, Error> {
        guard let url = pendingP12URL, let data = try? Data(contentsOf: url) else {
            return .failure(NSError(domain: "KsignNext", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cert.error.read", comment: "")]))
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: p12Password] as CFDictionary, &items)
        if status != errSecSuccess {
            return .failure(NSError(domain: "KsignNext", code: Int(status), userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cert.error.password", comment: "")]))
        }
        return .success(NSLocalizedString("cert.valid", comment: ""))
    }

    /// Clears all password-sheet state (pending file, typed password,
    /// validation result). Called on Cancel and after a successful
    /// import, so a stale URL or password can never leak into the
    /// next import.
    func clearPasswordSheetState() {
        pendingP12URL = nil
        p12Password = ""
        // validationResult lives in the view; the view clears it
        // alongside this call (see CertificatesView.passwordSheet).
    }
}

struct CertificatesView: View {
    @StateObject private var viewModel: CertificatesViewModel
    @State private var certToDelete: StoredCertificate?
    @State private var certToRevoke: DevelopmentCertificate?
    @State private var selectedCert: StoredCertificate?
    @State private var showPasswordSheet = false
    @State private var validationResult: String?

    /// - Parameter container: the app's container (from the
    ///   coordinator); nil builds a fresh one (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: CertificatesViewModel(container: container))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.certificates.isEmpty && viewModel.devCertificates.isEmpty {
                    if !viewModel.isSignedIn {
                        emptyState
                    } else if !viewModel.devCertificatesLoaded {
                        // Signed in but the live list has not answered
                        // yet: a spinner, never a flashing empty state.
                        ProgressView(NSLocalizedString("common.loading", comment: ""))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        signedInEmptyState
                    }
                } else {
                    List {
                        devCertificatesSection
                        localCertificatesSection
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tab.certificates", comment: ""))
            .dsLargeTitle()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu(NSLocalizedString("certs.import", comment: "")) {
                        Button(NSLocalizedString("certs.import.p12", comment: "")) { viewModel.showP12Importer = true }
                            .accessibilityIdentifier("certs.import.p12")
                        Button(NSLocalizedString("certs.import.provision", comment: "")) { viewModel.showProvisionImporter = true }
                            .accessibilityIdentifier("certs.import.provision")
                    }
                }
            }
            .fileImporter(isPresented: $viewModel.showP12Importer, allowedContentTypes: [.init(filenameExtension: "p12") ?? .data]) { result in
                switch result {
                case .success(let url):
                    viewModel.pendingP12URL = url; showPasswordSheet = true
                case .failure(let error): viewModel.errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $viewModel.showProvisionImporter, allowedContentTypes: [.init(filenameExtension: "mobileprovision") ?? .data]) { result in
                switch result {
                case .success(let url): viewModel.importFile(url)
                case .failure(let error): viewModel.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showPasswordSheet) { passwordSheet }
            .onAppear {
                viewModel.refresh()
                Task { await viewModel.loadDevCertificates() }
            }
            .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: Binding(get: { certToDelete != nil }, set: { if !$0 { certToDelete = nil } })) {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                    if let c = certToDelete { viewModel.delete(c) }
                    certToDelete = nil
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { certToDelete = nil }
            }
            .alert(NSLocalizedString("certs.dev.revoke.confirm", comment: ""), isPresented: Binding(get: { certToRevoke != nil }, set: { if !$0 { certToRevoke = nil } })) {
                Button(NSLocalizedString("common.revoke", comment: ""), role: .destructive) {
                    if let c = certToRevoke { Task { await viewModel.revokeDevCertificate(c) } }
                    certToRevoke = nil
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { certToRevoke = nil }
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
            // `navigationDestination(item:)` needs iOS 17; the `isPresented`
            // variant works from iOS 16.
            .navigationDestination(isPresented: Binding(get: { selectedCert != nil }, set: { if !$0 { selectedCert = nil } })) {
                if let cert = selectedCert { CertificateDetailView(certificate: cert, onDeleted: { viewModel.refresh() }) }
            }
        }
    }

    // Branches extracted so the type checker does not have to infer the
    // whole body as one expression (it timed out on the combined form).

    /// The account's development certificates from Apple (Phase 2).
    /// Shown only when signed in; creating one here is what the
    /// real refresh does automatically on first refresh.
    private var devCertificatesSection: some View {
        Section {
            if !viewModel.isSignedIn {
                Text(NSLocalizedString("certs.dev.signin", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.devCertificatesLoading {
                ProgressView()
            } else {
                // No single field is a stable unique key: certificateID
                // and serialNumber are both optional on the account
                // model, so the list position is the unique id.
                ForEach(Array(viewModel.devCertificates.enumerated()), id: \.offset) { _, cert in
                    HStack {
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(cert.name ?? NSLocalizedString("certs.dev.unnamed", comment: ""))
                                .font(.subheadline)
                            if let machine = cert.machineName {
                                Text(machine).font(.caption).foregroundStyle(.secondary)
                            }
                            if let serial = cert.serialNumber {
                                Text(serial).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let expiry = cert.expirationDate {
                                Text(expiry, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(NSLocalizedString("common.revoke", comment: ""), role: .destructive) {
                            certToRevoke = cert
                        }
                        .dsSecondaryButton()
                        .accessibilityIdentifier("certs.dev.revoke")
                    }
                }
                Button(NSLocalizedString("certs.dev.create", comment: "")) {
                    Task { await viewModel.createDevCertificate() }
                }
                .dsPrimaryButton()
                .disabled(viewModel.isCreatingDevCertificate)
                .accessibilityIdentifier("certs.dev.create")
                if viewModel.isCreatingDevCertificate {
                    ProgressView(NSLocalizedString("certs.dev.creating", comment: ""))
                }
            }
        } header: {
            Text(NSLocalizedString("certs.dev.title", comment: "")).dsSectionHeader()
        }
    }

    /// The locally stored certificates, as rows in the same List
    /// as the dev section (never a nested List).
    private var localCertificatesSection: some View {
        Section {
            if viewModel.certificates.isEmpty {
                Text(NSLocalizedString("certs.empty", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.certificates) { cert in
                    Button { selectedCert = cert } label: {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: cert.kind == "P12" ? "key.fill" : "doc.badge.gearshape")
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(cert.name).lineLimit(1)
                                Text(cert.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("certs.row.\(cert.name)")
                    .swipeActions {
                        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { certToDelete = cert }
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("certs.local.title", comment: "")).dsSectionHeader()
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            NSLocalizedString("certs.empty", comment: ""),
            systemImage: "key.fill",
            description: Text(NSLocalizedString("certs.empty.detail", comment: ""))
        ) {
            Button(NSLocalizedString("certs.import.p12", comment: "")) { viewModel.showP12Importer = true }
                .dsPrimaryButton()
                .accessibilityIdentifier("certs.import.empty")
        }
    }

    /// Signed in, live list loaded, and nothing stored anywhere yet:
    /// the same empty state, with Import as the next step and creating
    /// an on-device certificate as the alternative.
    private var signedInEmptyState: some View {
        EmptyStateView(
            NSLocalizedString("certs.empty", comment: ""),
            systemImage: "key.fill",
            description: Text(NSLocalizedString("certs.empty.detail", comment: ""))
        ) {
            Button(NSLocalizedString("certs.import.p12", comment: "")) { viewModel.showP12Importer = true }
                .dsPrimaryButton()
                .accessibilityIdentifier("certs.import.empty")
            Button(NSLocalizedString("certs.dev.create", comment: "")) {
                Task { await viewModel.createDevCertificate() }
            }
            .dsSecondaryButton()
            .disabled(viewModel.isCreatingDevCertificate)
            .accessibilityIdentifier("certs.dev.create.empty")
        }
    }

    private var passwordSheet: some View {
        NavigationStack {
            Form {
                SecureField(NSLocalizedString("cert.password", comment: ""), text: $viewModel.p12Password)
                    .accessibilityIdentifier("certs.passwordField")
                    .textContentType(.password)
                Text(NSLocalizedString("cert.password.note", comment: "")).font(.caption).foregroundStyle(.secondary)
                if let result = validationResult { Text(result).font(.caption) }
            }
            .navigationTitle(NSLocalizedString("certs.import.p12", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) {
                        viewModel.clearPasswordSheetState()
                        validationResult = nil
                        showPasswordSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("cert.validate", comment: "")) {
                        switch viewModel.validateP12() {
                        case .success(let message):
                            validationResult = message
                            if let url = viewModel.pendingP12URL { viewModel.importFile(url) }
                            // importFile consumed the password; no
                            // sheet state may survive into the next
                            // import.
                            viewModel.clearPasswordSheetState()
                            validationResult = nil
                            showPasswordSheet = false
                        case .failure(let error):
                            validationResult = error.localizedDescription
                        }
                    }
                    .accessibilityIdentifier("certs.validate")
                }
            }
        }
    }
}
