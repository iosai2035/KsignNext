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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showP12Importer = false
    @Published var showProvisionImporter = false
    @Published var pendingP12URL: URL?
    @Published var p12Password = "" // Held in memory only; never logged, never written to disk.

    func refresh() {
        isLoading = true
        defer { isLoading = false }
        guard let dir = Workspace.folder("Certificates") else { return }
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
        guard let destDir = Workspace.folder("Certificates") else { return }
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ cert: StoredCertificate) {
        do {
            try FileManager.default.removeItem(at: cert.url)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Validates a P12 with the in-memory password via SecPKCS12Import. Password is never stored.
    func validateP12() -> Result<String, Error> {
        guard let url = pendingP12URL, let data = try? Data(contentsOf: url) else {
            return .failure(NSError(domain: "KsignNext", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cert.error.read", comment: "")]))
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: p12Password] as CFDictionary, &items)
        p12Password = ""
        if status != errSecSuccess {
            return .failure(NSError(domain: "KsignNext", code: Int(status), userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("cert.error.password", comment: "")]))
        }
        return .success(NSLocalizedString("cert.valid", comment: ""))
    }
}

struct CertificatesView: View {
    @StateObject private var viewModel = CertificatesViewModel()
    @State private var certToDelete: StoredCertificate?
    @State private var selectedCert: StoredCertificate?
    @State private var showPasswordSheet = false
    @State private var validationResult: String?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.certificates.isEmpty {
                    emptyState
                } else {
                    certificatesList
                }
            }
            .navigationTitle(NSLocalizedString("tab.certificates", comment: ""))
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
            .onAppear { viewModel.refresh() }
            .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: Binding(get: { certToDelete != nil }, set: { if !$0 { certToDelete = nil } })) {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                    if let c = certToDelete { viewModel.delete(c) }
                    certToDelete = nil
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { certToDelete = nil }
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
    private var emptyState: some View {
        EmptyStateView(
            NSLocalizedString("certs.empty", comment: ""),
            systemImage: "key.fill",
            description: Text(NSLocalizedString("certs.empty.detail", comment: ""))
        ) {
            Button(NSLocalizedString("certs.import.p12", comment: "")) { viewModel.showP12Importer = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("certs.import.empty")
        }
    }

    private var certificatesList: some View {
        List(viewModel.certificates) { cert in
            Button { selectedCert = cert } label: {
                HStack {
                    Image(systemName: cert.kind == "P12" ? "key.fill" : "doc.badge.gearshape")
                    VStack(alignment: .leading) {
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
                    Button(NSLocalizedString("common.cancel", comment: "")) { viewModel.p12Password = ""; showPasswordSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("cert.validate", comment: "")) {
                        switch viewModel.validateP12() {
                        case .success(let message):
                            validationResult = message
                            if let url = viewModel.pendingP12URL { viewModel.importFile(url) }
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
