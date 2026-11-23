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

    init(app: StoredApp) { self.app = app }

    /// Inspects the IPA zip in-memory (small header reads only) for Info.plist presence.
    func inspect() {
        isLoading = true
        defer { isLoading = false }
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

    func signAction() -> SigningUnavailableReason { .backendNotLinked }
    func delete() {
        try? FileManager.default.removeItem(at: app.url)
    }
}

enum SigningUnavailableReason: LocalizedError {
    case backendNotLinked
    var errorDescription: String? { NSLocalizedString("signing.error.backend", comment: "") }
}

struct ApplicationDetailView: View {
    let app: StoredApp
    var onDeleted: () -> Void
    @StateObject private var viewModel: ApplicationDetailViewModel
    @State private var showDeleteConfirm = false
    @State private var showSignError = false
    @Environment(\.dismiss) private var dismiss

    init(app: StoredApp, onDeleted: @escaping () -> Void) {
        self.app = app
        self.onDeleted = onDeleted
        _viewModel = StateObject(wrappedValue: ApplicationDetailViewModel(app: app))
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
                Button(NSLocalizedString("apps.action.sign", comment: "")) { showSignError = true }
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
        .onAppear { viewModel.inspect() }
        .alert(NSLocalizedString("signing.error.title", comment: ""), isPresented: $showSignError) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        } message: { Text(SigningUnavailableReason.backendNotLinked.localizedDescription) }
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
