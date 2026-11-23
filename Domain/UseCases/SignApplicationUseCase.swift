import Foundation

/// Signing flow: validate the configuration -> run the engine's
/// progress stream -> verify the result -> persist the signed record.
/// No success is reported unless a real signed file exists and, when
/// `verifyAfterSigning` is set, verification passed.
public final class SignApplicationUseCase {
    private let signingEngine: SigningEngineProtocol
    private let certificateRepository: CertificateRepository
    private let signedRepository: SignedApplicationRepository
    private let logs: LogsManager
    private let taskManager: TaskManager

    public init(
        signingEngine: SigningEngineProtocol,
        certificateRepository: CertificateRepository,
        signedRepository: SignedApplicationRepository,
        logs: LogsManager = .shared,
        taskManager: TaskManager = .shared
    ) {
        self.signingEngine = signingEngine
        self.certificateRepository = certificateRepository
        self.signedRepository = signedRepository
        self.logs = logs
        self.taskManager = taskManager
    }

    /// Runs signing, forwarding progress to `onProgress`, and returns
    /// the persisted `SigningResult`.
    public func execute(
        _ request: SigningRequest,
        onProgress: @escaping @Sendable (SigningProgress) -> Void
    ) async throws -> SigningResult {
        let operationID = request.operationID
        try BundleIDValidator.validate(request.configuration.bundleIdentifier)
        guard request.configuration.isUsable else {
            throw AppError.signing(.invalidCertificate(reason: "No certificate is selected and ad-hoc signing is off."))
        }
        if let certificateID = request.configuration.certificateID {
            guard try await certificateRepository.fetch(id: certificateID) != nil else {
                throw AppError.signing(.invalidCertificate(reason: "The selected certificate was not found."))
            }
        }
        await logs.info("Signing started for \(request.configuration.bundleIdentifier)", operationID: operationID)
        let startedAt = Date()
        var lastProgress: SigningProgress?
        do {
            // The workspace defines where the signed IPA is written
            // (`workspace.outputURL`); the engine moves it out of the
            // workspace before emitting `.completed`, so the workspace
            // may be cleaned up afterwards without deleting the output.
            let workspace = try await signingEngine.prepare(request)
            try await signingEngine.validate(request, workspace: workspace)
            for await progress in signingEngine.sign(request) {
                lastProgress = progress
                onProgress(progress)
                await logs.debug("\(progress.stage.rawValue): \(progress.message)", operationID: operationID)
                if progress.stage.isTerminal && progress.stage != .completed {
                    break
                }
            }
            guard let final = lastProgress, final.stage == .completed else {
                throw AppError.signing(.signingFailed(reason: "The signing stream ended without a completed event."))
            }
            // The engine guarantees the signed file exists at this point.
            // `verified` means the engine verified it when
            // `verifyAfterSigning` was set; a separate
            // `VerifySignatureUseCase` run can re-check it independently.
            let result = SigningResult(
                operationID: operationID,
                importedIPAID: request.importedIPAID,
                signedFileURL: workspace.outputURL,
                bundleIdentifier: request.configuration.bundleIdentifier,
                version: request.configuration.version ?? "",
                certificateID: request.configuration.certificateID,
                signatureStatus: .signed,
                verified: request.configuration.verifyAfterSigning,
                signedAt: Date(),
                duration: Date().timeIntervalSince(startedAt)
            )
            try await signedRepository.save(result)
            await logs.info("Signing completed for \(result.bundleIdentifier)", operationID: operationID)
            return result
        } catch {
            await logs.logError(error, operationID: operationID, context: "Signing failed")
            await signingEngine.cleanup(operationID: operationID)
            throw error
        }
    }

    public func cancel(operationID: UUID) async {
        await signingEngine.cancel(operationID: operationID)
        await taskManager.cancel(name: operationID.uuidString)
        await logs.info("Signing cancelled", operationID: operationID)
    }
}
