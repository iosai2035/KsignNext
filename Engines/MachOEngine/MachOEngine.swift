import Foundation

/// High-level Mach-O inspection engine built on `MachOParser`.
///
/// Reads Mach-O binaries from disk (or from in-memory bytes, e.g. an entry
/// read out of an IPA) and answers the questions the signing / inspection
/// UI needs: architectures, linked dylibs, RPATHs, UUID, minimum OS / SDK,
/// encryption (FairPlay `cryptid`), and whether a code-signature load
/// command exists. All parsing is bounds-checked in `MachOParser`; this
/// class only adds file I/O and convenience queries.
public final class MachOEngine {

    /// Maximum Mach-O file size this engine will load into memory.
    public static let maxMachOSize: Int64 = 2 * 1024 * 1024 * 1024

    public init() {}

    // MARK: - Parsing

    /// Parses the Mach-O binary at `url`.
    public func parseMachO(at url: URL) throws -> MachOFile {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        if let size = attributes[.size] as? NSNumber, size.int64Value > Self.maxMachOSize {
            throw IPAError.sizeLimitExceeded(limit: Self.maxMachOSize, actual: size.int64Value)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw IPAError.ioError("Cannot read Mach-O file \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try parseMachO(data: data)
    }

    /// Parses Mach-O `data` (thin or fat).
    public func parseMachO(data: Data) throws -> MachOFile {
        try MachOParser.parse(data: data)
    }

    /// Parses only the header of a Mach-O binary (first `headerBytes` of
    /// the file). Used by IPA validation, which reads just the first 4 KB
    /// of an executable out of the archive.
    public func parseHeader(at url: URL, headerBytes: Int = 4096) throws -> MachOFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: headerBytes) else {
            throw IPAError.invalidMachO("Cannot read Mach-O header of \(url.lastPathComponent).")
        }
        return try MachOParser.parse(data: data, allowTruncatedHeader: true)
    }

    // MARK: - Queries

    /// Architecture names of every slice, e.g. `["arm64"]` or `["arm64", "x86_64"]`.
    public func architectures(of file: MachOFile) -> [String] {
        if file.isFat {
            return file.architectures.map(\.cpuTypeName)
        }
        return [file.cpuTypeName]
    }

    /// True when every slice is arm64 / arm64e (the only architectures
    /// that can run on a modern iPhone).
    public func isARM64Only(_ file: MachOFile) -> Bool {
        if file.isFat {
            return !file.architectures.isEmpty && file.architectures.allSatisfy(\.isARM64)
        }
        return file.isARM64
    }

    /// True when the binary contains any non-arm64 slice.
    public func hasNonARM64Slice(_ file: MachOFile) -> Bool {
        if file.isFat {
            return file.architectures.contains { !$0.isARM64 }
        }
        return !file.isARM64
    }

    /// Linked dynamic libraries (LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB /
    /// LC_REEXPORT_DYLIB), as `DylibInfo` values — never by text search.
    public func linkedDylibs(of file: MachOFile) -> [DylibInfo] {
        file.dylibs
    }

    /// Linked library paths only.
    public func linkedLibraryPaths(of file: MachOFile) -> [String] {
        file.dylibs.map(\.name)
    }

    /// RPATH entries (LC_RPATH).
    public func rpaths(of file: MachOFile) -> [String] {
        file.rpaths
    }

    /// Segment names, e.g. `["__TEXT", "__DATA", "__LINKEDIT"]`.
    public func segmentNames(of file: MachOFile) -> [String] {
        file.segments.map(\.name)
    }

    /// Sections of a named segment, or all sections when `segmentName` is nil.
    public func sections(of file: MachOFile, inSegment segmentName: String? = nil) -> [MachOSection] {
        if let segmentName {
            return file.segments.first(where: { $0.name == segmentName })?.sections ?? []
        }
        return file.segments.flatMap(\.sections)
    }

    /// True when the binary is FairPlay-encrypted (`cryptid != 0` in
    /// LC_ENCRYPTION_INFO_64). Encrypted binaries cannot be re-signed
    /// without the original decryption; callers must surface this.
    public func isEncrypted(_ file: MachOFile) -> Bool {
        file.isEncrypted
    }

    /// True when a LC_CODE_SIGNATURE load command is present.
    public func hasCodeSignature(_ file: MachOFile) -> Bool {
        file.hasCodeSignature
    }

