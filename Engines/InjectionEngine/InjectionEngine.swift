import Foundation

// MARK: - Public constants

/// Shown in every injection plan and result. ElleKit / MobileSubstrate
/// tweaks need a jailbroken runtime (or a jailbreak-style loader);
/// injecting them into an app signed for stock iOS does not make them
/// run, and nothing in this engine can change that.
public enum InjectionWarnings {
    public static let stockiOS =
        "Stock-iOS warning: ElleKit / MobileSubstrate tweaks are NOT guaranteed " +
        "to work on stock (non-jailbroken) iOS. Injection only places the files " +
        "and links them into the executable; a tweak that needs substrate, " +
        "ElleKit, or jailbreak-only APIs will load but do nothing — or crash " +
        "the app — on stock iOS. Only tweaks written to run without a substrate " +
        "have a realistic chance of working."
}

// MARK: - Plan / result types

public enum InjectionItemStatus: String, Codable {
    case ready
    case skippedDuplicate
    case skippedConflict
    case skippedUnsupported
}

/// One file that will be copied into the app bundle and (for dylibs)
/// linked into the main executable.
public struct InjectionItem: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var sourceURL: URL
    /// Path inside the .app bundle the file is copied to, for example
    /// "Frameworks/Tweak.dylib".
    public var destinationRelativePath: String
    public var injectionType: InjectionType
    public var architectures: [String]
    public var status: InjectionItemStatus
    public var skipReason: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceURL: URL,
        destinationRelativePath: String,
        injectionType: InjectionType,
        architectures: [String] = [],
        status: InjectionItemStatus = .ready,
        skipReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.destinationRelativePath = destinationRelativePath
        self.injectionType = injectionType
        self.architectures = architectures
        self.status = status
        self.skipReason = skipReason
    }
}

/// The full plan, built and shown BEFORE anything is copied or linked.
/// Executing a plan never adds items the plan did not list.
public struct InjectionPlan: Codable, Equatable, Identifiable {
    public let id: UUID
    public var appBundleURL: URL
    public var executablePath: String
    public var items: [InjectionItem]
    public var warnings: [String]
    public var stockIOSWarning: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        appBundleURL: URL,
        executablePath: String,
        items: [InjectionItem],
        warnings: [String] = [],
        stockIOSWarning: String = InjectionWarnings.stockiOS,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appBundleURL = appBundleURL
        self.executablePath = executablePath
        self.items = items
        self.warnings = warnings
        self.stockIOSWarning = stockIOSWarning
        self.createdAt = createdAt
    }

    public var readyItems: [InjectionItem] { items.filter { $0.status == .ready } }
    public var skippedItems: [InjectionItem] { items.filter { $0.status != .ready } }
}

public struct InjectionResult: Codable, Equatable, Identifiable {
    public let id: UUID
    public var planID: UUID
    public var injected: [String]
    public var skipped: [String]
    public var warnings: [String]
    public var stockIOSWarning: String
    public var completedAt: Date

    public init(
        id: UUID = UUID(),
        planID: UUID,
        injected: [String] = [],
        skipped: [String] = [],
        warnings: [String] = [],
        stockIOSWarning: String = InjectionWarnings.stockiOS,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.planID = planID
        self.injected = injected
        self.skipped = skipped
        self.warnings = warnings
        self.stockIOSWarning = stockIOSWarning
        self.completedAt = completedAt
    }
}

// MARK: - DEB inspection

/// What a DEB contains, without extracting it. `dataTarCompression`
/// reports the real compression honestly; only gzip data.tars can be
/// listed by this engine (see `ArchiveEngine.gunzip`).
public struct DebContents: Equatable {
    public var packageName: String?
    public var version: String?
    public var dataTarMember: String?
    public var dataTarCompression: TarCompression
    /// Files inside data.tar, when it could be read (gzip or plain tar).
    public var payloadFiles: [String]
    /// Human-readable reason when the payload could not be listed.
    public var payloadUnreadableReason: String?

