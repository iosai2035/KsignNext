import SwiftUI
import CryptoKit

struct CertificateInfo: Equatable {
    var subject = "", issuer = "", serial = "", fingerprint = "", status = "", expiry = ""
    var isExpired = false
    var compatibilityResult = ""
}

@MainActor
final class CertificateDetailViewModel: ObservableObject {
    @Published var info = CertificateInfo()
    /// Genuinely async loading flag: true only while `load()` awaits
    /// the engine / repository. The view shows a spinner until
    /// `hasLoaded` flips, so no half-filled rows ever flash.
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var isTestingCompatibility = false
    @Published var errorMessage: String?
    let certificate: StoredCertificate

    private let certificateEngine: CertificateEngineProtocol
    private let certificateRepository: CertificateRepository
    private let keychain: KeychainService

    /// The engine / repository / keychain are injectable for tests;
    /// by default the real engines are used (the repository is the
    /// shared Core Data one, so records saved by the import flow
    /// are visible here). The single-argument call used by the view
    /// and by `CertificateParsingTests` keeps working.
    init(
        certificate: StoredCertificate,
        certificateEngine: CertificateEngineProtocol? = nil,
        certificateRepository: CertificateRepository? = nil,
        keychain: KeychainService? = nil
    ) {
        self.certificate = certificate
        self.certificateEngine = certificateEngine ?? CertificateEngine()
        self.certificateRepository = certificateRepository ?? CoreDataCertificateRepository(persistence: .shared)
        self.keychain = keychain ?? .shared
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        info.subject = certificate.name
        if certificate.kind == "mobileprovision" {
            await loadProvision()
        } else {
            await loadP12()
        }
    }

    /// P12 details come from the parsed certificate: the repository
    /// record saved at import time (parsed by `CertificateEngine`,
    /// which reads issuer / serial / fingerprint from the DER
    /// bytes). A password-less P12 is parsed directly as a fallback;
    /// a password-protected P12 without a record cannot be parsed
    /// here — the password is never asked for on this screen — so
    /// its fields stay blank and the status says only "Stored".
    private func loadP12() async {
        if let record = await storedRecord() {
            applyRecord(record)
            return
        }
        if let parsed = try? await certificateEngine.parseP12(at: certificate.url, password: "") {
            applyRecord(parsed)
            return
        }
        info.status = NSLocalizedString("cert.status.stored", comment: "")
    }

    private func applyRecord(_ record: CertificateModel) {
        info.issuer = record.issuer ?? ""
        info.serial = record.serialNumber ?? ""
        info.fingerprint = record.fingerprint
        info.expiry = record.expirationDate.map(Self.formatDate) ?? ""
        info.isExpired = record.isExpired
        info.status = record.isExpired
            ? NSLocalizedString("cert.status.expired", comment: "")
            : record.status == .valid
                ? NSLocalizedString("cert.status.valid", comment: "")
                : NSLocalizedString("cert.status.stored", comment: "")
    }

    /// Parses a .mobileprovision through the real engine path.
    /// A profile is a CMS (PKCS#7) envelope wrapping an XML plist,
    /// so raw `PropertyListSerialization` on the file bytes can never
    /// read it. `ProvisioningEngine` (reached here via
    /// `CertificateEngine.parseProvisioningProfile`) already strips
    /// that envelope — it extracts the embedded `<?xml … </plist>`
    /// document and decodes it — so this reuses that one
    /// implementation instead of adding a second parser. (The
    /// Security framework's `CMSDecoder` is macOS-only and is not
    /// in the iOS SDK, so it cannot be the parser here.)
    private func loadProvision() async {
        do {
            let profile = try await certificateEngine.parseProvisioningProfile(at: certificate.url)
            info.status = profile.name
            info.expiry = profile.expirationDate.map(Self.formatDate) ?? ""
            info.isExpired = profile.isExpired
            info.issuer = profile.teamName ?? profile.teamIdentifier
            info.serial = profile.uuid
            // Fingerprint of the first embedded developer certificate
            // (SHA-256 of its DER bytes) — the same value
            // `validatePair` compares against a certificate.
            if let base64 = profile.certificates.first,
               let der = Data(base64Encoded: base64) {
                info.fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            }
        } catch {
            info.status = NSLocalizedString("cert.error.read", comment: "")
            errorMessage = error.localizedDescription
        }
    }

    /// Real compatibility check: parse the item, check expiry, and
    /// for a profile also check that a stored certificate matches
    /// its team and is listed in it. The result now depends on the
    /// actual data instead of the file extension.
    func testCompatibility() async {
        isTestingCompatibility = true
        defer { isTestingCompatibility = false }
        if certificate.kind == "mobileprovision" {
            await testProvisionCompatibility()
        } else {
            await testP12Compatibility()
        }
    }

