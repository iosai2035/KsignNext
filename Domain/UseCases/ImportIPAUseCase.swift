import Foundation

/// Import flow: validate -> import -> persist.
/// The use case owns the order and the logging; the engine owns the
/// file work. A failure at any step aborts the import with a typed error.
public final class ImportIPAUseCase {
    private let ipaEngine: IPAEngineProtocol
    private let repository: ImportedApplicationRepository
    private let logs: LogsManager

    public init(ipaEngine: IPAEngineProtocol, repository: ImportedApplicationRepository, logs: LogsManager = .shared) {
        self.ipaEngine = ipaEngine
        self.repository = repository
        self.logs = logs
    }

    /// Imports the IPA at `url` and returns the stored record.
    public func execute(url: URL) async throws -> ImportedIPA {
        let operationID = UUID()
        await logs.info("Import started for \(url.lastPathComponent)", operationID: operationID)
        do {
            let report = try await ipaEngine.validateIPA(at: url)
            guard report.isValid else {
                let detail = report.errors.joined(separator: "; ")
                await logs.error("Import validation failed: \(detail)", operationID: operationID)
                throw AppError.ipa(.invalidInfoPlist(reason: detail))
            }
            let imported = try await ipaEngine.importIPA(from: url)
            try await repository.save(imported)
            await logs.info("Imported \(imported.name) (\(imported.bundleIdentifier))", operationID: operationID)
            return imported
        } catch {
            await logs.logError(error, operationID: operationID, context: "Import failed")
            throw error
        }
    }

    /// Validates and inspects without importing, for the preview screen.
    /// Builds a lightweight ImportedIPA shell around the source URL so
    /// the engine can inspect it; nothing is copied into the workspace.
    public func inspect(url: URL) async throws -> IPAInspectionReport {
        let metadata = try await ipaEngine.readAppMetadata(at: url)
        let shell = ImportedIPA(
            name: metadata.name,
            bundleIdentifier: metadata.bundleIdentifier,
            version: metadata.version,
            buildVersion: metadata.buildVersion,
            minimumOSVersion: metadata.minimumOSVersion,
            fileSize: metadata.fileSize,
            fileURL: url,
            metadata: metadata
        )
        return try await ipaEngine.inspectIPA(shell)
    }
}
