import Foundation

/// Imports a P12 certificate: engine import (parse → validate → copy
/// → Keychain) then repository save, with rollback in reverse on
/// failure.
///
/// Transaction order: the engine parses, copies the file into
/// `Certificates/` and saves the password in the Keychain — always,
/// even when `password` is `""` (a password-less P12 is registered
/// like any other; a Keychain-save failure inside the engine already
/// deletes the copied file — that is the engine's job). This use case
/// then saves the record. If the repository save fails, the Keychain
/// item (under `passwordAccount(for: model.id)`) AND the copied file
/// are deleted and the original error is rethrown, so no orphan file,
/// orphan Keychain item or orphan record can remain.
///
/// Init shape (coordinator decision, 2026-11-28 — a deviation from
/// design §B.10, which listed only `(engine, repository, logger)`):
/// the rollback above is impossible without a Keychain handle and a
/// filesystem handle, so `keychain` and `fileSystem` are required
/// injected dependencies, following the existing pattern of
/// `DeleteCertificateUseCase`. The final integration worker updates
/// design §B.10 accordingly.
public struct ImportCertificateUseCase: Sendable {
    private let engine: CertificateEngineProtocol
    private let repository: CertificateRepository
    private let keychain: KeychainService
    private let fileSystem: FileSystemManager
    private let logger: AppLogger

    public init(
        engine: CertificateEngineProtocol,
        repository: CertificateRepository,
        keychain: KeychainService,
        fileSystem: FileSystemManager,
        logger: AppLogger
    ) {
        self.engine = engine
        self.repository = repository
        self.keychain = keychain
        self.fileSystem = fileSystem
        self.logger = logger
    }

    public func execute(fileURL: URL, password: String) async throws -> CertificateModel {
        let model: CertificateModel
        do {
            model = try await engine.importP12(at: fileURL, password: password)
        } catch {
            await logger.logError(error, context: "ImportCertificateUseCase")
            throw error
        }

        do {
            try await repository.save(model)
        } catch {
            // Roll back in reverse: Keychain item, then copied file.
            // The account is the one the engine recorded on the
            // model; when it is absent, it is derived from the
            // engine's canonical account for this id. Rollback
            // failures are logged but never mask the original error.
            let account = model.keychainAccount ?? type(of: engine).passwordAccount(for: model.id)
            do {
                try keychain.delete(account: account)
            } catch {
                await logger.error("Certificate import rollback: could not remove the Keychain item for \(model.id.uuidString): \(error.localizedDescription)")
            }
            if let copiedURL = model.fileURL {
                do {
                    try fileSystem.delete(at: copiedURL)
                } catch {
                    await logger.error("Certificate import rollback: could not remove the copied file for \(model.id.uuidString): \(error.localizedDescription)")
                }
            }
            await logger.logError(error, context: "ImportCertificateUseCase")
            throw error
        }

        await logger.info("Imported certificate \(model.name) (\(model.id.uuidString))")
        return model
    }
}
