import SwiftUI

struct CertificateInfo: Equatable {
    var subject = "", issuer = "", serial = "", fingerprint = "", status = "", expiry = ""
    var isExpired = false
    var compatibilityResult = ""
}

@MainActor
final class CertificateDetailViewModel: ObservableObject {
    @Published var info = CertificateInfo()
    @Published var isLoading = false
    @Published var errorMessage: String?
    let certificate: StoredCertificate

    init(certificate: StoredCertificate) { self.certificate = certificate }

    func load() {
        isLoading = true
        defer { isLoading = false }
        info.subject = certificate.name
        if certificate.kind == "mobileprovision" {
            info.status = parseProvision()
        } else {
            info.status = NSLocalizedString("cert.status.stored", comment: "")
        }
    }

    /// Reads the mobileprovision plist (CMS-wrapped files report honestly as unreadable here).
    private func parseProvision() -> String {
        guard let data = try? Data(contentsOf: certificate.url) else {
            return NSLocalizedString("cert.error.read", comment: "")
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let name = plist["Name"] as? String {
            info.expiry = (plist["ExpirationDate"] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? ""
            if let exp = plist["ExpirationDate"] as? Date { info.isExpired = exp < Date() }
            return name
        }
        return NSLocalizedString("cert.provision.cms", comment: "")
    }

    func testCompatibility() {
        info.compatibilityResult = certificate.kind == "P12"
            ? NSLocalizedString("cert.compat.p12", comment: "")
            : NSLocalizedString("cert.compat.provision", comment: "")
    }

    func delete() { try? FileManager.default.removeItem(at: certificate.url) }
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
        List {
            Section(NSLocalizedString("cert.detail.title", comment: "")) {
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
            }
            Section(NSLocalizedString("cert.compat.title", comment: "")) {
                Button(NSLocalizedString("cert.compat.run", comment: "")) { viewModel.testCompatibility() }
                    .accessibilityIdentifier("certDetail.compatibility")
                if !viewModel.info.compatibilityResult.isEmpty {
                    Text(viewModel.info.compatibilityResult).font(.caption)
                }
            }
            Section {
                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { showDeleteConfirm = true }
                    .accessibilityIdentifier("certDetail.delete")
            }
        }
        .navigationTitle(certificate.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load() }
        .alert(NSLocalizedString("common.delete.confirm", comment: ""), isPresented: $showDeleteConfirm) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                viewModel.delete(); onDeleted(); dismiss()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(2) }
    }
}
