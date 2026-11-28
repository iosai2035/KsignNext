import Foundation

/// Signs one IPA and records the attempt.
///
/// Flow: resolve certificate/profile via the repositories (a
/// missing id is a specific typed error, not a silent nil); resolve
/// the P12 password early via `certificateEngine.storedPassword`
/// (transient local — a Keychain failure surfaces before any
/// signing starts; the engine re-resolves it through its own
/// resolver at sign time); compute the output URL in `Signed/` as
/// `<bundleIdentifier>-signed-<operationID-8>.ipa`; sign with
/// progress; then verify UNCONDITIONALLY — even when the engine
/// was configured to skip verification, a `passed == false` here
/// deletes the output file and throws `.verificationFailed`.
///
/// On success the operation is recorded as `.succeeded` (output
/// path + SHA-256 + size + certificate/profile ids); on ANY failure
/// it is recorded as `.failed` (or `.cancelled`) with the error
/// message — best-effort, so a recording failure never masks the
/// original error. No orphan success record, no orphan output file
/// on failure.
public struct SignApplicationUseCase: Sendable {
    private let engine: any SigningEngineProtocol
    private let certificateRepository: any CertificateRepository
    private let provisioningRepository: any ProvisioningProfileRepository
    private let certificateEngine: any CertificateEngineProtocol
    private let operationRepository: any SigningOperationRepositoryProtocol
    private let fileSystem: FileSystemManager
    private let logger: AppLogger

    public init(engine: any SigningEngineProtocol,
                certificateRepository: any CertificateRepository,
                provisioningRepository: any ProvisioningProfileRepository,
                certificateEngine: any CertificateEngineProtocol,
                operationRepository: any SigningOperationRepositoryProtocol,
                fileSystem: FileSystemManager,
                logger: AppLogger) {
        self.engine = engine
        self.certificateRepository = certificateRepository
        self.provisioningRepository = provisioningRepository
        self.certificateEngine = certificateEngine
        self.operationRepository = operationRepository
        self.fileSystem = fileSystem
        self.logger = logger
    }

    public func execute(sourceURL: URL, configuration: SigningConfiguration,
                        progress: @escaping @Sendable (SigningProgress) -> Void) async throws -> SignedResult {
        let operationID = UUID()
        let started = Date()
        var operation = SigningOperationModel(id: operationID, status: .running, startDate: started,
                                             bundleIdentifier: configuration.bundleIdentifier,
                                             certificateID: configuration.certificateID,
                                             provisioningProfileID: configuration.provisioningProfileID)
        let signedFolder = try fileSystem.folder(.signed)
        let outputURL = signedFolder.appendingPathComponent(
            "\(configuration.bundleIdentifier)-signed-\(operationID.uuidString.prefix(8)).ipa")
        do {
            // Resolve the identity first: a missing id is a typed
            // error here, not a nil the engine trips over later.
            var certificate: CertificateModel?
            var profile: ProvisioningModel?
            if !configuration.doAdhocSigning {
                if let certificateID = configuration.certificateID {
                    guard let resolved = try await certificateRepository.fetch(id: certificateID) else {
                        throw AppError.signing(.invalidCertificate(reason: "No certificate was found with that id."))
                    }
                    certificate = resolved
                    // Early password resolution: a Keychain failure
                    // surfaces before signing starts. The value is
                    // transient; the engine re-resolves it at sign
                    // time through its own resolver.
                    _ = try certificateEngine.storedPassword(for: resolved)
                } else {
                    throw AppError.signing(.invalidCertificate(reason: "No certificate was selected."))
                }
                if let profileID = configuration.provisioningProfileID {
                    guard let resolved = try await provisioningRepository.fetch(id: profileID) else {
                        throw AppError.signing(.missingProvisioningProfile)
                    }
                    profile = resolved
                } else {
                    throw AppError.signing(.missingProvisioningProfile)
                }
            }
            _ = certificate
            _ = profile

            let request = SigningRequest(operationID: operationID, sourceURL: sourceURL,
                                         outputURL: outputURL, configuration: configuration)
            let result = try await engine.sign(request, progress: progress)

            // Unconditional verification: the engine may have been
            // configured to skip it, but success is only recorded
            // after this check passes.
            let report = try await engine.verify(
                result.outputURL, bundleIdentifier: configuration.bundleIdentifier,
                expectProfile: !configuration.doAdhocSigning && !configuration.removeProvisioning)
            guard report.passed else {
                try? FileManager.default.removeItem(at: result.outputURL)
                throw AppError.signing(.verificationFailed(reason: report.failures.joined(separator: "; ")))
            }

            operation.status = .succeeded
            operation.endDate = Date()
            operation.outputPath = result.outputURL.path
            operation.outputSHA256 = result.sha256
            operation.outputSizeBytes = result.sizeBytes
            try? await operationRepository.save(operation)
            return result
        } catch {
            await logger.logError(error, context: "SignApplicationUseCase")
            // A failed sign must never leave an output file behind.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            operation.endDate = Date()
            operation.errorMessage = error.localizedDescription
            if case AppError.signing(.cancelled) = error {
                operation.status = .cancelled
            } else if case AppError.cancelled = error {
                operation.status = .cancelled
            } else {
                operation.status = .failed
            }
            try? await operationRepository.save(operation)
            throw error
        }
    }
}
