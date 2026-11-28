import SwiftUI
import UniformTypeIdentifiers

/// Certificates manager (contract §C.3), presented as a full-screen
/// cover from the side menu. Two sections — Identities (.p12) and
/// Profiles (.mobileprovision). Import via the `+` menu (document
/// picker); a P12 opens the password sheet, a profile imports at
/// once. Tap a row for its detail; swipe to delete. Delete dismisses
/// only when every step succeeds (W-6).
struct CertificatesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject private var viewModel: CertificatesViewModel
    @State private var certificateToDelete: CertificateModel?
    @State private var profileToDelete: ProvisioningModel?

    init(viewModel: CertificatesViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        List {
            identitiesSection
            profilesSection
        }
        .navigationTitle(Loc.string("tab.certificates"))
        .dsInlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(Loc.string("common.close")) {
                    coordinator.showCertificatesManager = false
                }
                .accessibilityLabel(Loc.string("common.close"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu(Loc.string("certs.import")) {
                    Button(Loc.string("certs.import.p12")) { viewModel.showP12Importer = true }
                        .accessibilityIdentifier("certs.import.p12")
                    Button(Loc.string("certs.import.provision")) { viewModel.showProvisionImporter = true }
                        .accessibilityIdentifier("certs.import.provision")
                }
                .accessibilityLabel(Loc.string("certs.import"))
            }
        }
        .fileImporter(
            isPresented: $viewModel.showP12Importer,
            allowedContentTypes: [Self.p12Type]
        ) { result in
            switch result {
            case .success(let url):
                viewModel.pendingP12URL = url
                coordinator.pendingP12ImportURL = url
                coordinator.presentedSheet = .p12PasswordPrompt(url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $viewModel.showProvisionImporter,
            allowedContentTypes: [Self.provisionType]
        ) { result in
            switch result {
            case .success(let url):
                Task { _ = await viewModel.importProfile(url: url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .task { await viewModel.refresh() }
        .task(id: coordinator.certificatesChangedToken) { await viewModel.refresh() }
        .alert(Loc.string("common.delete.confirm"), isPresented: Binding(
            get: { certificateToDelete != nil || profileToDelete != nil },
            set: { if !$0 { certificateToDelete = nil; profileToDelete = nil } }
        )) {
            Button(Loc.string("common.delete"), role: .destructive) {
                Task { await confirmDelete() }
            }
            Button(Loc.string("common.cancel"), role: .cancel) {
                certificateToDelete = nil
                profileToDelete = nil
            }
        }
        .alert(Loc.string("alert.error.title"), isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(Loc.string("common.ok"), role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private static var p12Type: UTType { UTType(filenameExtension: "p12") ?? .data }
    private static var provisionType: UTType { UTType(filenameExtension: "mobileprovision") ?? .data }

    private func confirmDelete() async {
        if let certificate = certificateToDelete {
            _ = await viewModel.deleteCertificate(id: certificate.id)
            certificateToDelete = nil
        } else if let profile = profileToDelete {
            _ = await viewModel.deleteProfile(id: profile.id)
            profileToDelete = nil
        }
    }

    // MARK: - Sections

    private var identitiesSection: some View {
        Section {
            if viewModel.certificates.isEmpty {
                Text(Loc.string("certs.empty"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("certs.empty"))
            } else {
                ForEach(viewModel.certificates) { certificate in
                    NavigationLink(value: AppRoute.certificateDetail(certificate.id)) {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(DS.ColorPalette.accentBrand)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(certificate.name)
                                    .lineLimit(1)
                                Text(certificate.teamIdentifier ?? Loc.string("cert.kind.unknown"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            ExpiryPill(daysUntilExpiration: certificate.daysUntilExpiration)
                            statusPill(certificate.status)
                        }
                        .frame(minHeight: DS.Accessibility.minTouchTarget)
                    }
                    .accessibilityLabel("\(certificate.name), \(statusText(certificate.status)), \(DS.expiryText(days: certificate.daysUntilExpiration))")
                    .swipeActions {
                        Button(Loc.string("common.delete"), role: .destructive) {
                            certificateToDelete = certificate
                        }
                        .accessibilityLabel(Loc.string("common.delete"))
                    }
                }
            }
        } header: {
            Text(Loc.string("certs.section.identities")).dsSectionHeader()
        }
    }

    private var profilesSection: some View {
        Section {
            if viewModel.profiles.isEmpty {
                Text(Loc.string("dashboard.expiry.empty"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("dashboard.expiry.empty"))
            } else {
                ForEach(viewModel.profiles) { profile in
                    NavigationLink(value: AppRoute.profileDetail(profile.id)) {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: "doc.badge.gearshape")
                                .foregroundStyle(DS.ColorPalette.accentBrand)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(profile.name)
                                    .lineLimit(1)
                                Text(profile.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(coverageText(for: profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            ExpiryPill(daysUntilExpiration: profile.daysUntilExpiration)
                        }
                        .frame(minHeight: DS.Accessibility.minTouchTarget)
                    }
                    .accessibilityLabel("\(profile.name), \(DS.expiryText(days: profile.daysUntilExpiration))")
                    .swipeActions {
                        Button(Loc.string("common.delete"), role: .destructive) {
                            profileToDelete = profile
                        }
                        .accessibilityLabel(Loc.string("common.delete"))
                    }
                }
            }
        } header: {
            Text(Loc.string("certs.section.profiles")).dsSectionHeader()
        }
    }

    /// UDID coverage state without a pasted UDID: the row shows the
    /// prompt, not a verdict.
    private func coverageText(for profile: ProvisioningModel) -> String {
        if profile.kind == .appStore { return Loc.string("certs.coverage.noList") }
        return Loc.string("certs.coverage.prompt")
    }

    private func statusPill(_ status: CertificateStatus) -> some View {
        Text(statusText(status))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .background(statusColor(status).opacity(0.15), in: Capsule())
            .accessibilityLabel(statusText(status))
    }

    private func statusColor(_ status: CertificateStatus) -> Color {
        switch status {
        case .valid: return .green
        case .expired, .revoked, .invalid, .mismatched: return .red
        case .unknown: return .gray
        }
    }

    private func statusText(_ status: CertificateStatus) -> String {
        switch status {
        case .valid: return Loc.string("cert.status.valid")
        case .expired: return Loc.string("cert.status.expired")
        case .revoked: return Loc.string("cert.status.revoked")
        case .invalid: return Loc.string("cert.status.invalid")
        case .mismatched: return Loc.string("cert.status.mismatched")
        case .unknown: return Loc.string("cert.status.unknown")
        }
    }
}

/// P12 password sheet (contract §C.3). The password lives in this
/// sheet's `@State` only — never in the view model, never logged,
/// never written to disk. Empty password is allowed and means
/// password-less (it still registers, W-3). Validate runs
/// `parseP12` in-memory first; Import consumes the password, clears
/// it from memory, then runs the use case.
struct P12PasswordSheet: View {
    let url: URL
    @ObservedObject private var viewModel: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var validationMessage: String?
    @State private var isWorking = false

    init(url: URL, viewModel: CertificatesViewModel) {
        self.url = url
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            Form {
                SecureField(Loc.string("cert.password"), text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("certs.passwordField")
                    .accessibilityLabel(Loc.string("cert.password"))
                Text(Loc.string("cert.password.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .accessibilityLabel(validationMessage)
                }
                if isWorking {
                    ProgressView(Loc.string("common.loading"))
                }
            }
            .navigationTitle(Loc.string("certs.import.p12"))
            .dsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.string("common.cancel")) {
                        clearState()
                        dismiss()
                    }
                    .accessibilityLabel(Loc.string("common.cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.string("cert.validate")) {
                        Task { await validate() }
                    }
                    .disabled(isWorking)
                    .accessibilityLabel(Loc.string("cert.validate"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(Loc.string("common.import")) {
                        Task { await importP12() }
                    }
                    .disabled(isWorking)
                    .accessibilityLabel(Loc.string("common.import"))
                }
            }
        }
    }

    private func validate() async {
        isWorking = true
        defer { isWorking = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let engine = try viewModel.container.resolveCertificateEngine()
            _ = try await engine.parseP12(at: url, password: password)
            validationMessage = Loc.string("cert.valid")
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func importP12() async {
        isWorking = true
        defer { isWorking = false }
        // The password is consumed here and cleared immediately
        // after, whatever the outcome — it must not survive the
        // sheet in memory.
        let consumedPassword = password
        let ok = await viewModel.importP12(url: url, password: consumedPassword)
        password = ""
        if ok {
            clearState()
            dismiss()
        }
    }

    private func clearState() {
        password = ""
        validationMessage = nil
        viewModel.pendingP12URL = nil
    }
}