    /// Minimum OS / SDK from LC_BUILD_VERSION or LC_VERSION_MIN_IPHONEOS.
    public func minimumOSVersion(of file: MachOFile) -> String? {
        file.minimumOSVersion
    }

    public func sdkVersion(of file: MachOFile) -> String? {
        file.sdkVersion
    }

    /// UUID of the parsed slice (LC_UUID), if present.
    public func uuid(of file: MachOFile) -> String? {
        file.uuid
    }

    /// Install name (LC_ID_DYLIB), for dylibs / frameworks.
    public func installName(of file: MachOFile) -> String? {
        file.installName
    }

    // MARK: - Per-slice parsing (fat binaries)

    /// Parses every slice of a fat binary at `url` and returns one
    /// `MachOFile` per slice (each with `sliceOffset` set).
    public func parseAllSlices(at url: URL) throws -> [MachOFile] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        return try parseAllSlices(data: data)
    }

    /// Parses every slice of a fat binary from in-memory `data`.
    public func parseAllSlices(data: Data) throws -> [MachOFile] {
        let topLevel = try MachOParser.parse(data: data)
        guard topLevel.isFat else { return [topLevel] }
        var results: [MachOFile] = []
        for architecture in topLevel.architectures {
            let start = Int(architecture.offset)
            let end = Int(architecture.offset + architecture.size)
            guard start >= 0, end <= data.count, end >= start else {
                throw IPAError.invalidMachO("Fat slice at offset \(architecture.offset) is out of bounds.")
            }
            let sliceData = data.subdata(in: start..<end)
            let parsed = try MachOParser.parse(data: sliceData)
            var withOffset = parsed
            withOffset.sliceOffset = architecture.offset
            withOffset.isFat = false
            withOffset.architectures = [architecture]
            results.append(withOffset)
        }
        return results
    }

    /// Parses the arm64 slice of a fat binary, or the thin binary as-is.
    public func parseARM64Slice(data: Data) throws -> MachOFile {
        let topLevel = try MachOParser.parse(data: data)
        guard topLevel.isFat else { return topLevel }
        guard let arm64 = topLevel.architectures.first(where: \.isARM64) else {
            throw IPAError.invalidMachO("Fat binary has no arm64 slice.")
        }
        let start = Int(arm64.offset)
        let end = Int(arm64.offset + arm64.size)
        guard start >= 0, end <= data.count, end >= start else {
            throw IPAError.invalidMachO("arm64 slice is out of bounds.")
        }
        var parsed = try MachOParser.parse(data: data.subdata(in: start..<end))
        parsed.sliceOffset = arm64.offset
        parsed.isFat = true
        parsed.architectures = topLevel.architectures
        return parsed
    }
}

// MARK: - MachOEngineProtocol conformance (coordinator integration)

/// Adapts the concrete `MachOFile`-based API to the Domain protocol,
/// which works in URLs and `MachOInfo` values. The overloads below take
/// a URL where the class methods take a `MachOFile`; Swift resolves
/// them by parameter type.
extension MachOEngine: MachOEngineProtocol {
    public func inspect(_ url: URL) async throws -> MachOInfo {
        let file = try parseMachO(at: url)
        return MachOInfo(
            cpuType: file.architectures.first?.cpuTypeName ?? "arm64",
            cpuSubtype: "",
            is64Bit: true,
            isFat: file.isFat,
            architectures: architectures(of: file),
            uuid: file.uuid,
            linkedLibraries: linkedLibraryPaths(of: file),
            rpaths: rpaths(of: file),
            hasCodeSignature: file.hasCodeSignature,
            minimumOSVersion: file.minimumOSVersion,
            sdkVersion: file.sdkVersion,
            segments: segmentNames(of: file),
            isEncrypted: file.isEncrypted
        )
    }

    public func architectures(of url: URL) async throws -> [String] {
        architectures(of: try parseMachO(at: url))
    }

    public func dependencies(of url: URL) async throws -> [String] {
        linkedLibraryPaths(of: try parseMachO(at: url))
    }

    public func isEncrypted(_ url: URL) async throws -> Bool {
        try parseMachO(at: url).isEncrypted
    }

    public func uuid(of url: URL) async throws -> String? {
        try parseMachO(at: url).uuid
    }
}
