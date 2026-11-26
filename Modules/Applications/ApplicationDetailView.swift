import SwiftUI

struct AppInspection: Equatable {
    var bundleID = "", displayName = "", version = "", minimumOS = "", executable = ""
    var architectures: [String] = []
    var hasEntitlements = false
}

@MainActor
final class ApplicationDetailViewModel: ObservableObject {
    @Published var inspection = AppInspection()
    /// True once `inspect()` has finished (success or fallback), so the
    /// view shows inspection rows only with real values instead of
    /// flashing "Unknown" placeholders while the read is in flight.
    @Published var didInspect = false
    @Published var errorMessage: String?
    let app: StoredApp
    private let container: DependencyContainer?

    /// - Parameter container: the app's container; nil keeps the
    ///   ZIP-header fallback only (tests / previews).
    init(app: StoredApp, container: DependencyContainer? = nil) {
        self.app = app
        self.container = container
    }

    /// Reads the real metadata from the IPA's Info.plist through the
    /// IPA engine (bundle id, display name, version, minimum OS,
    /// executable, architectures). When no container is available —
    /// or the file is not a readable IPA — falls back to the ZIP
    /// header check and the file name, with the version labelled
    /// unknown, exactly as before.
    func inspect() async {
        defer { didInspect = true }
        if let container {
            do {
                let metadata = try await container.ipaEngine.readAppMetadata(at: app.url)
                inspection = AppInspection(
                    bundleID: metadata.bundleIdentifier,
                    displayName: metadata.bundleDisplayName ?? metadata.name,
                    version: metadata.version,
                    minimumOS: metadata.minimumOSVersion ?? "",
                    executable: metadata.executableName ?? "",
                    architectures: metadata.architectures,
                    hasEntitlements: false
                )
                return
            } catch {
                // Fall through to the header check below.
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: app.url) else {
            errorMessage = NSLocalizedString("error.file.read", comment: ""); return
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header == Data([0x50, 0x4B, 0x03, 0x04]) else {
            errorMessage = NSLocalizedString("apps.error.notzip", comment: ""); return
        }
        inspection.displayName = app.name
        inspection.version = NSLocalizedString("apps.version.unknown", comment: "")
    }

    /// Removes the file and its repository record. Returns false (and
    /// sets `errorMessage`) when anything fails, so the caller never
    /// dismisses the screen over a delete that did not happen. The
    /// record match is by file URL first, then by name, because the
    /// engine's stored copy uses a UUID file name; signed apps match
    /// by `signedFileURL`.
    func delete() async -> Bool {
        do {
            try FileManager.default.removeItem(at: app.url)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard let container else { return true }
        do {
            let imported = try await container.importedApplicationRepository.fetchAll()
            for record in imported where record.fileURL == app.url || record.name == app.name {
                if record.fileURL != app.url {
                    try? FileManager.default.removeItem(at: record.fileURL)
                }
                try await container.importedApplicationRepository.delete(id: record.id)
            }
            let signed = try await container.signedApplicationRepository.fetchAll()
            for record in signed where record.signedFileURL == app.url {
                try await container.signedApplicationRepository.delete(id: record.id)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct ApplicationDetailView: View {
    let app: StoredApp
    let container: DependencyContainer?
    var onDeleted: () -> Void
    @StateObject private var viewModel: ApplicationDetailViewModel
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(app: StoredApp, container: DependencyContainer? = nil, onDeleted: @escaping () -> Void) {
        self.app = app
        self.container = container
        self.onDeleted = onDeleted
        _viewModel = StateObject(wrappedValue: ApplicationDetailViewModel(app: app, container: container))
    }

    var body: some View {
        List {
            Section {
                detailRow(NSLocalizedString("apps.detail.name", comment: ""), app.name)
                detailRow(NSLocalizedString("apps.detail.size", comment: ""), Workspace.fileSizeString(app.size))
                detailRow(NSLocalizedString("apps.detail.path", comment: ""), app.url.lastPathComponent)
                if viewModel.didInspect {
                    detailRow(NSLocalizedString("apps.detail.displayname", comment: ""), viewModel.inspection.displayName.isEmpty ? app.name : viewModel.inspection.displayName)
                    detailRow(NSLocalizedString("apps.detail.bundleid", comment: ""), viewModel.inspection.bundleID.isEmpty ? NSLocalizedString("apps.version.unknown", comment: "") : viewModel.inspection.bundleID)
                    detailRow(NSLocalizedString("apps.detail.version", comment: ""), viewModel.inspection.version)
                    detailRow(NSLocalizedString("apps.detail.minimumos", comment: ""), viewModel.inspection.minimumOS.isEmpty ? NSLocalizedString("apps.version.unknown", comment: "") : viewModel.inspection.minimumOS)
                    detailRow(NSLocalizedString("apps.detail.executable", comment: ""), viewModel.inspection.executable.isEmpty ? NSLocalizedString("apps.version.unknown", comment: "") : viewModel.inspection.executable)
                    detailRow(NSLocalizedString("apps.detail.architectures", comment: ""), viewModel.inspection.architectures.isEmpty ? NSLocalizedString("apps.version.unknown", comment: "") : viewModel.inspection.architectures.joined(separator: ", "))
                    // The metadata read never reports entitlements, so an
                    // unpopulated field is shown as unknown, never as a
                    // false "no entitlements".
                    detailRow(NSLocalizedString("apps.detail.entitlements", comment: ""), viewModel.inspection.hasEntitlements ? NSLocalizedString("common.yes", comment: "") : NSLocalizedString("apps.version.unknown", comment: ""))
                } else {
                    ProgressView(NSLocalizedString("common.loading", comment: ""))
                }
            } header: {
                Text(NSLocalizedString("apps.detail.info", comment: "")).dsSectionHeader()
            }
            Section {
                NavigationLink(NSLocalizedString("apps.action.sign", comment: "")) {
                    SigningCenterView(container: container, preselectedAppName: app.url.lastPathComponent)
                }
                .accessibilityIdentifier("appDetail.sign")
                ShareLink(item: app.url, preview: SharePreview(app.name)) {
                    Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("appDetail.export")
                NavigationLink(NSLocalizedString("macho.title", comment: "")) { MachOInspectorView(fileURL: app.url) }
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { showDeleteConfirm = true }
                    .accessibilityIdentifier("appDetail.delete")
            } header: {
                Text(NSLocalizedString("apps.detail.actions", comment: "")).dsSectionHeader()
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(app.name)
        .dsInlineTitle()
        .task { await viewModel.inspect() }
        .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                Task {
                    if await viewModel.delete() { onDeleted(); dismiss() }
                }
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.md) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1).truncationMode(.middle) }
    }
}