    public init(
        packageName: String? = nil,
        version: String? = nil,
        dataTarMember: String? = nil,
        dataTarCompression: TarCompression = .unknown,
        payloadFiles: [String] = [],
        payloadUnreadableReason: String? = nil
    ) {
        self.packageName = packageName
        self.version = version
        self.dataTarMember = dataTarMember
        self.dataTarCompression = dataTarCompression
        self.payloadFiles = payloadFiles
        self.payloadUnreadableReason = payloadUnreadableReason
    }
}

// MARK: - Mach-O helpers (shared with the signing engine's checks)

/// Minimal Mach-O architecture reader. Reads only headers, never
/// executes anything. Returns architecture names such as "arm64".
public enum MachOArchitectures {
    public static let cpuArm64: Int32 = 0x0100000C
    public static let cpuArm64_32: Int32 = 0x0200000C
    public static let cpuArmV7: Int32 = 12

    public static func architectures(of data: Data) -> [String] {
        guard data.count >= 4 else { return [] }
        let magic = readUInt32(data, at: 0)
        switch magic {
        case 0xfeedfacf, 0xfeedface, 0xcefaedfe, 0xcffaedfe:
            guard data.count >= 8 else { return [] }
            let cpu = Int32(bitPattern: readUInt32(data, at: 4))
            return [name(forCPU: cpu)]
        case 0xcafebabe, 0xbebafeca:
            guard data.count >= 8 else { return [] }
            let count = Int(readUInt32BE(data, at: 4))
            var result: [String] = []
            var offset = 8
            for _ in 0..<count {
                guard offset + 8 <= data.count else { break }
                let cpu = Int32(bitPattern: readUInt32BE(data, at: offset))
                result.append(name(forCPU: cpu))
                offset += 20 // fat_arch: cputype, cpusubtype, offset, size, align
            }
            return result
        default:
            return []
        }
    }

    public static func architectures(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let head: Data?
        do { head = try handle.read(upToCount: 4096) } catch { return [] }
        guard let head, head.count >= 4 else { return [] }
        var data = head
        let magic = readUInt32(data, at: 0)
        if magic == 0xcafebabe || magic == 0xbebafeca {
            // Fat binary: read the whole header table (count * 20 bytes).
            guard data.count >= 8 else { return [] }
            let count = Int(readUInt32BE(data, at: 4))
            let needed = 8 + count * 20
            if needed > data.count, let rest = try? handle.read(upToCount: needed - data.count) {
                data.append(rest)
            }
        }
        return architectures(of: data)
    }

    public static func isArm64(_ architectures: [String]) -> Bool {
        architectures.contains("arm64")
    }

    /// The LC_ID_DYLIB install name of a thin 64-bit Mach-O, if present.
    /// Used to rewrite a dylib's install name to @rpath on injection.
    public static func installName(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32 else { return nil }
        let magic = readUInt32(data, at: 0)
        var commandsOffset = 32
        var slice = data
        if magic == 0xcafebabe || magic == 0xbebafeca {
            // First arm64 slice of a fat binary.
            guard data.count >= 8 else { return nil }
            let count = Int(readUInt32BE(data, at: 4))
            var sliceOffset: Int?
            var sliceSize: Int?
            for i in 0..<count {
                let base = 8 + i * 20
                guard base + 20 <= data.count else { break }
                let cpu = Int32(bitPattern: readUInt32BE(data, at: base))
                if cpu == cpuArm64 {
                    sliceOffset = Int(readUInt32BE(data, at: base + 8))
                    sliceSize = Int(readUInt32BE(data, at: base + 12))
                    break
                }
            }
            guard let off = sliceOffset, let size = sliceSize,
                  off + size <= data.count, size >= 32 else { return nil }
            slice = data.subdata(in: off..<(off + size))
            guard readUInt32(slice, at: 0) == 0xfeedfacf else { return nil }
        } else if magic != 0xfeedfacf {
            return nil
        }
        let ncmds = Int(readUInt32(slice, at: 16))
        var offset = commandsOffset
        for _ in 0..<ncmds {
            guard offset + 8 <= slice.count else { return nil }
            let cmd = readUInt32(slice, at: offset)
            let cmdSize = Int(readUInt32(slice, at: offset + 4))
            guard cmdSize >= 8, offset + cmdSize <= slice.count else { return nil }
            if cmd == 0x0d { // LC_ID_DYLIB
                guard offset + 24 <= slice.count else { return nil }
                let nameOffset = Int(readUInt32(slice, at: offset + 8))
                let nameStart = offset + nameOffset
                guard nameStart < slice.count else { return nil }
                let bytes = slice.subdata(in: nameStart..<min(offset + cmdSize, slice.count))
                let name = bytes.prefix(while: { $0 != 0 })
                return String(bytes: name, encoding: .utf8)
            }
            offset += cmdSize
        }
        _ = commandsOffset
        return nil
    }

