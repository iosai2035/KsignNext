import SwiftUI

/// Side menu (contract §10.3a): a drawer from the leading edge on
/// iPhone, openable from any tab and owned by the `AppCoordinator`;
/// a persistent sidebar on iPad. Contents: the active signing
/// identity card, the Certificates manager entry, and import
/// shortcuts. Certificates live here — never in Settings (§C.5).
struct SideMenuView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject private var viewModel: CertificatesViewModel
    private let isDrawer: Bool

    init(viewModel: CertificatesViewModel, isDrawer: Bool = true) {
        self.viewModel = viewModel
        self.isDrawer = isDrawer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.sectionSpacing) {
                    identityCard
                    certificatesSection
                    importSection
                }
                .padding()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorPalette.cardBackground)
        .task { await viewModel.refresh() }
    }

    private var header: some View {
        HStack {
            Text(Loc.string("about.name"))
                .font(.headline)
                .accessibilityLabel(Loc.string("about.name"))
            Spacer()
            if isDrawer {
                Button {
                    coordinator.closeSideMenu()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("sidemenu.close"))
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }

    /// The active signing identity: the valid certificate with the
    /// nearest expiry (Phase 1 has no selection model, so the
    /// identity signing would use first is the one shown). Empty
    /// when nothing valid is stored — never a fake identity.
    private var activeIdentity: CertificateModel? {
        viewModel.certificates
            .filter { $0.status == .valid && !$0.isExpired }
            .sorted { lhs, rhs in
                switch (lhs.expirationDate, rhs.expirationDate) {
                case (let a?, let b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.importedAt > rhs.importedAt
                }
            }
            .first
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(Loc.string("sidemenu.identity.title"))
                .dsSectionHeader()
                .accessibilityLabel(Loc.string("sidemenu.identity.title"))
            if let identity = activeIdentity {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(DS.ColorPalette.accentBrand)
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(identity.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let team = identity.teamIdentifier {
                            Text(team)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ExpiryPill(daysUntilExpiration: identity.daysUntilExpiration)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(identity.name), \(DS.expiryText(days: identity.daysUntilExpiration))")
            } else {
                Text(Loc.string("sidemenu.identity.none"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("sidemenu.identity.none"))
                Button(Loc.string("sidemenu.identity.import")) {
                    importP12()
                }
                .dsPrimaryButton()
                .accessibilityLabel(Loc.string("sidemenu.identity.import"))
            }
        }
        .dsCard()
    }

    private var certificatesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Button {
                coordinator.openCertificatesManager()
            } label: {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(DS.ColorPalette.accentBrand)
                    Text(Loc.string("sidemenu.certificates"))
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.certificates.count + viewModel.profiles.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(viewModel.certificates.count + viewModel.profiles.count)")
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: DS.Accessibility.minTouchTarget)
            }
            .accessibilityLabel(Loc.string("sidemenu.certificates"))
            .accessibilityHint(Loc.string("certs.open.hint"))
        }
        .dsCard()
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Button(Loc.string("certs.import.p12")) { importP12() }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("certs.import.p12"))
            Button(Loc.string("certs.import.provision")) { importProvision() }
                .dsSecondaryButton()
                .accessibilityLabel(Loc.string("certs.import.provision"))
        }
    }

    /// Import shortcut: open the manager and arm its document
    /// picker. The picker lives in `CertificatesView`, bound to the
    /// shared view model flag, so it opens as soon as the manager
    /// appears.
    private func importP12() {
        viewModel.showP12Importer = true
        coordinator.openCertificatesManager()
    }

    private func importProvision() {
        viewModel.showProvisionImporter = true
        coordinator.openCertificatesManager()
    }
}