    private func testP12Compatibility() async {
        let record: CertificateModel?
        if let stored = await storedRecord() {
            record = stored
        } else {
            record = try? await certificateEngine.parseP12(at: certificate.url, password: "")
        }
        guard let record else {
            info.compatibilityResult = NSLocalizedString("cert.compat.unverified", comment: "")
            return
        }
        if record.isExpired {
            info.compatibilityResult = NSLocalizedString("cert.compat.expired", comment: "")
            return
        }
        info.compatibilityResult = NSLocalizedString("cert.compat.p12", comment: "")
    }

    private func testProvisionCompatibility() async {
        let profile: ProvisioningModel
        do {
            profile = try await certificateEngine.parseProvisioningProfile(at: certificate.url)
        } catch {
            info.compatibilityResult = error.localizedDescription
            return
        }
        if profile.isExpired {
            info.compatibilityResult = NSLocalizedString("cert.compat.expired", comment: "")
            return
        }
        let records = (try? await certificateRepository.fetchAll()) ?? []
        if records.isEmpty {
            info.compatibilityResult = NSLocalizedString("cert.compat.noCert", comment: "")
            return
        }
        let profileFingerprints = Set(profile.certificates.compactMap { base64 -> String? in
            guard let der = Data(base64Encoded: base64) else { return nil }
            return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        })
        let matches = records.contains { record in
            record.teamIdentifier == profile.teamIdentifier
                && (profileFingerprints.isEmpty || profileFingerprints.contains(record.fingerprint.lowercased()))
        }
        info.compatibilityResult = matches
            ? NSLocalizedString("cert.compat.provision", comment: "")
            : NSLocalizedString("cert.compat.mismatch", comment: "")
    }

    /// Deletes the file AND the repository record with its Keychain
    /// password, so a stale record can never make signing pick a
    /// missing identity.
    func delete() async {
        try? FileManager.default.removeItem(at: certificate.url)
        if let match = await storedRecord() {
            try? await certificateRepository.delete(id: match.id)
            if let account = match.keychainAccount {
                try? keychain.delete(account: account)
            }
        }
    }

    /// The repository record for this file, if it was registered at
    /// import time (the engine stores its model under the stored
    /// file URL).
    private func storedRecord() async -> CertificateModel? {
        let records = (try? await certificateRepository.fetchAll()) ?? []
        return records.first { $0.fileURL == certificate.url }
    }

    private static func formatDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}

struct CertificateDetailView: View {
    let certificate: StoredCertificate
    var onDeleted: () -> Void
    @StateObject private var viewModel: CertificateDetailViewModel
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(certificate: StoredCertificate, onDeleted: @escaping () -> Void) {
        self.certificate = certificate
        self.onDeleted = onDeleted
        _viewModel = StateObject(wrappedValue: CertificateDetailViewModel(certificate: certificate))
    }

    var body: some View {
        Group {
            if !viewModel.hasLoaded {
                ProgressView(NSLocalizedString("common.loading", comment: ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        row(NSLocalizedString("cert.detail.subject", comment: ""), viewModel.info.subject)
                        row(NSLocalizedString("cert.detail.issuer", comment: ""), viewModel.info.issuer.isEmpty ? "—" : viewModel.info.issuer)
                        row(NSLocalizedString("cert.detail.serial", comment: ""), viewModel.info.serial.isEmpty ? "—" : viewModel.info.serial)
                        row(NSLocalizedString("cert.detail.fingerprint", comment: ""), viewModel.info.fingerprint.isEmpty ? "—" : viewModel.info.fingerprint)
                        row(NSLocalizedString("cert.detail.expiry", comment: ""), viewModel.info.expiry.isEmpty ? "—" : viewModel.info.expiry)
                        HStack {
                            Text(NSLocalizedString("cert.detail.status", comment: ""))
                            Spacer()
                            Text(viewModel.info.status)
                                .foregroundStyle(viewModel.info.isExpired ? .red : .green)
                        }
                    } header: {
                        Text(NSLocalizedString("cert.detail.title", comment: "")).dsSectionHeader()
                    }
                    Section {
                        Button(NSLocalizedString("cert.compat.run", comment: "")) {
                            Task { await viewModel.testCompatibility() }
                        }
                        .dsPrimaryButton()
                        .disabled(viewModel.isTestingCompatibility)
                        .accessibilityIdentifier("certDetail.compatibility")
                        if viewModel.isTestingCompatibility {
                            ProgressView(NSLocalizedString("common.loading", comment: ""))
                        }
                        if !viewModel.info.compatibilityResult.isEmpty {
                            Text(viewModel.info.compatibilityResult).font(.caption)
                        }
                    } header: {
                        Text(NSLocalizedString("cert.compat.title", comment: "")).dsSectionHeader()
                    }
                    Section {
                        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { showDeleteConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .accessibilityIdentifier("certDetail.delete")
                    }
                }
            }
        }
        .navigationTitle(certificate.name)
        .dsInlineTitle()
        .onAppear { Task { await viewModel.load() } }
        .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                Task { await viewModel.delete(); onDeleted(); dismiss() }
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.md) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(2) }
    }
}