    static func name(forCPU cpu: Int32) -> String {
        switch cpu {
        case cpuArm64: return "arm64"
        case cpuArm64_32: return "arm64_32"
        case cpuArmV7: return "armv7"
        default: return "cpu-\(cpu)"
        }
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

// MARK: - Engine

/// Imports dylib / DEB / framework / bundle tweaks, builds an
/// `InjectionPlan` (shown before execution), then executes it:
/// copies components into the .app bundle and links dylibs into the
/// main executable through the zsign backend.
public final class InjectionEngine: Sendable {
    private let backend: ZsignAdapter
    private let fileManager = FileManager.default
    /// Scratch dir for files extracted from DEBs; removed by `cleanup()`.
    private let stagingURL: URL

    public init(backend: any ZsignBackend) {
        self.backend = ZsignAdapter(backend: backend)
        self.stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-inject-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    public init(adapter: ZsignAdapter) {
        self.backend = adapter
        self.stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-inject-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    /// Removes the DEB-extraction scratch directory. Safe to call twice.
    public func cleanup() {
        try? fileManager.removeItem(at: stagingURL)
    }

    // MARK: Import

    /// Imports one tweak file and describes it as a `TweakModel`.
    /// Throws `SigningError` naming the file and the reason on failure.
    public func importTweak(from url: URL) throws -> TweakModel {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SigningError.invalidIPA(reason: "Tweak file not found: \(url.lastPathComponent).")
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "dylib":
            let archs = MachOArchitectures.architectures(at: url)
            return TweakModel(
                name: url.deletingPathExtension().lastPathComponent,
                architecture: archs.first ?? "unknown",
                injectionType: .dylib,
                compatibility: archs.isEmpty || MachOArchitectures.isArm64(archs)
                    ? .unknown : .incompatibleArchitecture,
                fileURL: url
            )
        case "deb":
            let contents = try inspectDeb(at: url)
            let hasSubstrate = contents.payloadFiles.contains {
                $0.contains("MobileSubstrate/DynamicLibraries")
            }
            return TweakModel(
                name: contents.packageName ?? url.deletingPathExtension().lastPathComponent,
                version: contents.version,
                injectionType: .deb,
                compatibility: hasSubstrate ? .jailbreakOnly : .unknown,
                fileURL: url
            )
        case "framework":
            return TweakModel(
                name: url.deletingPathExtension().lastPathComponent,
                injectionType: .framework,
                fileURL: url
            )
        case "bundle":
            return TweakModel(
                name: url.deletingPathExtension().lastPathComponent,
                injectionType: .bundle,
                fileURL: url
            )
        default:
            throw SigningError.invalidIPA(
                reason: "Unsupported tweak file “\(url.lastPathComponent)”: expected .dylib, .deb, .framework or .bundle."
            )
        }
    }

    // MARK: DEB inspection (pure-Swift AR reader)

    /// Reads a Debian package's `!<arch>` table, finds the data.tar
    /// member, and lists its payload when the compression allows it.
    /// gzip payloads are listed (decompressed with
    /// `ArchiveEngine.gunzip`); xz / bzip2 / lzma / zstd payloads are
    /// reported honestly as unreadable — this engine has no decoder
    /// for them and will not pretend otherwise.
    public func inspectDeb(at url: URL) throws -> DebContents {
        guard let data = try? Data(contentsOf: url) else {
            throw SigningError.invalidIPA(reason: "Cannot read DEB file: \(url.lastPathComponent).")
        }
        guard data.count >= 8, data[0..<8].elementsEqual("!<arch>\n".utf8) else {
            throw SigningError.invalidIPA(reason: "Not a Debian package (bad ar magic): \(url.lastPathComponent).")
        }
        var result = DebContents()
        var offset = 8
        var controlData: Data?
        var dataTarData: Data?
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            guard let nameRaw = String(bytes: header[0..<16], encoding: .utf8),
                  let sizeRaw = String(bytes: header[48..<58], encoding: .utf8),
                  let size = Int(sizeRaw.trimmingCharacters(in: .whitespaces)) else {
                throw SigningError.invalidIPA(reason: "Corrupt ar header in DEB: \(url.lastPathComponent).")
            }
            let name = nameRaw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/", with: "")
            let bodyStart = offset + 60
            guard bodyStart + size <= data.count else {
                throw SigningError.invalidIPA(reason: "Truncated ar member “\(name)” in DEB: \(url.lastPathComponent).")
            }
            let body = data.subdata(in: bodyStart..<(bodyStart + size))
            if name == "control.tar.gz" || name.hasPrefix("control.tar") {
                controlData = body
            } else if name.hasPrefix("data.tar") {
                result.dataTarMember = name
                dataTarData = body
            }
            offset = bodyStart + size + (size % 2) // ar members are 2-byte aligned
        }
        if let controlData {
            let controlTar = ArchiveEngine.gunzip(controlData) ?? controlData
            if let fields = extractControlFields(from: controlTar) {
                result.packageName = fields["Package"]
                result.version = fields["Version"]
            }
        }
        guard let dataTarData else {
            result.payloadUnreadableReason = "DEB has no data.tar member."
            return result
        }
        result.dataTarCompression = ArchiveEngine.detectTarCompression(dataTarData)
        switch result.dataTarCompression {
        case .gzip:
            if let tar = ArchiveEngine.gunzip(dataTarData),
               let entries = try? ArchiveEngine.parseTarEntries(tar) {
                result.payloadFiles = entries.filter { !$0.isDirectory }.map(\.name)
            } else {
                result.payloadUnreadableReason = "data.tar.gz could not be decompressed."
            }
        case .none:
            if let entries = try? ArchiveEngine.parseTarEntries(dataTarData) {
                result.payloadFiles = entries.filter { !$0.isDirectory }.map(\.name)
            } else {
                result.payloadUnreadableReason = "Uncompressed data.tar could not be parsed."
            }
        case .xz, .bzip2, .lzma, .zstd, .unknown:
            result.payloadUnreadableReason =
                "data.tar uses \(result.dataTarCompression.rawValue) compression, which this " +
                "engine cannot decompress on-device. Re-package the DEB with gzip " +
                "(data.tar.gz) to inspect and inject its payload."
        }
        return result
    }

    /// Parses the Debian `control` file (Package: / Version: lines)
    /// out of an uncompressed control.tar, walking its 512-byte
    /// headers directly (including GNU long-name 'L' entries).
    private func extractControlFields(from controlTar: Data) -> [String: String]? {
        guard let body = extractTarFile(named: "control", in: controlTar)
            ?? extractTarFile(named: "./control", in: controlTar),
              let text = String(data: body, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    /// Returns the bytes of one file member of an uncompressed tar, or
    /// nil when the member is absent. Walks headers directly so GNU
    /// long-name ('L') entries are honoured.
    private func extractTarFile(named wanted: String, in tar: Data) -> Data? {
        var offset = 0
        var pendingLongName: String?
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = String(bytes: header.subdata(in: 0..<100).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let sizeString = String(bytes: header.subdata(in: 124..<136).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let size = Int(sizeString.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let typeFlag = header[156]
            let blocks = Int((size + 511) / 512)
            let bodyStart = offset + 512
            guard bodyStart + size <= tar.count else { return nil }
            if typeFlag == UInt8(ascii: "L") {
                let body = tar.subdata(in: bodyStart..<(bodyStart + size))
                pendingLongName = String(bytes: body.prefix(while: { $0 != 0 }), encoding: .utf8)
                offset = bodyStart + blocks * 512
                continue
            }
            let effectiveName = pendingLongName ?? name
            pendingLongName = nil
            if effectiveName == wanted {
                return tar.subdata(in: bodyStart..<(bodyStart + size))
            }
            offset = bodyStart + blocks * 512
        }
        return nil
    }

    /// Extracts every tar member under `prefix` (a .framework or
    /// .bundle directory) into `destination`, preserving structure.
    private func extractTarPrefix(_ prefix: String, in tar: Data, to destination: URL) throws {
        var offset = 0
        var pendingLongName: String?
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = String(bytes: header.subdata(in: 0..<100).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let sizeString = String(bytes: header.subdata(in: 124..<136).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let size = Int(sizeString.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let typeFlag = header[156]
            let blocks = Int((size + 511) / 512)
            let bodyStart = offset + 512
            guard bodyStart + size <= tar.count else { break }
            if typeFlag == UInt8(ascii: "L") {
                let body = tar.subdata(in: bodyStart..<(bodyStart + size))
                pendingLongName = String(bytes: body.prefix(while: { $0 != 0 }), encoding: .utf8)
                offset = bodyStart + blocks * 512
                continue
            }
            let effectiveName = pendingLongName ?? name
            pendingLongName = nil
            let normalized = effectiveName.hasPrefix("./") ? String(effectiveName.dropFirst(2)) : effectiveName
            let prefixNorm = prefix.hasPrefix("./") ? String(prefix.dropFirst(2)) : prefix
            if normalized.hasPrefix(prefixNorm), typeFlag != UInt8(ascii: "5") {
                let relative = String(normalized.dropFirst(prefixNorm.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !relative.isEmpty {
                    let target = destination.appendingPathComponent(relative)
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try tar.subdata(in: bodyStart..<(bodyStart + size)).write(to: target)
                }
            }
            offset = bodyStart + blocks * 512
        }
    }

    // MARK: Planning

    /// Builds the plan for `tweaks` against `appBundleURL`. Nothing is
    /// copied or linked here. Duplicate destinations, files already in
    /// the bundle, and non-arm64 dylibs are marked skipped with a
    /// reason; the stock-iOS warning is always attached.
    public func plan(
        tweaks: [TweakModel],
        appBundleURL: URL,
        injectPath: InjectionPath = .frameworks,
        injectFolder: InjectionFolder = .frameworks
    ) throws -> InjectionPlan {
        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            throw SigningError.invalidIPA(reason: "App bundle not found: \(appBundleURL.lastPathComponent).")
        }
        guard let executable = executableName(in: appBundleURL) else {
            throw SigningError.invalidIPA(reason: "App bundle \(appBundleURL.lastPathComponent) has no executable in Info.plist.")
        }
        var warnings: [String] = []
        var seenDestinations: [String: String] = [:]
        var items: [InjectionItem] = []
        for tweak in tweaks where tweak.isEnabled {
            guard let source = tweak.fileURL else {
                warnings.append("Skipped tweak “\(tweak.name)”: it has no file.")
                continue
            }
            switch tweak.injectionType {
            case .dylib:
                let archs = MachOArchitectures.architectures(at: source)
                let destination = destinationPath(
                    fileName: source.lastPathComponent,
                    injectPath: injectPath, injectFolder: injectFolder, kind: .dylib
                )
                if !archs.isEmpty, !MachOArchitectures.isArm64(archs) {
                    items.append(item(
                        tweak: tweak, source: source, destination: destination,
                        architectures: archs, status: .skippedUnsupported,
                        reason: "Dylib “\(source.lastPathComponent)” is \(archs.joined(separator: ", ")), not arm64."
                    ))
                    continue
                }
                items.append(checkedItem(
                    tweak: tweak, source: source, destination: destination, architectures: archs,
                    appBundleURL: appBundleURL, seen: &seenDestinations
                ))
            case .framework:
                let destination = destinationPath(
                    fileName: source.lastPathComponent,
                    injectPath: injectPath, injectFolder: injectFolder, kind: .framework
                )
                items.append(checkedItem(
                    tweak: tweak, source: source, destination: destination, architectures: [],
                    appBundleURL: appBundleURL, seen: &seenDestinations
                ))
            case .bundle:
                let destination = destinationPath(
                    fileName: source.lastPathComponent,
                    injectPath: injectPath, injectFolder: injectFolder, kind: .bundle
                )
                items.append(checkedItem(
                    tweak: tweak, source: source, destination: destination, architectures: [],
                    appBundleURL: appBundleURL, seen: &seenDestinations
                ))
            case .deb:
                items.append(contentsOf: try debItems(
                    tweak: tweak, source: source,
                    appBundleURL: appBundleURL, seen: &seenDestinations,
                    warnings: &warnings
                ))
            case .unknown:
                warnings.append("Skipped tweak “\(tweak.name)”: unknown injection type.")
            }
        }
        if tweaks.contains(where: { $0.compatibility == .jailbreakOnly }) {
            warnings.append("One or more tweaks are marked jailbreak-only (MobileSubstrate payload). They will almost certainly not run on stock iOS.")
        }
        return InjectionPlan(
            appBundleURL: appBundleURL,
            executablePath: appBundleURL.appendingPathComponent(executable).path,
            items: items,
            warnings: warnings
        )
    }

    // MARK: Execution

    /// Executes a plan built by `plan(...)`: copies each ready item
    /// into the bundle, rewrites non-@rpath dylib install names, and
    /// links each dylib into the main executable. Skipped items are
    /// reported, never executed. Throws on the first copy/link
    /// failure, naming the file and the stage.
    public func execute(_ plan: InjectionPlan) async throws -> InjectionResult {
        var injected: [String] = []
        var skipped: [String] = plan.skippedItems.map {
            "\($0.name): \($0.skipReason ?? "skipped")"
        }
        var warnings = plan.warnings
        for item in plan.readyItems {
            let destination = plan.appBundleURL.appendingPathComponent(item.destinationRelativePath)
            do {
                try Task.checkCancellation()
                try copyItem(from: item.sourceURL, to: destination)
                if item.injectionType == .dylib {
                    if let installName = MachOArchitectures.installName(at: destination),
                       !installName.hasPrefix("@rpath/") {
                        let newName = "@rpath/\(destination.lastPathComponent)"
                        try await backend.changeDylibPath(
                            appExecutable: destination.path, oldPath: installName, newPath: newName
                        )
                    }
                    try await backend.injectDylib(
                        appExecutable: plan.executablePath, dylibPath: "@rpath/\(destination.lastPathComponent)"
                    )
                }
                injected.append(item.destinationRelativePath)
            } catch is CancellationError {
                throw SigningError.cancelled
            } catch let error as SigningError {
                throw SigningError.signingFailed(
                    reason: "Injection failed at file “\(item.name)” (stage: \(item.injectionType == .dylib ? "inject-dylib" : "copy")): \(error.localizedDescription)"
                )
            } catch {
                throw SigningError.signingFailed(
                    reason: "Injection failed at file “\(item.name)” (stage: copy): \(error.localizedDescription)"
                )
            }
        }
        if injected.isEmpty, !plan.readyItems.isEmpty {
            warnings.append("No tweak was injected: every ready item failed or was skipped.")
        }
        return InjectionResult(
            planID: plan.id,
            injected: injected,
            skipped: skipped,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private func item(
        tweak: TweakModel, source: URL, destination: String,
        architectures: [String], status: InjectionItemStatus, reason: String?
    ) -> InjectionItem {
        InjectionItem(
            name: tweak.name, sourceURL: source,
            destinationRelativePath: destination,
            injectionType: tweak.injectionType,
            architectures: architectures, status: status, skipReason: reason
        )
    }

    private func checkedItem(
        tweak: TweakModel, source: URL, destination: String, architectures: [String],
        appBundleURL: URL, seen: inout [String: String]
    ) -> InjectionItem {
        if let first = seen[destination] {
            return item(tweak: tweak, source: source, destination: destination, architectures: architectures,
                        status: .skippedDuplicate,
                        reason: "Duplicate: “\(first)” already injects to \(destination).")
        }
        seen[destination] = tweak.name
        if fileManager.fileExists(atPath: appBundleURL.appendingPathComponent(destination).path) {
            return item(tweak: tweak, source: source, destination: destination, architectures: architectures,
                        status: .skippedConflict,
                        reason: "A file already exists at \(destination) in the app bundle.")
        }
        return item(tweak: tweak, source: source, destination: destination, architectures: architectures,
                    status: .ready, reason: nil)
    }

    /// Duplicate/conflict check for an already-built item (DEB payload
    /// files, whose name is the payload file, not the tweak name).
    private func checkedItemForDeb(
        _ item: InjectionItem, appBundleURL: URL, seen: inout [String: String]
    ) -> InjectionItem {
        var result = item
        if let first = seen[item.destinationRelativePath] {
            result.status = .skippedDuplicate
            result.skipReason = "Duplicate: “\(first)” already injects to \(item.destinationRelativePath)."
            return result
        }
        seen[item.destinationRelativePath] = item.name
        if fileManager.fileExists(atPath: appBundleURL.appendingPathComponent(item.destinationRelativePath).path) {
            result.status = .skippedConflict
            result.skipReason = "A file already exists at \(item.destinationRelativePath) in the app bundle."
            return result
        }
        result.status = .ready
        return result
    }

    /// Destination inside the .app bundle for an injected file.
    private func destinationPath(
        fileName: String, injectPath: InjectionPath, injectFolder: InjectionFolder, kind: InjectionType
    ) -> String {
        switch kind {
        case .framework:
            return "Frameworks/\(fileName)"
        case .bundle:
            return injectFolder == .frameworks ? "Frameworks/\(fileName)" : fileName
        case .dylib, .deb, .unknown:
            switch injectPath {
            case .frameworks: return "Frameworks/\(fileName)"
            case .plugIns: return "PlugIns/\(fileName)"
            case .appRoot: return fileName
            }
        }
    }

    /// Items for a DEB: every injectable payload file under a known
    /// Library path is extracted to the staging directory (a .dylib as
    /// a single file, a .framework/.bundle with its whole directory
    /// tree) and mapped into the bundle; other payload files are
    /// skipped — they belong to the system, not the app bundle.
    /// Only gzip / plain data.tars can be extracted; other
    /// compressions were already reported by `inspectDeb(at:)`.
    private func debItems(
        tweak: TweakModel, source: URL,
        appBundleURL: URL, seen: inout [String: String],
        warnings: inout [String]
    ) throws -> [InjectionItem] {
        let contents = try inspectDeb(at: source)
        guard !contents.payloadFiles.isEmpty else {
            warnings.append(
                "DEB “\(source.lastPathComponent)” could not be listed: " +
                (contents.payloadUnreadableReason ?? "empty payload.")
            )
            return [item(tweak: tweak, source: source, destination: source.lastPathComponent,
                         architectures: [], status: .skippedUnsupported,
                         reason: contents.payloadUnreadableReason ?? "DEB payload could not be read.")]
        }
        guard let tar = readableDataTar(of: source, contents: contents) else {
            warnings.append("DEB “\(source.lastPathComponent)”: \(contents.payloadUnreadableReason ?? "data.tar unreadable.")")
            return [item(tweak: tweak, source: source, destination: source.lastPathComponent,
                         architectures: [], status: .skippedUnsupported,
                         reason: contents.payloadUnreadableReason ?? "data.tar unreadable.")]
        }
        var items: [InjectionItem] = []
        var stagedContainers: Set<String> = []
        for path in contents.payloadFiles {
            let normalized = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            guard let mapped = mapDebPayloadPath(normalized) else { continue }
            let fileName = URL(fileURLWithPath: normalized).lastPathComponent
            // A .framework / .bundle in a tar is a directory: its files
            // appear as entries *under* "Foo.framework/...", never as a
            // single entry. Detect the container root and inject it once.
            if let containerEnd = normalized.range(of: ".framework/")?.upperBound
                ?? normalized.range(of: ".bundle/")?.upperBound {
                let containerPath = String(normalized[..<containerEnd].dropLast())
                if stagedContainers.contains(containerPath) { continue }
                stagedContainers.insert(containerPath)
                let containerName = URL(fileURLWithPath: containerPath).lastPathComponent
                guard let containerMapped = mapDebPayloadPath(containerPath) else { continue }
                let staged = stagingURL.appendingPathComponent("\(tweak.id.uuidString)-\(containerName)")
                do {
                    try extractTarPrefix(containerPath + "/", in: tar, to: staged)
                } catch {
                    warnings.append("DEB “\(source.lastPathComponent)”: could not extract \(containerPath): \(error.localizedDescription)")
                    continue
                }
                guard fileManager.fileExists(atPath: staged.path) else { continue }
                let kind: InjectionType = containerName.hasSuffix(".framework") ? .framework : .bundle
                let containerItem = InjectionItem(
                    name: containerName, sourceURL: staged,
                    destinationRelativePath: containerMapped, injectionType: kind
                )
                items.append(checkedItemForDeb(containerItem, appBundleURL: appBundleURL, seen: &seen))
                continue
            }
            guard fileName.hasSuffix(".dylib") else { continue }
            let staged = stagingURL.appendingPathComponent("\(tweak.id.uuidString)-\(fileName)")
            do {
                guard let bytes = extractTarFile(named: path, in: tar)
                    ?? extractTarFile(named: "./\(path)", in: tar)
                    ?? extractTarFile(named: normalized, in: tar) else { continue }
                try bytes.write(to: staged)
            } catch {
                warnings.append("DEB “\(source.lastPathComponent)”: could not extract \(path): \(error.localizedDescription)")
                continue
            }
            let archs = MachOArchitectures.architectures(at: staged)
            if !archs.isEmpty, !MachOArchitectures.isArm64(archs) {
                items.append(item(tweak: tweak, source: staged, destination: mapped, architectures: archs,
                                  status: .skippedUnsupported,
                                  reason: "Dylib “\(fileName)” in DEB is \(archs.joined(separator: ", ")), not arm64."))
                continue
            }
            let dylibItem = InjectionItem(
                name: fileName, sourceURL: staged, destinationRelativePath: mapped,
                injectionType: .dylib, architectures: archs
            )
            items.append(checkedItemForDeb(dylibItem, appBundleURL: appBundleURL, seen: &seen))
        }
        if items.isEmpty {
            warnings.append("DEB “\(source.lastPathComponent)” contains no injectable .dylib / .framework / .bundle under a known Library path.")
        }
        return items
    }

    /// The uncompressed data.tar bytes of a DEB, when its compression
    /// allows it (gzip via `ArchiveEngine.gunzip`, or plain tar).
    private func readableDataTar(of debURL: URL, contents: DebContents) -> Data? {
        guard let data = try? Data(contentsOf: debURL) else { return nil }
        var offset = 8
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            guard let nameRaw = String(bytes: header[0..<16], encoding: .utf8),
                  let sizeRaw = String(bytes: header[48..<58], encoding: .utf8),
                  let size = Int(sizeRaw.trimmingCharacters(in: .whitespaces)) else { return nil }
            let name = nameRaw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "")
            let bodyStart = offset + 60
            guard bodyStart + size <= data.count else { return nil }
            if name == contents.dataTarMember {
                let body = data.subdata(in: bodyStart..<(bodyStart + size))
                switch contents.dataTarCompression {
                case .gzip: return ArchiveEngine.gunzip(body)
                case .none: return body
                case .xz, .bzip2, .lzma, .zstd, .unknown: return nil
                }
            }
            offset = bodyStart + size + (size % 2)
        }
        return nil
    }

    /// Maps a DEB payload path to a bundle-relative destination, or
    /// nil when the file does not belong inside an .app bundle.
    /// Recognised roots (including jailbreak `var/jb` variants):
    /// Library/Frameworks, Library/MobileSubstrate/DynamicLibraries,
    /// Library/Application Support.
    private func mapDebPayloadPath(_ path: String) -> String? {
        let stripped = path
            .replacingOccurrences(of: "./", with: "")
            .replacingOccurrences(of: "var/jb/", with: "")
            .replacingOccurrences(of: "jb/", with: "")
        if stripped.hasPrefix("Library/Frameworks/") {
            return String(stripped.dropFirst("Library/".count))
        }
        if stripped.hasPrefix("Library/MobileSubstrate/DynamicLibraries/") {
            let file = String(stripped.dropFirst("Library/MobileSubstrate/DynamicLibraries/".count))
            return "Frameworks/\(file)"
        }
        if stripped.hasPrefix("Library/Application Support/") {
            return String(stripped.dropFirst("Library/".count))
        }
        return nil
    }

    private func copyItem(from source: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// CFBundleExecutable from the bundle's Info.plist, if readable.
    func executableName(in appBundleURL: URL) -> String? {
        let plistURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty else { return nil }
        return executable
    }
}
