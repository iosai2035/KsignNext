import SwiftUI
import UniformTypeIdentifiers

/// Dashboard tab (contract §C.2): expiry overview + banners + recent
/// activity + counts. Tapping a banner opens the Certificates
/// manager; tapping an expiry row opens that profile's detail;
/// tapping an activity row opens Diagnostics.
struct DashboardView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var viewModel: DashboardViewModel
    @State private var showImporter = false

    init(container: DependencyContainer) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(container: container))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.sectionSpacing) {
                bannersSection
                expiryCard
                countsSection
                activitySection
            }
            .padding()
        }
        .navigationTitle(Loc.string("dashboard.title"))
        .dsLargeTitle()
        .dsSideMenuButton()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("common.refresh"))
            }
        }
        .task { await viewModel.refresh() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [Self.p12Type, Self.provisionType]
        ) { result in
            switch result {
            case .success(let url):
                Task { await importPickedFile(url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
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

    /// Routes a file picked from the Dashboard's Import button: a
    /// .p12 opens the password sheet, a profile imports at once.
    private func importPickedFile(_ url: URL) async {
        switch url.pathExtension.lowercased() {
        case "p12":
            coordinator.pendingP12ImportURL = url
            coordinator.presentedSheet = .p12PasswordPrompt(url)
        case "mobileprovision":
            let ok = await coordinator.certificatesViewModel.importProfile(url: url)
            if ok {
                await viewModel.refresh()
            } else if let message = coordinator.certificatesViewModel.errorMessage {
                viewModel.errorMessage = message
            }
        default:
            break
        }
    }

    // MARK: - Banners (§B.11, persistent while the condition holds)

    @ViewBuilder
    private var bannersSection: some View {
        ForEach(viewModel.banners) { profile in
            let days = profile.daysUntilExpiration ?? 0
            Button {
                coordinator.openCertificatesManager()
            } label: {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: days < 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    Text(bannerText(for: profile, days: days))
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundStyle(days <= 0 ? .red : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dsCard()
            .accessibilityLabel(bannerText(for: profile, days: days))
            .accessibilityHint(Loc.string("certs.open.hint"))
        }
    }

    private func bannerText(for profile: ProvisioningModel, days: Int) -> String {
        if days < 0 { return Loc.string("banner.expiry.expired", profile.name) }
        if days == 0 { return Loc.string("banner.expiry.today", profile.name) }
        return Loc.string("banner.expiry.soon", profile.name, days)
    }

    // MARK: - Expiry card

    private var expiryCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(Loc.string("dashboard.expiry.title"))
                .dsSectionHeader()
                .accessibilityLabel(Loc.string("dashboard.expiry.title"))
            if viewModel.expiringProfiles.isEmpty {
                Text(Loc.string("dashboard.expiry.empty"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("dashboard.expiry.empty"))
                Button(Loc.string("certs.import")) {
                    showImporter = true
                }
                .dsPrimaryButton()
                .accessibilityLabel(Loc.string("certs.import"))
            } else {
                ForEach(viewModel.expiringProfiles) { profile in
                    NavigationLink(value: AppRoute.profileDetail(profile.id)) {
                        HStack(spacing: DS.Spacing.md) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(profile.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(String(profile.uuid.prefix(8))) · \(profile.teamIdentifier)")
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
                }
            }
        }
        .dsCard()
    }

    // MARK: - Counts

    private var countsSection: some View {
        HStack(spacing: DS.Spacing.md) {
            Button {
                coordinator.openCertificatesManager()
            } label: {
                countCard(
                    title: Loc.string("dashboard.count.certs"),
                    value: "\(viewModel.certificateCount)"
                )
            }
            .accessibilityLabel("\(Loc.string("dashboard.count.certs")): \(viewModel.certificateCount)")
            Button {
                coordinator.openCertificatesManager()
            } label: {
                countCard(
                    title: Loc.string("dashboard.count.profiles"),
                    value: "\(viewModel.profileCount)"
                )
            }
            .accessibilityLabel("\(Loc.string("dashboard.count.profiles")): \(viewModel.profileCount)")
            Button {
                coordinator.path.append(AppRoute.storage)
            } label: {
                countCard(
                    title: Loc.string("dashboard.count.freeSpace"),
                    value: freeSpaceText
                )
            }
            .accessibilityLabel("\(Loc.string("dashboard.count.freeSpace")): \(freeSpaceText)")
        }
    }

    private func countCard(title: String, value: String) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    private var freeSpaceText: String {
        guard let bytes = viewModel.freeSpaceBytes else { return Loc.string("common.unknown") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Recent activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(Loc.string("dashboard.recent"))
                .dsSectionHeader()
                .accessibilityLabel(Loc.string("dashboard.recent"))
            if let activityError = viewModel.activityError {
                Text(activityError)
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .accessibilityLabel(activityError)
            } else if viewModel.recentActivity.isEmpty {
                Text(Loc.string("dashboard.recent.empty"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.string("dashboard.recent.empty"))
                Text(Loc.string("dashboard.recent.empty.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentActivity) { entry in
                    Button {
                        coordinator.presentedSheet = .diagnostics
                    } label: {
                        HStack(spacing: DS.Spacing.md) {
                            levelDot(entry.level)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(entry.message)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("\(levelText(entry.level)): \(entry.message)")
                }
            }
        }
        .dsCard()
    }

    private func levelDot(_ level: LogLevel) -> some View {
        Circle()
            .fill(levelColor(level))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }

    private func levelText(_ level: LogLevel) -> String {
        switch level {
        case .debug: return Loc.string("logs.level.debug")
        case .info: return Loc.string("logs.level.info")
        case .warning: return Loc.string("logs.level.warning")
        case .error: return Loc.string("logs.level.error")
        case .critical: return Loc.string("logs.level.critical")
        }
    }
}
