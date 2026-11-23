import Foundation

/// Contract for the IPA engine. Unified by the coordinator: this is the
/// method set the real `IPAEngine` implements (import/validate/extract/
/// inspect/metadata/package/cleanup). The Domain use cases call these
/// methods; see `ImportIPAUseCase`.
public protocol IPAEngineProtocol: AnyObject {
    func importIPA(from url: URL) async throws -> ImportedIPA
    func validateIPA(at url: URL) async throws -> IPAValidationReport
    func extractIPA(_ ipa: ImportedIPA) async throws -> ExtractedIPA
    func inspectIPA(_ ipa: ImportedIPA) async throws -> IPAInspectionReport
    func readAppMetadata(at url: URL) async throws -> AppMetadata
    func packageIPA(from appBundleURL: URL) async throws -> URL
    func cleanupWorkspace(for id: UUID) async throws
}
