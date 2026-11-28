import Foundation

/// Inspects an IPA without signing it. Every structural problem
/// throws the specific `AppError.ipa` case — never a generic error,
/// so the UI can show the exact reason.
public final class IPAEngine: IPAEngineProtocol, @unchecked Sendable {
    /// The executable inspection window. A fat binary whose arm64
    /// slice header lies beyond this window throws `.invalidMachO`
    /// naming the limit (documented, not silent).
    public static let executableInspectionWindow = 4 * 1024 * 1024

    private let archive: ArchiveEngine
    private let fileSystem: FileSystemManager

    public init(archive: ArchiveEngine = ArchiveEngine(), fileSystem: FileSystemManager = .shared) {
        self.archive = archive
        self.fileSystem = fileSystem
    }

    public func inspect(ipaURL: URL) async throws -> AppInfo {
        // File checks: exists, .ipa extension, non-empty, ZIP magic.
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw AppError.ipa(.fileNotFound(path: ipaURL.path))
        }
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw AppError.ipa(.notAnIPA(ipaURL))
        }
        let size = try fileSystem.fileSize(at: ipaURL)
        guard size > 0 else {
            throw AppError.ipa(.invalidZIP("IPA file is empty."))
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: ipaURL)
            defer { try? handle.close() }
            guard let bytes = try handle.read(upToCount: 4), bytes.count == 4 else {
                throw AppError.ipa(.invalidZIP("IPA file is too small to be a ZIP archive."))
            }
            header = bytes
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.ipa(.fileNotFound(path: ipaURL.path))
        }
        guard header == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw AppError.ipa(.invalidZIP("Not a ZIP archive (missing PK\\u{03}\\u{04} magic)."))
        }

        let entries = try archive.listEntries(at: ipaURL)
        guard entries.contains(where: { $0.name.hasPrefix("Payload/") }) else {
            throw AppError.ipa(.missingPayload)
        }
        let appNames = Set(entries.compactMap { entry -> String? in
            guard entry.name.hasPrefix("Payload/"), !entry.isDirectory else { return nil }
            let rest = entry.name.dropFirst("Payload/".count)
            guard !rest.contains("/"), rest.hasSuffix(".app") else { return nil }
            return String(rest)
        })
        // A `.app` directory entry itself (Payload/Foo.app/) also counts.
        let appDirs = Set(entries.compactMap { entry -> String? in
            guard entry.name.hasPrefix("Payload/") else { return nil }
            let rest = entry.name.dropFirst("Payload/".count)
            let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard first.hasSuffix(".app") else { return nil }
            return first
        })
        let apps = appNames.union(appDirs)
        guard !apps.isEmpty else { throw AppError.ipa(.noAppBundleFound) }
        guard apps.count == 1, let appName = apps.first else {
            throw AppError.ipa(.multipleAppsFound(count: apps.count))
        }

        let plistName = "Payload/\(appName)/Info.plist"
        guard entries.contains(where: { $0.name == plistName }) else {
            throw AppError.ipa(.missingInfoPlist)
        }
        let plistData = try archive.readEntryData(named: plistName, in: ipaURL)
        let plist: [String: Any]
        do {
            let object = try PropertyListSerialization.propertyList(from: plistData, format: nil)
            guard let dict = object as? [String: Any] else {
                throw AppError.ipa(.invalidInfoPlist(reason: "Info.plist is not a dictionary."))
            }
            plist = dict
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.ipa(.invalidInfoPlist(reason: error.localizedDescription))
        }
        guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            throw AppError.ipa(.invalidInfoPlist(reason: "Missing or empty CFBundleIdentifier."))
        }
        guard let executableName = plist["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw AppError.ipa(.invalidInfoPlist(reason: "Missing or empty CFBundleExecutable."))
        }

        let executableName_ = "Payload/\(appName)/\(executableName)"
        guard entries.contains(where: { $0.name == executableName_ }) else {
            throw AppError.ipa(.missingExecutable)
        }
        let executableData = try archive.readEntryData(
            named: executableName_, in: ipaURL, maxBytes: Self.executableInspectionWindow)
        let architectures: [MachOArchitecture]
        let hasSignature: Bool
        do {
            architectures = try MachOEngine.architectures(of: executableData)
            hasSignature = try MachOEngine.hasCodeSignature(data: executableData)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.ipa(.invalidMachO(error.localizedDescription))
        }

        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleIdentifier.split(separator: ".").last.map(String.init)
            ?? bundleIdentifier
        let version = (plist["CFBundleShortVersionString"] as? String) ?? ""
        let build = (plist["CFBundleVersion"] as? String) ?? ""
        return AppInfo(bundleIdentifier: bundleIdentifier, displayName: displayName, version: version,
                       build: build, executableName: executableName, appName: appName,
                       architectures: architectures, hasCodeSignature: hasSignature)
    }
}
