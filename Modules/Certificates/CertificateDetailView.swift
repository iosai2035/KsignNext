import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

/// Certificate / profile detail (contract §C.3). One view, two
/// subjects: an identity (P12) or a provisioning profile. Shows the
/// stored fields, the expiry countdown with its band colour, and —
/// for profiles — the UDID coverage section and the re-import action.
/// Delete names the failed step on failure and dismisses only when
/// every step succeeds (W-6).
struct CertificateDetailView: View {
    enum Subject {
        case certificate(CertificateModel)
        case profile(ProvisioningModel)
    }

    private let subject: Subject
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showReimporter = false
    @State private var errorMessage: String?
    @State private var isDeleting = false

    init(certificate: CertificateModel) {
        self.subject = .certificate(certificate)
    }

    init(profile: ProvisioningModel) {
        self.subject = .profile(profile)
    }

    var body: some View {
        List {
            detailSection
            if case .profile(let profile) = subject {
                coverageSection(profile: profile)
                reimportSection
            }
            deleteSection
        }
        .navigationTitle(title)
        .dsInlineTitle()
        .fileImporter(
            isPresented: $showReimporter,
            allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                Task { await reimport(url: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert(Loc.string("common.delete.confirm"), isPresented: $showDeleteConfirm) {
            Button(Loc.string("common.delete"), role: .destructive) {
                Task { await delete() }
            }
            Button(Loc.string("common.cancel"), role: .cancel) {}
        }
        .alert(Loc.string("alert.error.title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(Loc.string("common.ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var title: String {
        switch subject {
        case .certificate(let certificate): return certificate.name
        case .profile(let profile): return profile.name
        }
    }

    // MARK: - Detail fields

    @ViewBuilder
    private var detailSection: some View {
        switch subject {
        case .certificate(let certificate):
            Section {
                row(Loc.string("cert.detail.subject"), certificate.commonName ?? certificate.name)
                row(Loc.string("cert.detail.issuer"), certificate.issuer ?? "—")
                row(Loc.string("cert.detail.serial"), certificate.serialNumber ?? "—")
                row(Loc.string("cert.detail.fingerprint"), certificate.fingerprint)
                row(Loc.string("certs.detail.team"), certificate.teamIdentifier ?? "—")
                row(Loc.string("certs.detail.kind"), kindText(certificate.kind))
                row(Loc.string("cert.detail.status"), statusText(certificate.status))
                expiryRow(days: certificate.daysUntilExpiration, date: certificate.expirationDate)
                row(Loc.string("certs.detail.filename"), certificate.p12FileName ?? "—")
                row(Loc.string("certs.detail.keychain"), certificate.isStoredInKeychain
                    ? Loc.string("certs.detail.keychain.stored")
                    : Loc.string("certs.detail.keychain.none"))
            } header: {
                Text(Loc.string("cert.detail.title")).dsSectionHeader()
            }
        case .profile(let profile):
            Section {
                row(Loc.string("certs.detail.uuid"), profile.uuid)
                row(Loc.string("certs.detail.team"), profile.teamIdentifier)
                row(Loc.string("certs.detail.teamname"), profile.teamName ?? "—")
                row(Loc.string("certs.detail.appid"), profile.appIdentifier)
                row(Loc.string("certs.detail.bundleid"), profile.bundleIdentifier)
                row(Loc.string("certs.detail.kind"), profileKindText(profile.kind))
                expiryRow(days: profile.daysUntilExpiration, date: profile.expirationDate)
                row(Loc.string("certs.detail.created"), profile.creationDate.map(Self.formatDate) ?? "—")
                row(Loc.string("certs.detail.datahash"), profile.dataHash)
                row(Loc.string("certs.detail.filename"), profile.fileURL?.lastPathComponent ?? "—")
            } header: {
                Text(Loc.string("cert.detail.title")).dsSectionHeader()
            }
            Section {
                ForEach(profile.entitlements.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    row(key, value)
                }
                if profile.entitlements.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                }
            } header: {
                Text(Loc.string("certs.detail.entitlements")).dsSectionHeader()
            }
            Section {
                row(Loc.string("certs.detail.devices"), "\(profile.provisionedDevices.count)")
                ForEach(profile.provisionedDevices, id: \.self) { device in
                    Text(device)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            } header: {
                Text(Loc.string("certs.detail.devices")).dsSectionHeader()
            }
            Section {
                ForEach(Self.embeddedFingerprints(profile), id: \.self) { fingerprint in
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                if profile.certificates.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                }
            } header: {
                Text(Loc.string("certs.detail.certificates")).dsSectionHeader()
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func expiryRow(days: Int?, date: Date?) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Text(Loc.string("cert.detail.expiry"))
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: DS.Spacing.xxs) {
                Text(date.map(Self.formatDate) ?? Loc.string("expiry.none"))
                ExpiryPill(daysUntilExpiration: days)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Loc.string("cert.detail.expiry")): \(DS.expiryText(days: days))")
    }

    // MARK: - Device coverage (profiles only, §C.3)

    private func coverageSection(profile: ProvisioningModel) -> some View {
        Section {
            CoverageSectionView(profile: profile)
        } header: {
            Text(Loc.string("certs.detail.coverage")).dsSectionHeader()
        }
    }

    private var reimportSection: some View {
        Section {
            Button(Loc.string("certs.detail.reimport")) {
                showReimporter = true
            }
            .dsPrimaryButton()
            .accessibilityLabel(Loc.string("certs.detail.reimport"))
        }
    }

    private var deleteSection: some View {
        Section {
            Button(Loc.string("common.delete"), role: .destructive) {
                showDeleteConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeleting)
            .accessibilityIdentifier("certDetail.delete")
            .accessibilityLabel(Loc.string("common.delete"))
            if isDeleting {
                ProgressView(Loc.string("common.loading"))
            }
        }
    }

    // MARK: - Actions

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        let ok: Bool
        switch subject {
        case .certificate(let certificate):
            ok = await coordinator.certificatesViewModel.deleteCertificate(id: certificate.id)
        case .profile(let profile):
            ok = await coordinator.certificatesViewModel.deleteProfile(id: profile.id)
        }
        if ok {
            dismiss()
        } else {
            errorMessage = coordinator.certificatesViewModel.errorMessage
        }
    }

    /// Re-import (§B.11): the new profile is validated immediately
    /// by the use case (CMS valid? already expired?); any failure
    /// stops the flow with the specific message. On success the
    /// detail dismisses back to the manager, which shows the new
    /// profile.
    private func reimport(url: URL) async {
        let ok = await coordinator.certificatesViewModel.importProfile(url: url)
        if ok {
            dismiss()
        } else {
            errorMessage = coordinator.certificatesViewModel.errorMessage
        }
    }

    // MARK: - Helpers

    private func kindText(_ kind: CertificateKind) -> String {
        switch kind {
        case .development, .developer: return Loc.string("cert.kind.development")
        case .distribution: return Loc.string("cert.kind.distribution")
        case .adhoc: return Loc.string("cert.kind.adhoc")
        case .unknown: return Loc.string("cert.kind.unknown")
        }
    }

    private func profileKindText(_ kind: ProvisioningKind) -> String {
        switch kind {
        case .development: return Loc.string("profile.kind.development")
        case .adhoc: return Loc.string("profile.kind.adhoc")
        case .appStore: return Loc.string("profile.kind.appStore")
        case .enterprise: return Loc.string("profile.kind.enterprise")
        case .unknown: return Loc.string("profile.kind.unknown")
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

    private static func formatDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    /// SHA-256 fingerprints of the profile's embedded developer
    /// certificates — the same values `validatePair` compares
    /// against a certificate's fingerprint.
    private static func embeddedFingerprints(_ profile: ProvisioningModel) -> [String] {
        profile.certificates.compactMap { base64 -> String? in
            guard let der = Data(base64Encoded: base64) else { return nil }
            return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Device coverage for one profile (§C.3): pasted-UDID field (40-hex
/// validation with the exact error message) + "Check coverage" →
/// covered / not covered for THIS profile (exact `contains`). App
/// Store profiles show "no device list" text, not a fake `true`. No
/// UDID pasted → the prompt, not an error.
private struct CoverageSectionView: View {
    let profile: ProvisioningModel
    @StateObject private var udidStore = DeviceUDIDStore()
    @State private var draftUDID = ""
    @State private var coverageResult: String?
    @State private var coverageError: String?

    var body: some View {
        if profile.kind == .appStore {
            Text(Loc.string("certs.coverage.noList"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Loc.string("certs.coverage.noList"))
        } else {
            TextField(Loc.string("udid.placeholder"), text: $draftUDID)
                .textContentType(.none)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
                .font(.caption.monospaced())
                .accessibilityLabel(Loc.string("udid.field"))
                .onAppear { draftUDID = udidStore.savedUDID ?? "" }
            Button(Loc.string("certs.coverage.check")) {
                checkCoverage()
            }
            .dsSecondaryButton()
            .accessibilityLabel(Loc.string("certs.coverage.check"))
            if let coverageResult {
                Text(coverageResult)
                    .font(.subheadline)
                    .accessibilityLabel(coverageResult)
            }
            if let coverageError {
                Text(coverageError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityLabel(coverageError)
            }
            if coverageResult == nil && coverageError == nil {
                Text(Loc.string("certs.coverage.prompt"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("certs.coverage.prompt"))
            }
        }
    }

    private func checkCoverage() {
        coverageResult = nil
        coverageError = nil
        do {
            try DeviceUDIDValidator.validate(draftUDID)
            guard let normalized = DeviceUDIDValidator.normalized(draftUDID) else {
                throw AppError.validation(.invalidDeviceUDID(draftUDID))
            }
            _ = try udidStore.save(draftUDID)
            let covered = profile.provisionedDevices.contains(normalized)
            coverageResult = covered
                ? Loc.string("certs.coverage.covered")
                : Loc.string("certs.coverage.notCovered")
        } catch {
            coverageError = error.localizedDescription
        }
    }
}
