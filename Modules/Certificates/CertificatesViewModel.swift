import Foundation

/// Certificates manager state (contract §C.3). Import and delete go
/// through the use cases (§B.10); every failure surfaces in
/// `errorMessage`. The P12 password is never stored here — the
/// password sheet owns it, and the sheet clears it once the import
/// consumes it (W-3: an empty password still registers).
@MainActor
final class CertificatesViewModel: ObservableObject {
    @Published var certificates: [CertificateModel] = []
    @Published var profiles: [ProvisioningModel] = []
    @Published var errorMessage: String?
    @Published var showP12Importer = false
    @Published var showProvisionImporter = false
    @Published var pendingP12URL: URL?
    @Published var isLoading = false

    let container: DependencyContainer

    init(container: DependencyContainer) {
        self.container = container
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let certificateRepository = try container.resolveCertificateRepository()
            certificates = try await certificateRepository.fetchAll()
            let profileRepository = try container.resolveProvisioningProfileRepository()
            profiles = try await profileRepository.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Imports a P12 with the given password (empty = password-less,
    /// still registers, W-3). The password is consumed here and the
    /// caller clears its copy. Returns true on success.
    func importP12(url: URL, password: String) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let taskID = container.taskRegistry.register(
            label: Loc.string("certs.import.p12"), destination: .certificates
        )
        defer { container.taskRegistry.finish(id: taskID) }
        do {
            let useCase = try container.makeImportCertificateUseCase()
            let model = try await useCase.execute(fileURL: url, password: password)
            // Remove the coordinator's plain Certificates/ copy when
            // the engine stored its own <base>-<id>.p12: the plain
            // copy would otherwise be an orphan duplicate. A
            // failure here only warns — the import already succeeded.
            if let storedURL = model.fileURL, storedURL != url {
                do {
                    let certsDir = try container.files.folder(.certificates)
                    if url.deletingLastPathComponent() == certsDir {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    await AppLogger.shared.warning("Could not remove plain P12 copy after import: \(error.localizedDescription)")
                }
            }
            await AppLogger.shared.info("Imported certificate \(model.name)")
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await AppLogger.shared.logError(error, context: "Import P12")
            return false
        }
    }

    /// Imports a provisioning profile. An already-expired profile is
    /// rejected by the use case before any file is copied
    /// (`provisioningExpired`). Returns true on success.
    func importProfile(url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let taskID = container.taskRegistry.register(
            label: Loc.string("certs.import.provision"), destination: .certificates
        )
        defer { container.taskRegistry.finish(id: taskID) }
        do {
            let useCase = try container.makeImportProvisioningProfileUseCase()
            let model = try await useCase.execute(fileURL: url)
            await AppLogger.shared.info("Imported provisioning profile \(model.name)")
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await AppLogger.shared.logError(error, context: "Import provisioning profile")
            return false
        }
    }

    /// Deletes a certificate (record + file + Keychain item) with
    /// per-step errors (W-6). Returns true only when every step
    /// succeeded — the caller dismisses only then.
    func deleteCertificate(id: UUID) async -> Bool {
        do {
            let useCase = try container.makeDeleteCertificateUseCase()
            try await useCase.execute(id: id)
            await AppLogger.shared.info("Deleted certificate \(id.uuidString)")
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await AppLogger.shared.logError(error, context: "Delete certificate")
            return false
        }
    }

    /// Deletes a provisioning profile (record + file) with per-step
    /// errors (W-6). Returns true only when every step succeeded.
    func deleteProfile(id: UUID) async -> Bool {
        do {
            let useCase = try container.makeDeleteProvisioningProfileUseCase()
            try await useCase.execute(id: id)
            await AppLogger.shared.info("Deleted provisioning profile \(id.uuidString)")
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await AppLogger.shared.logError(error, context: "Delete provisioning profile")
            return false
        }
    }
}
