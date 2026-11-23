import Foundation

/// The IPA engine: import, validate, extract, inspect, read metadata,
/// package, and clean up IPA files.
///
/// Safety limits (enforced on every path that touches an archive):
/// - max IPA file size: 2 GB
/// - max entries: 50,000
/// - max total uncompressed size: 10 GB
/// - max single entry: 2 GB
/// - max compression ratio: 100:1 (zip-bomb guard)
/// - entry names must be relative, contain no `..`, and symlinks are never
///   followed outside the workspace.
public final class IPAEngine: IPAEngineProtocol {

    public static let maxIPASize: Int64 = 2 * 1024 * 1024 * 1024
    public static let maxEntryCount: Int = 50_000
    public static let maxTotalUncompressedSize: Int64 = 10 * 1024 * 1024 * 1024
    public static let maxSingleEntrySize: Int64 = 2 * 1024 * 1024 * 1024
    public static let maxCompressionRatio: Double = 100.0

    private let workspaceRoot: URL
    private let archive = ArchiveEngine()
    private let plistReader = PlistReader()
    private let machOEngine = MachOEngine()
    private let fileManager = FileManager.default

    /// - Parameter workspaceRoot: Directory holding `imports/`, `extracted/`
    ///   and `packaged/` subdirectories. Defaults to
    ///   `<Application Support>/KsignNext/IPA` (falls back to the caches
    ///   directory when Application Support is unavailable).
    public init(workspaceRoot: URL? = nil) {
        if let workspaceRoot {
            self.workspaceRoot = workspaceRoot
        } else if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.workspaceRoot = support.appendingPathComponent("KsignNext/IPA", isDirectory: true)
        } else {
            self.workspaceRoot = fileManager.temporaryDirectory.appendingPathComponent("KsignNext/IPA", isDirectory: true)
        }
    }

    // MARK: - Workspace layout

    private var importsDirectory: URL {
        workspaceRoot.appendingPathComponent("imports", isDirectory: true)
    }

    private var extractedDirectory: URL {
        workspaceRoot.appendingPathComponent("extracted", isDirectory: true)
    }

    private var packagedDirectory: URL {
        workspaceRoot.appendingPathComponent("packaged", isDirectory: true)
    }

    private func ensureWorkspace() throws {
        try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packagedDirectory, withIntermediateDirectories: true)
    }

    private func extractionDirectory(for id: UUID) -> URL {
        extractedDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - IPAEngineProtocol

    /// Imports an IPA from `url` (e.g. a Files / share-sheet URL): copies
    /// it into the workspace under a fresh UUID, validates the ZIP
    /// structure, and reads its metadata. Security-scoped access is
    /// honoured when the URL needs it.
    public func importIPA(from url: URL) async throws -> ImportedIPA {
        try ensureWorkspace()
        guard fileManager.fileExists(atPath: url.path) else {
            throw IPAError.fileNotFound(path: url.path)
        }
        guard url.pathExtension.lowercased() == "ipa" else {
            throw IPAError.notAnIPA(url)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw IPAError.invalidZIP("IPA file is empty.")
        }
        guard fileSize <= Self.maxIPASize else {
            throw IPAError.sizeLimitExceeded(limit: Self.maxIPASize, actual: fileSize)
        }

        let id = UUID()
        let destination = importsDirectory.appendingPathComponent("\(id.uuidString).ipa")
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw IPAError.ioError("Cannot copy IPA into workspace: \(error.localizedDescription)")
        }

        // Validate structure before trusting the file, and read metadata.
        let report = try await validateIPA(at: destination)
        guard report.isValid else {
            try? fileManager.removeItem(at: destination)
            throw IPAError.invalidZIP(report.errors.first ?? "IPA failed validation.")
        }
        let metadata = try await readAppMetadata(at: destination)
        return ImportedIPA(
            id: id,
            name: metadata.name,
            bundleIdentifier: metadata.bundleIdentifier,
            version: metadata.version,
            buildVersion: metadata.buildVersion,
            minimumOSVersion: metadata.minimumOSVersion,
            fileSize: fileSize,
            fileURL: destination,
            originalURL: url,
            iconData: metadata.iconData,
            metadata: metadata
        )
    }

    /// Validates the IPA at `url` without extracting it.
    public func validateIPA(at url: URL) async throws -> IPAValidationReport {
        try await IPAValidator().validate(url: url)
    }

    /// Extracts an imported IPA into `extracted/<id>/` and locates every
    /// `.app` bundle under `Payload/`.
    public func extractIPA(_ ipa: ImportedIPA) async throws -> ExtractedIPA {
        try ensureWorkspace()
        let sourceURL = ipa.fileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw IPAError.fileNotFound(path: sourceURL.path)
        }
        let directory = extractionDirectory(for: ipa.id)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try archive.extractAll(from: sourceURL, to: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        let appBundles = try findAppBundles(in: directory)
        guard !appBundles.isEmpty else {
            try? fileManager.removeItem(at: directory)
            throw IPAError.noAppBundleFound
        }
        let primary = appBundles.first
        let metadata = try primary.map { try readAppMetadataFromBundle($0) }
        return ExtractedIPA(
            importedIPAId: ipa.id,
            sourceURL: sourceURL,
            extractionDirectory: directory,
            appBundleURLs: appBundles,
            primaryAppBundleURL: primary,
            metadata: metadata
        )
    }

    /// Inspects an imported IPA: metadata, Mach-O facts, entitlements,
    /// extensions, frameworks, icons, and code-signature presence.
    public func inspectIPA(_ ipa: ImportedIPA) async throws -> IPAInspectionReport {
        // Inspection keeps the extraction around for the caller to use
        // (signing / installation read from it); cleanup is explicit via
        // cleanupWorkspace(for:). Nothing is deleted here.
        let extracted = try await extractIPA(ipa)
        guard let primaryBundle = extracted.primaryAppBundleURL,
              let metadata = extracted.metadata else {
            throw IPAError.noAppBundleFound
        }
        var warnings: [String] = []
        var architectures: [String] = []
        var isFat = false
        var isEncrypted = false
        var linkedLibraries: [String] = []
        var rpaths: [String] = []
        var segments: [String] = []
        var uuids: [String] = []
        var minimumOSVersion = metadata.minimumOSVersion
        var sdkVersion: String?
        var entitlements: [String: Any] = [:]
        var hasCodeSignature = false

        if let executableName = metadata.executableName {
            let executableURL = primaryBundle.appendingPathComponent(executableName)
            if fileManager.fileExists(atPath: executableURL.path) {
                do {
                    let machO = try machOEngine.parseMachO(at: executableURL)
                    architectures = machOEngine.architectures(of: machO)
                    isFat = machO.isFat
                    isEncrypted = machO.isEncrypted
                    linkedLibraries = machOEngine.linkedLibraryPaths(of: machO)
                    rpaths = machOEngine.rpaths(of: machO)
                    segments = machOEngine.segmentNames(of: machO)
                    if let uuid = machO.uuid { uuids.append(uuid) }
                    minimumOSVersion = machO.minimumOSVersion ?? minimumOSVersion
                    sdkVersion = machO.sdkVersion
                    hasCodeSignature = machO.hasCodeSignature
                    if machOEngine.hasNonARM64Slice(machO) {
                        warnings.append("Executable contains non-arm64 slices: \(architectures.joined(separator: ", ")).")
                    }
                    if isEncrypted {
                        warnings.append("Executable is FairPlay-encrypted (cryptid != 0) and cannot be re-signed as-is.")
                    }
                } catch {
                    warnings.append("Cannot parse main executable: \(error.localizedDescription)")
                }
            } else {
                warnings.append("Executable \(executableName) listed in Info.plist is missing from the bundle.")
            }
        }

        // Entitlements: prefer the embedded provisioning profile's
        // entitlements, fall back to a sibling .entitlements file.
        let provisioningURL = primaryBundle.appendingPathComponent("embedded.mobileprovision")
        if fileManager.fileExists(atPath: provisioningURL.path) {
            do {
                entitlements = try EntitlementsEngine().entitlementsFromProvisioningProfile(at: provisioningURL)
            } catch {
                warnings.append("Cannot read entitlements from provisioning profile: \(error.localizedDescription)")
            }
        }

        let codeSignatureURL = primaryBundle.appendingPathComponent("_CodeSignature")
        let hasCodeSignatureDirectory = fileManager.fileExists(atPath: codeSignatureURL.path)
        if hasCodeSignatureDirectory { hasCodeSignature = true }

        return IPAInspectionReport(
            metadata: metadata,
            appBundleURLs: extracted.appBundleURLs,
            architectures: architectures,
            isFatBinary: isFat,
            isEncrypted: isEncrypted,
            linkedLibraries: linkedLibraries,
            rpaths: rpaths,
            segments: segments,
            uuids: uuids,
            minimumOSVersion: minimumOSVersion,
            sdkVersion: sdkVersion,
            entitlements: entitlements.mapValues { String(describing: $0) },
            hasCodeSignature: hasCodeSignature,
            hasProvisioningProfile: fileManager.fileExists(atPath: provisioningURL.path),
            extensionBundleIdentifiers: metadata.extensionBundleIdentifiers,
            frameworkNames: metadata.frameworkNames,
            iconData: metadata.iconData,
            warnings: warnings
        )
    }

    /// Reads metadata for an IPA file URL or an .app bundle URL.
    public func readAppMetadata(at url: URL) async throws -> AppMetadata {
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" {
            return try await readAppMetadataFromIPA(url)
        }
        if ext == "app" {
            return try readAppMetadataFromBundle(url)
        }
        // A directory that is itself an .app bundle may arrive without the
        // extension in the path check above; accept it if it holds Info.plist.
        if fileManager.fileExists(atPath: url.appendingPathComponent("Info.plist").path) {
            return try readAppMetadataFromBundle(url)
        }
        throw IPAError.unsupportedFormat("Expected an .ipa file or an .app bundle, got \(url.lastPathComponent).")
    }

    /// Packages an .app bundle into a new IPA at
    /// `packaged/<bundle-id>-<version>.ipa` and returns its URL.
    /// The IPA layout is `Payload/<App>.app/...` with `SwiftSupport/` omitted
    /// (the signing engine adds it when needed).
    public func packageIPA(from appBundleURL: URL) async throws -> URL {
        try ensureWorkspace()
        guard appBundleURL.pathExtension.lowercased() == "app" else {
            throw IPAError.unsupportedFormat("packageIPA expects an .app bundle, got \(appBundleURL.lastPathComponent).")
        }
        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            throw IPAError.fileNotFound(path: appBundleURL.path)
        }
        let metadata = try readAppMetadataFromBundle(appBundleURL)
        let fileName = "\(metadata.bundleIdentifier)-\(metadata.version).ipa"
        let destination = packagedDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // Collect the bundle tree with archive paths under Payload/.
        guard let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw IPAError.ioError("Cannot enumerate \(appBundleURL.lastPathComponent).")
        }
        var files: [(archivePath: String, fileURL: URL)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true { continue }
            if values?.isSymbolicLink == true {
                // Symlinks inside a bundle (e.g. Frameworks/*.framework/Headers)
                // are skipped rather than followed: following them could pull
                // files from outside the bundle into the IPA.
                continue
            }
            let relative = fileURL.path.replacingOccurrences(of: appBundleURL.path + "/", with: "")
            let archivePath = "Payload/\(appBundleURL.lastPathComponent)/\(relative)"
            files.append((archivePath: archivePath, fileURL: fileURL))
        }
        guard !files.isEmpty else {
            throw IPAError.invalidZIP("App bundle \(appBundleURL.lastPathComponent) is empty.")
        }
        files.sort { $0.archivePath < $1.archivePath }
        try archive.createArchive(files: files, to: destination)
        return destination
    }

    /// Removes the imported file and extraction directory for `id`.
    public func cleanupWorkspace(for id: UUID) async throws {
        let imported = importsDirectory.appendingPathComponent("\(id.uuidString).ipa")
        if fileManager.fileExists(atPath: imported.path) {
            try fileManager.removeItem(at: imported)
        }
        let extracted = extractionDirectory(for: id)
        if fileManager.fileExists(atPath: extracted.path) {
            try fileManager.removeItem(at: extracted)
        }
    }

    // MARK: - Metadata reading

    /// Reads metadata from an IPA without extracting the whole archive:
    /// reads the central directory, finds the first .app's Info.plist and
    /// icon entries, and decodes them in memory.
    private func readAppMetadataFromIPA(_ ipaURL: URL) async throws -> AppMetadata {
        let entries = try archive.listEntries(at: ipaURL)
        let infoPlistNames = entries.map(\.name).filter {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist")
        }
        guard let plistName = infoPlistNames.sorted().first else {
            throw IPAError.missingInfoPlist
        }
        let plistData = try archive.readEntryData(named: plistName, in: ipaURL)
        let dict = try plistReader.readDictionary(data: plistData)
        // Bundle path inside the archive, e.g. "Payload/MyApp.app/".
        let bundlePath = String(plistName.dropLast("Info.plist".count))
        let attributes = try fileManager.attributesOfItem(atPath: ipaURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var metadata = try Self.metadata(from: dict, fileSize: fileSize, fileURL: ipaURL)
        // Icons: read the first matching icon entry from the archive.
        metadata.iconData = try Self.iconDataFromArchive(entries: entries, bundlePath: bundlePath, archiveURL: ipaURL, dict: dict, archive: archive)
        // Extensions / frameworks visible in the central directory.
        let prefix = bundlePath
        metadata.extensionBundleIdentifiers = entries.map(\.name)
            .filter { $0.hasPrefix(prefix + "PlugIns/") && $0.hasSuffix(".appex/Info.plist") }
            .map { name in
                let rest = String(name.dropFirst(prefix.count).dropFirst("PlugIns/".count))
                return String(rest.dropLast("/Info.plist".count))
            }
        metadata.hasExtensions = !metadata.extensionBundleIdentifiers.isEmpty
        metadata.frameworkNames = Set(entries.map(\.name)
            .filter { $0.hasPrefix(prefix + "Frameworks/") && $0.hasSuffix(".framework/") }
            .map { name in
                let rest = String(name.dropFirst(prefix.count).dropFirst("Frameworks/".count))
                return String(rest.dropLast("/".count))
            }).sorted()
        return metadata
    }

    /// Reads metadata from an extracted .app bundle on disk.
    private func readAppMetadataFromBundle(_ bundleURL: URL) throws -> AppMetadata {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw IPAError.missingInfoPlist
        }
        let dict = try plistReader.readDictionary(at: plistURL)
        let fileSize = directorySize(of: bundleURL)
        var metadata = try Self.metadata(from: dict, fileSize: fileSize, fileURL: bundleURL)
        metadata.iconData = iconDataFromBundle(bundleURL, dict: dict)
        metadata.extensionBundleIdentifiers = extensionBundleIdentifiers(in: bundleURL)
        metadata.hasExtensions = !metadata.extensionBundleIdentifiers.isEmpty
        metadata.frameworkNames = frameworkNames(in: bundleURL)
        // Architectures / encryption from the main executable, best-effort.
        if let executableName = metadata.executableName {
            let executableURL = bundleURL.appendingPathComponent(executableName)
            if fileManager.fileExists(atPath: executableURL.path),
               let machO = try? machOEngine.parseMachO(at: executableURL) {
                metadata.architectures = machOEngine.architectures(of: machO)
                metadata.isEncrypted = machO.isEncrypted
            }
        }
        return metadata
    }

    /// Builds AppMetadata from a parsed Info.plist dictionary.
    private static func metadata(from dict: [String: Any], fileSize: Int64, fileURL: URL?) throws -> AppMetadata {
        let reader = PlistReader()
        guard let bundleID = reader.string(dict, "CFBundleIdentifier"), !bundleID.isEmpty else {
            throw IPAError.invalidPlist("Info.plist has no CFBundleIdentifier.")
        }
        let name = reader.string(dict, "CFBundleDisplayName")
            ?? reader.string(dict, "CFBundleName")
            ?? bundleID
        let version = reader.string(dict, "CFBundleShortVersionString") ?? "1.0"
        let build = reader.string(dict, "CFBundleVersion") ?? "1"
        let minimumOS = reader.string(dict, "MinimumOSVersion")
        let executable = reader.string(dict, "CFBundleExecutable")
        let deviceFamilies = (dict["UIDeviceFamily"] as? [NSNumber])?.map(\.intValue) ?? []
        let urlSchemes = ((dict["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return AppMetadata(
            name: name,
            bundleIdentifier: bundleID,
            version: version,
            buildVersion: build,
            minimumOSVersion: minimumOS,
            executableName: executable,
            fileSize: fileSize,
            fileURL: fileURL,
            architectures: [],
            supportedDeviceFamilies: deviceFamilies,
            requiresiPhoneOS: reader.bool(dict, "LSRequiresIPhoneOS") ?? false,
            bundleDisplayName: reader.string(dict, "CFBundleDisplayName"),
            urlSchemes: urlSchemes
        )
    }

    // MARK: - Bundle discovery / icons / layout

    /// Finds every `.app` bundle directly under `Payload/` in an
    /// extraction directory.
    private func findAppBundles(in extractionDirectory: URL) throws -> [URL] {
        let payload = extractionDirectory.appendingPathComponent("Payload", isDirectory: true)
        guard fileManager.fileExists(atPath: payload.path) else {
            throw IPAError.missingPayload
        }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        } catch {
            throw IPAError.ioError("Cannot list Payload: \(error.localizedDescription)")
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Icon file names declared in Info.plist (`CFBundleIcons` /
    /// `CFBundleIconFiles` / `CFBundleIconFile`).
    private static func declaredIconNames(in dict: [String: Any]) -> [String] {
        var names: [String] = []
        if let icons = dict["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let files = dict["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let file = dict["CFBundleIconFile"] as? String {
            names.append(file)
        }
        return names
    }

    private func iconDataFromBundle(_ bundleURL: URL, dict: [String: Any]) -> Data? {
        for baseName in Self.declaredIconNames(in: dict) {
            for suffix in ["@3x.png", "@2x.png", ".png"] {
                let candidate = bundleURL.appendingPathComponent(baseName + suffix)
                if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                    return data
                }
            }
        }
        // Fallback: any AppIcon*.png in the bundle root.
        if let contents = try? fileManager.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix("AppIcon") && file.pathExtension.lowercased() == "png" {
                if let data = try? Data(contentsOf: file), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    private static func iconDataFromArchive(
        entries: [ZipEntry], bundlePath: String, archiveURL: URL,
        dict: [String: Any], archive: ArchiveEngine
    ) throws -> Data? {
        for baseName in declaredIconNames(in: dict) {
            for suffix in ["@3x.png", "@2x.png", ".png"] {
                let entryName = bundlePath + baseName + suffix
                if entries.contains(where: { $0.name == entryName }),
                   let data = try? archive.readEntryData(named: entryName, in: archiveURL), !data.isEmpty {
                    return data
                }
            }
        }
        for entry in entries where entry.name.hasPrefix(bundlePath) && entry.name.hasSuffix(".png") {
            let fileName = URL(fileURLWithPath: entry.name).lastPathComponent
            if fileName.hasPrefix("AppIcon"),
               let data = try? archive.readEntryData(entry, in: archiveURL), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func extensionBundleIdentifiers(in bundleURL: URL) -> [String] {
        let plugIns = bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "appex" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func frameworkNames(in bundleURL: URL) -> [String] {
        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "framework" }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Recursive size of a directory tree (best-effort; unreadable items
    /// contribute 0 rather than failing the whole metadata read).
    private func directorySize(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
