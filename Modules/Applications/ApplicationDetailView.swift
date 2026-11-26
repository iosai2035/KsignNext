import SwiftUI

struct AppInspection: Equatable {
    var bundleID = "", displayName = "", version = "", minimumOS = "", executable = ""
    var architectures: [String] = []
    var hasEntitlements = false
}

@MainActor
final class ApplicationDetailViewModel: ObservableObject {
    @Published var inspection = AppInspection()
    @Published var isLoading = false
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
        isLoading = true
        defer { isLoading = false }
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

    func delete() {
        try? FileManager.default.removeItem(at: app.url)
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
            Section(NSLocalizedString("apps.detail.info", comment: "")) {
                detailRow(NSLocalizedString("apps.detail.name", comment: ""), app.name)
                detailRow(NSLocalizedString("apps.detail.size", comment: ""), Workspace.fileSizeString(app.size))
                detailRow(NSLocalizedString("apps.detail.path", comment: ""), app.url.lastPathComponent)
                detailRow(NSLocalizedString("apps.detail.bundleid", comment: ""), viewModel.inspection.bundleID.isEmpty ? NSLocalizedString("apps.version.unknown", comment: "") : viewModel.inspection.bundleID)
                detailRow(NSLocalizedString("apps.detail.version", comment: ""), viewModel.inspection.version)
            }
            Section(NSLocalizedString("apps.detail.actions", comment: "")) {
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
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.inspect() }
        .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                viewModel.delete(); onDeleted(); dismiss()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1).truncationMode(.middle) }
    }
}
