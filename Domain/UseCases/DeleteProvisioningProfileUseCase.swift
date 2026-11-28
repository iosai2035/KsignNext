import Foundation

/// Deletes a provisioning profile: repository record → file.
///
/// The record is fetched first so the file URL is known before the
/// record is gone. If the record is missing,
/// `AppError.storage(.notFound(id:))` is thrown and no further step
/// runs. If the record deletion itself fails, the file step does not
/// run (deleting it would orphan the surviving record). If the record
/// is gone but the file deletion fails, the thrown
/// `AppError.storage(.deleteFailed(reason:))` names the failed step.
/// The UI dismisses only when all steps succeed.
public struct DeleteProvisioningProfileUseCase: Sendable {
    private let repository: ProvisioningProfileRepository
    private let fileSystem: FileSystemManager
    private let logger: AppLogger

    public init(
        repository: ProvisioningProfileRepository,
        fileSystem: FileSystemManager,
        logger: AppLogger
    ) {
        self.repository = repository
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
            await logger.logError(error, context: "DeleteProvisioningProfileUseCase")
            throw AppError.storage(.deleteFailed(reason: "Profile record deletion failed: \(error.localizedDescription)"))
        }

        if let fileURL = model.fileURL {
            do {
                try fileSystem.delete(at: fileURL)
            } catch {
                let reason = "profile file deletion failed: \(error.localizedDescription)"
                await logger.error("Profile deletion partially failed for \(id.uuidString): \(reason)")
                throw AppError.storage(.deleteFailed(reason: reason))
            }
        }

        await logger.info("Deleted provisioning profile \(model.name) (\(id.uuidString))")
    }
}
