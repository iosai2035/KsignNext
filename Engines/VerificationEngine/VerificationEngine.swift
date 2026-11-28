import Foundation

/// Post-sign structural verification. Extracts the IPA to a temp
/// dir and checks it structurally.
///
/// Throws ONLY for unreadable input (missing file, not a ZIP,
/// extraction failure). A structurally unsound app returns
/// `passed == false` with each failed check named in `failures`,
/// so the caller can report the specific reason.
///
/// Honest limit: this proves the signature artefacts are present
/// and consistent — NOT that Apple cryptographically signed
/// anything. A pass means "structurally sound".
public final class VerificationEngine: VerificationEngineProtocol, @unchecked Sendable {
    private let archive: ArchiveEngine
    private let fileSystem: FileSystemManager
    private let fileManager = FileManager.default

    public init(archive: ArchiveEngine = ArchiveEngine(), fileSystem: FileSystemManager = .shared) {
        self.archive = archive
        self.fileSystem = fileSystem
    }

    public func verify(signedIPAURL: URL, expectedBundleIdentifier: String, expectProfile: Bool) async throws -> VerificationReport {
        guard fileManager.fileExists(atPath: signedIPAURL.path) else {
            throw AppError.ipa(.fileNotFound(path: signedIPAURL.path))
        }
        let workspace = try fileSystem.createTempDirectory(named: "verify-\(UUID().uuidString)")
        defer { fileSystem.cleanupTempDirectory(workspace) }
        let extracted: [URL]
        do {
            extracted = try archive.extractAll(from: signedIPAURL, to: workspace)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.ipa(.invalidZIP(error.localizedDescription))
        }
        _ = extracted

        var failures: [String] = []
        let payload = workspace.appendingPathComponent("Payload", isDirectory: true)
        let appURLs: [URL]
        do {
            appURLs = try fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
        } catch {
            failures.append("No Payload folder with an app bundle was found.")
            return VerificationReport(passed: false, failures: failures)
        }
        guard appURLs.count == 1, let appURL = appURLs.first else {
            failures.append(appURLs.isEmpty
                ? "No app bundle was found under Payload/."
                : "Found \(appURLs.count) app bundles under Payload/; exactly one is expected.")
            return VerificationReport(passed: false, failures: failures)
        }

        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            failures.append("Info.plist is missing or does not parse.")
            return VerificationReport(passed: false, failures: failures)
        }
        if (plist["CFBundleIdentifier"] as? String) != expectedBundleIdentifier {
            failures.append("CFBundleIdentifier “\(plist["CFBundleIdentifier"] as? String ?? "")” does not match the expected “\(expectedBundleIdentifier)”.")
        }
        guard let executableName = plist["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            failures.append("Info.plist has no CFBundleExecutable.")
            return VerificationReport(passed: false, failures: failures)
        }
        let executableURL = appURL.appendingPathComponent(executableName)
        guard fileManager.fileExists(atPath: executableURL.path) else {
            failures.append("Executable “\(executableName)” is missing from the app bundle.")
            return VerificationReport(passed: false, failures: failures)
        }
        do {
            let handle = try FileHandle(forReadingFrom: executableURL)
            defer { try? handle.close() }
            guard let window = try handle.read(upToCount: IPAEngine.executableInspectionWindow) else {
                failures.append("Executable “\(executableName)” could not be read.")
                return VerificationReport(passed: false, failures: failures)
            }
            if try !MachOEngine.hasCodeSignature(data: window) {
                failures.append("Executable “\(executableName)” has no code signature (LC_CODE_SIGNATURE).")
            }
        } catch let error as AppError {
            failures.append("Executable “\(executableName)” could not be checked: \(error.localizedDescription)")
        } catch {
            failures.append("Executable “\(executableName)” could not be read: \(error.localizedDescription)")
        }

        let codeResourcesURL = appURL
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources")
        guard fileManager.fileExists(atPath: codeResourcesURL.path) else {
            failures.append("_CodeSignature/CodeResources is missing.")
            return VerificationReport(passed: false, failures: failures)
        }
        do {
            let resourcesData = try Data(contentsOf: codeResourcesURL)
            _ = try PropertyListSerialization.propertyList(from: resourcesData, format: nil)
        } catch {
            failures.append("_CodeSignature/CodeResources does not parse as a property list.")
        }

        if expectProfile {
            let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
            if !fileManager.fileExists(atPath: profileURL.path) {
                failures.append("embedded.mobileprovision is missing.")
            }
        }

        return VerificationReport(passed: failures.isEmpty, failures: failures)
    }
}
