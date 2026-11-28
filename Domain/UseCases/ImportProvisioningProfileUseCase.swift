import Foundation

/// Imports a provisioning profile: engine import (parse → reject an
/// already-expired profile before any copy → copy) then repository
/// save, with rollback in reverse on failure.
///
/// If the repository save fails, the copied file is deleted and the
/// original error is rethrown, so no orphan file or orphan record can
/// remain. A corrupt profile writes nothing: the engine throws before
/// any copy, and this use case saves nothing.
///
/// Init shape (coordinator decision, 2026-11-28 — a deviation from
/// design §B.10, which listed only `(engine, repository, logger)`):
/// the rollback above is impossible without a filesystem handle, so
/// `fileSystem` is a required injected dependency, following the
/// existing pattern of `DeleteProvisioningProfileUseCase`. The final
/// integration worker updates design §B.10 accordingly.
public struct ImportProvisioningProfileUseCase: Sendable {
    private let engine: ProvisioningEngineProtocol
    private let repository: ProvisioningProfileRepository
    private let fileSystem: FileSystemManager
    private let logger: AppLogger

    public init(
        engine: ProvisioningEngineProtocol,
        repository: ProvisioningProfileRepository,
        fileSystem: FileSystemManager,
        logger: AppLogger
    ) {
        self.engine = engine
        self.repository = repository
        self.fileSystem = fileSystem
        self.logger = logger
    }

    public func execute(fileURL: URL) async throws -> ProvisioningModel {
        let model: ProvisioningModel
        do {
            model = try await engine.importProvisioningProfile(at: fileURL)
        } catch {
            await logger.logError(error, context: "ImportProvisioningProfileUseCase")
            throw error
        }

        do {
            try await repository.save(model)
        } catch {
            // Roll back in reverse: delete the copied file. A
            // rollback failure is logged but never masks the original
            // error.
            if let copiedURL = model.fileURL {
                do {
                    try fileSystem.delete(at: copiedURL)
                } catch {
                    await logger.error("Profile import rollback: could not remove the copied file for \(model.id.uuidString): \(error.localizedDescription)")
                }
            }
            await logger.logError(error, context: "ImportProvisioningProfileUseCase")
            throw error
        }

        await logger.info("Imported provisioning profile \(model.name) (\(model.id.uuidString))")
        return model
    }
}
