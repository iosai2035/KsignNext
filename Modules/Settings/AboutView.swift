import SwiftUI

/// About view (contract §C.5): app name, version, build, bundle ID
/// — all live metadata — plus "Copy diagnostics summary"
/// (version/build/counts/free space). Nothing else: no deferred
/// sections, no design-system specs.
struct AboutView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var certificateCount: Int?
    @State private var profileCount: Int?
    @State private var freeSpaceBytes: Int64?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                row(Loc.string("about.name"), appName)
                row(Loc.string("about.version"), versionText)
                row(Loc.string("about.bundleid"), bundleID)
                row(Loc.string("about.platform"), platformText)
                Text(Loc.string("about.description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Loc.string("about.section.info")).dsSectionHeader()
            }
            Section {
                row(Loc.string("dashboard.count.certs"), countText(certificateCount))
                row(Loc.string("dashboard.count.profiles"), countText(profileCount))
                row(Loc.string("settings.storage.free"), freeSpaceText)
                Button(Loc.string("settings.about.copy")) {
                    copySummary()
                }
                .dsPrimaryButton()
                .accessibilityLabel(Loc.string("settings.about.copy"))
                if copied {
                    Text(Loc.string("settings.about.copied"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Loc.string("settings.about.copied"))
                }
            } header: {
                Text(Loc.string("settings.diagnostics.title")).dsSectionHeader()
            }
        }
        .navigationTitle(Loc.string("settings.about.title"))
        .dsInlineTitle()
        .task { await loadCounts() }
    }

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? Loc.string("about.name")
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Loc.string("common.unknown")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? Loc.string("common.unknown")
        return Loc.string("about.version", version, build)
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? Loc.string("common.unknown")
    }

    private var platformText: String {
        #if os(iOS)
        return "iOS"
        #else
        return Loc.string("common.unknown")
        #endif
    }

    private func countText(_ count: Int?) -> String {
        guard let count else { return Loc.string("common.unknown") }
        return "\(count)"
    }

    private var freeSpaceText: String {
        guard let freeSpaceBytes else { return Loc.string("common.unknown") }
        return ByteCountFormatter.string(fromByteCount: freeSpaceBytes, countStyle: .file)
    }

    private func loadCounts() async {
        do {
            let certificateRepository = try coordinator.container.resolveCertificateRepository()
            certificateCount = try await certificateRepository.fetchAll().count
            let profileRepository = try coordinator.container.resolveProvisioningProfileRepository()
            profileCount = try await profileRepository.fetchAll().count
        } catch {
            certificateCount = nil
            profileCount = nil
        }
        freeSpaceBytes = FileSystemManager.shared.freeSpaceBytes()
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

    private func copySummary() {
        let summary = """
        \(appName) \(versionText)
        \(Loc.string("about.bundleid")): \(bundleID)
        \(Loc.string("dashboard.count.certs")): \(countText(certificateCount))
        \(Loc.string("dashboard.count.profiles")): \(countText(profileCount))
        \(Loc.string("settings.storage.free")): \(freeSpaceText)
        """
        UIPasteboard.general.string = summary
        copied = true
    }
}
