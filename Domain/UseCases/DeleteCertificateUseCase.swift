import Foundation

/// Deletes a certificate: repository record → file → Keychain item.
///
/// The record is fetched first so the file URL and Keychain account
/// are known before the record is gone. If the record is missing,
/// `AppError.storage(.notFound(id:))` is thrown and no further step
/// runs. If the record deletion itself fails, the file and Keychain
/// steps do not run (deleting them would orphan the surviving
/// record). If the record is gone but a later step fails, the
/// remaining steps still run and every failure is collected; the
/// thrown `AppError.storage(.deleteFailed(reason:))` names the
/// failed step(s). The UI dismisses only when all steps succeed —
/// errors are never swallowed and the view never dismissed on a
/// partial failure.
public struct DeleteCertificateUseCase: Sendable {
    private let repository: CertificateRepository
    private let keychain: KeychainService
    private let fileSystem: FileSystemManager
    private let logger: AppLogger

    public init(
        repository: CertificateRepository,
        keychain: KeychainService,
        fileSystem: FileSystemManager,
        logger: AppLogger
    ) {
        self.repository = repository
        self.keychain = keychain
        self.fileSystem = fileSystem
        self.logger = logger
    }

    public func execute(id: UUID) async throws {
        guard let model = try await repository.fetch(id: id) else {
            throw AppError.storage(.notFound(id: id.uuidString))
        }

        do {
            try await repository.delete(id: id)
        } catch {
            await logger.logError(error, context: "DeleteCertificateUseCase")
            throw AppError.storage(.deleteFailed(reason: "Certificate record deletion failed: \(error.localizedDescription)"))
        }

        var failures: [String] = []

        if let fileURL = model.fileURL {
            do {
                try fileSystem.delete(at: fileURL)
            } catch {
                failures.append("certificate file deletion failed: \(error.localizedDescription)")
            }
        }

        if let account = model.keychainAccount {
            do {
                try keychain.delete(account: account)
            } catch {
                failures.append("Keychain item deletion failed: \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            let reason = failures.joined(separator: "; ")
            await logger.error("Certificate deletion partially failed for \(id.uuidString): \(reason)")
            throw AppError.storage(.deleteFailed(reason: reason))
        }

        await logger.info("Deleted certificate \(model.name) (\(id.uuidString))")
    }
}
