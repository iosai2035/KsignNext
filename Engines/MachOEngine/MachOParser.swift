import Foundation

// MARK: - Safe data reader

/// Bounds-checked, little-endian reader over Mach-O bytes. Every read
/// verifies `offset + size <= data.count` with overflow-checked arithmetic
/// (`addingReportingOverflow`); any violation throws `IPAError.invalidMachO`
/// instead of trapping. There is no unchecked subscript access anywhere.
public struct MachODataReader {
    public let data: Data
    public private(set) var offset: Int

    public init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset >= data.count }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw IPAError.invalidMachO("Seek to offset \(newOffset) is out of bounds (file size \(data.count)).")
        }
        offset = newOffset
    }

    public mutating func skip(_ count: Int) throws {
        let (next, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, next >= 0, next <= data.count else {
            throw IPAError.invalidMachO("Skip of \(count) bytes at offset \(offset) is out of bounds.")
        }
        offset = next
    }

    private func checkedRange(count: Int) throws -> Range<Int> {
        guard count >= 0 else {
            throw IPAError.invalidMachO("Negative read length \(count).")
        }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, end <= data.count else {
            throw IPAError.invalidMachO("Read of \(count) bytes at offset \(offset) exceeds file size \(data.count).")
        }
        return offset..<end
    }

    public mutating func readUInt8() throws -> UInt8 {
        let range = try checkedRange(count: 1)
        defer { offset = range.upperBound }
        return data[range.lowerBound]
    }

    public mutating func readUInt16() throws -> UInt16 {
        let range = try checkedRange(count: 2)
        defer { offset = range.upperBound }
        return UInt16(data[range.lowerBound]) | (UInt16(data[range.lowerBound + 1]) << 8)
    }

    public mutating func readUInt32() throws -> UInt32 {
        let range = try checkedRange(count: 4)
        defer { offset = range.upperBound }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[range.lowerBound + index]) << (8 * index)
        }
        return value
    }

    public mutating func readUInt64() throws -> UInt64 {
        let range = try checkedRange(count: 8)
        defer { offset = range.upperBound }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[range.lowerBound + index]) << (8 * index)
        }
        return value
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readBytes(count: Int) throws -> Data {
        let range = try checkedRange(count: count)
        defer { offset = range.upperBound }
        return data.subdata(in: range)
    }

    /// Reads a NUL-terminated C string, capped at `maxLength` bytes.
    public mutating func readCString(maxLength: Int = 256) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while bytes.count < maxLength {
            let byte = try readUInt8()
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a fixed-length, possibly NUL-padded string field.
    public mutating func readFixedString(length: Int) throws -> String {
        let bytes = try readBytes(count: length)
        let trimmed = bytes.prefix(while: { $0 != 0 })
        return String(bytes: trimmed, encoding: .utf8) ?? String(decoding: trimmed, as: UTF8.self)
    }

    /// Non-advancing peek at an absolute offset.
    public func peekUInt32(at absoluteOffset: Int) throws -> UInt32 {
        var copy = MachODataReader(data: data, offset: absoluteOffset)
        return try copy.readUInt32()
    }
}

// MARK: - Types

/// One architecture slice of a fat binary.
public struct MachOArchitecture: Equatable {
    public var cpuType: UInt32
    public var cpuSubtype: UInt32
    public var offset: Int64
    public var size: Int64
    public var align: UInt32

    public init(cpuType: UInt32, cpuSubtype: UInt32, offset: Int64, size: Int64, align: UInt32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.offset = offset
        self.size = size
        self.align = align
    }

    /// Human-readable CPU name, e.g. "arm64", "x86_64", "armv7".
    public var cpuTypeName: String {
        MachOParser.cpuTypeName(cpuType, subtype: cpuSubtype)
    }

    public var isARM64: Bool { cpuType == MachOParser.cpuTypeARM64 }
}

/// A single load command (raw header fields plus a short description).
public struct MachOLoadCommand: Equatable {
    public var cmd: UInt32
    public var cmdsize: UInt32
    public var offset: Int
    public var name: String
    /// Human-readable detail (dylib path, RPATH value, version, ...).
    public var detail: String

    public init(cmd: UInt32, cmdsize: UInt32, offset: Int, name: String, detail: String = "") {
        self.cmd = cmd
        self.cmdsize = cmdsize
        self.offset = offset
        self.name = name
        self.detail = detail
    }
}

/// One section inside a segment.
public struct MachOSection: Equatable {
    public var name: String
    public var segmentName: String
    public var address: UInt64
    public var size: UInt64
    public var offset: UInt32
    public var flags: UInt32

    public init(name: String, segmentName: String, address: UInt64, size: UInt64, offset: UInt32, flags: UInt32) {
        self.name = name
        self.segmentName = segmentName
        self.address = address
        self.size = size
        self.offset = offset
        self.flags = flags
    }
}

/// One segment (LC_SEGMENT / LC_SEGMENT_64) and its sections.
public struct MachOSegment: Equatable {
    public var name: String
    public var vmAddress: UInt64
    public var vmSize: UInt64
    public var fileOffset: UInt64
    public var fileSize: UInt64
    public var maxProtection: Int32
    public var initialProtection: Int32
    public var sections: [MachOSection]

    public init(
        name: String, vmAddress: UInt64, vmSize: UInt64, fileOffset: UInt64, fileSize: UInt64,
        maxProtection: Int32, initialProtection: Int32, sections: [MachOSection] = []
    ) {
        self.name = name
        self.vmAddress = vmAddress
        self.vmSize = vmSize
        self.fileOffset = fileOffset
        self.fileSize = fileSize
        self.maxProtection = maxProtection
        self.initialProtection = initialProtection
        self.sections = sections
    }
}

/// A linked dynamic library (LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB).
public struct DylibInfo: Equatable {
    public var name: String
    public var timestamp: UInt32
    public var currentVersion: String
    public var compatibilityVersion: String
    public var isWeak: Bool
    public var isReexport: Bool

    public init(name: String, timestamp: UInt32, currentVersion: String, compatibilityVersion: String, isWeak: Bool = false, isReexport: Bool = false) {
        self.name = name
        self.timestamp = timestamp
        self.currentVersion = currentVersion
        self.compatibilityVersion = compatibilityVersion
        self.isWeak = isWeak
        self.isReexport = isReexport
    }
}

/// Parsed Mach-O file: header fields, one slice's load commands, segments,
/// dylibs, and (for fat files) the list of architecture slices.
public struct MachOFile: Equatable {
    public var isFat: Bool
    public var architectures: [MachOArchitecture]
    /// CPU type of the slice that was actually parsed (first slice for fat).
    public var cpuType: UInt32
    public var cpuSubtype: UInt32
    public var fileType: UInt32
    public var numberOfCommands: UInt32
    public var sizeOfCommands: UInt32
    public var flags: UInt32
    public var loadCommands: [MachOLoadCommand]
    public var segments: [MachOSegment]
    public var dylibs: [DylibInfo]
    public var installName: String?
    public var rpaths: [String]
    public var uuid: String?
    public var minimumOSVersion: String?
    public var sdkVersion: String?
    public var isEncrypted: Bool
    public var encryptionCryptID: UInt32?
    public var hasCodeSignature: Bool
    public var codeSignatureOffset: UInt64?
    public var codeSignatureSize: UInt64?
    /// Byte offset of the parsed slice inside the file (0 for thin files).
    public var sliceOffset: Int64

    public init(
        isFat: Bool = false, architectures: [MachOArchitecture] = [],
        cpuType: UInt32 = 0, cpuSubtype: UInt32 = 0, fileType: UInt32 = 0,
        numberOfCommands: UInt32 = 0, sizeOfCommands: UInt32 = 0, flags: UInt32 = 0,
        loadCommands: [MachOLoadCommand] = [], segments: [MachOSegment] = [],
        dylibs: [DylibInfo] = [], installName: String? = nil, rpaths: [String] = [],
        uuid: String? = nil, minimumOSVersion: String? = nil, sdkVersion: String? = nil,
        isEncrypted: Bool = false, encryptionCryptID: UInt32? = nil,
        hasCodeSignature: Bool = false, codeSignatureOffset: UInt64? = nil,
        codeSignatureSize: UInt64? = nil, sliceOffset: Int64 = 0
    ) {
        self.isFat = isFat
        self.architectures = architectures
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.fileType = fileType
        self.numberOfCommands = numberOfCommands
        self.sizeOfCommands = sizeOfCommands
        self.flags = flags
        self.loadCommands = loadCommands
        self.segments = segments
        self.dylibs = dylibs
        self.installName = installName
        self.rpaths = rpaths
        self.uuid = uuid
        self.minimumOSVersion = minimumOSVersion
        self.sdkVersion = sdkVersion
        self.isEncrypted = isEncrypted
        self.encryptionCryptID = encryptionCryptID
        self.hasCodeSignature = hasCodeSignature
        self.codeSignatureOffset = codeSignatureOffset
        self.codeSignatureSize = codeSignatureSize
        self.sliceOffset = sliceOffset
    }

    public var cpuTypeName: String { MachOParser.cpuTypeName(cpuType, subtype: cpuSubtype) }

    public var fileTypeName: String {
        switch fileType {
        case 0x1: return "MH_OBJECT"
        case 0x2: return "MH_EXECUTE"
        case 0x3: return "MH_FVMLIB"
        case 0x4: return "MH_CORE"
        case 0x5: return "MH_PRELOAD"
        case 0x6: return "MH_DYLIB"
        case 0x7: return "MH_DYLINKER"
        case 0x8: return "MH_BUNDLE"
        case 0x9: return "MH_DYLIB_STUB"
        case 0xA: return "MH_DSYM"
        case 0xB: return "MH_KEXT_BUNDLE"
        default: return "unknown(0x\(String(fileType, radix: 16)))"
        }
    }

    public var isARM64: Bool { cpuType == MachOParser.cpuTypeARM64 }
}

// MARK: - Parser

/// Low-level Mach-O parser. Reads only header + load-command bytes; it
/// never scans the file as text for dylib names — every string comes from
/// a load command's offset field, bounds-checked against the command size.
public enum MachOParser {

    // Magic numbers (as stored in the file, little-endian read).
    public static let magic32: UInt32 = 0xFEEDFACE
    public static let magic64: UInt32 = 0xFEEDFACF
    public static let magicFat: UInt32 = 0xCAFEBABE
    public static let magicFatReverse: UInt32 = 0xBEBAFECA
    public static let magic32Reverse: UInt32 = 0xCEFAEDFE
    public static let magic64Reverse: UInt32 = 0xCFFAEDFE

    // CPU types.
    public static let cpuTypeARM64: UInt32 = 0x0100000C
    public static let cpuTypeX86_64: UInt32 = 0x01000007
    public static let cpuTypeARM: UInt32 = 0x0000000C
    public static let cpuTypeX86: UInt32 = 0x00000007

    // Load-command ids.
    public static let lcSegment: UInt32 = 0x1
    public static let lcSymtab: UInt32 = 0x2
    public static let lcDyldInfoOnly: UInt32 = 0x22
    public static let lcLoadDylib: UInt32 = 0xC
    public static let lcIdDylib: UInt32 = 0xD
    public static let lcLoadDylinker: UInt32 = 0xE
    public static let lcUUID: UInt32 = 0x1B
    public static let lcCodeSignature: UInt32 = 0x1D
    public static let lcSegment64: UInt32 = 0x19
    public static let lcEncryptionInfo: UInt32 = 0x21
    public static let lcEncryptionInfo64: UInt32 = 0x2C
    public static let lcLoadWeakDylib: UInt32 = 0x18
    public static let lcRpath: UInt32 = 0x1C
    public static let lcReexportDylib: UInt32 = 0x1F
    public static let lcDyldInfo: UInt32 = 0x22
    public static let lcLoadUpwardDylib: UInt32 = 0x23
    public static let lcBuildVersion: UInt32 = 0x32
    public static let lcMinVersionIOS: UInt32 = 0x24
    public static let lcVersionMinMacOSX: UInt32 = 0x24
    public static let lcFunctionStarts: UInt32 = 0x26
    public static let lcMain: UInt32 = 0x28

    /// Parses Mach-O `data`. For a fat binary the first slice is parsed in
    /// full and the other slices are listed in `architectures`.
    /// When `allowTruncatedHeader` is true (validation fast-path, where only
    /// the first 4 KB of an executable were read), load commands that run
    /// past the available bytes are skipped instead of throwing, and the
    /// returned file reports only what could be read.
    public static func parse(data: Data, allowTruncatedHeader: Bool = false) throws -> MachOFile {
        guard data.count >= 4 else {
            throw IPAError.invalidMachO("File is too small to be a Mach-O binary (\(data.count) bytes).")
        }
        var reader = MachODataReader(data: data)
        let magic = try reader.readUInt32()
        switch magic {
        case magicFat, magicFatReverse:
            return try parseFat(data: data, isByteSwapped: magic == magicFatReverse, allowTruncatedHeader: allowTruncatedHeader)
        case magic64, magic64Reverse:
            return try parseThin(data: data, is64Bit: true, isByteSwapped: magic == magic64Reverse, sliceOffset: 0, allowTruncatedHeader: allowTruncatedHeader)
        case magic32, magic32Reverse:
            return try parseThin(data: data, is64Bit: false, isByteSwapped: magic == magic32Reverse, sliceOffset: 0, allowTruncatedHeader: allowTruncatedHeader)
        default:
            throw IPAError.invalidMachO("Unknown magic 0x\(String(magic, radix: 16)).")
        }
    }

    // MARK: Fat

    private static func parseFat(data: Data, isByteSwapped: Bool, allowTruncatedHeader: Bool) throws -> MachOFile {
        var reader = MachODataReader(data: data, offset: 4)
        let count = try reader.readUInt32()
        let swappedCount = isByteSwapped ? count.byteSwapped : count
        guard swappedCount > 0, swappedCount <= 16 else {
            throw IPAError.invalidMachO("Fat binary has an implausible architecture count \(swappedCount).")
        }
        var architectures: [MachOArchitecture] = []
        for _ in 0..<swappedCount {
            let cpuTypeRaw = try reader.readUInt32()
            let cpuSubtypeRaw = try reader.readUInt32()
            let offsetRaw = try reader.readUInt32()
            let sizeRaw = try reader.readUInt32()
            let alignRaw = try reader.readUInt32()
            let cpuType = isByteSwapped ? cpuTypeRaw.byteSwapped : cpuTypeRaw
            let cpuSubtype = isByteSwapped ? cpuSubtypeRaw.byteSwapped : cpuSubtypeRaw
            let sliceOffset = Int64(isByteSwapped ? offsetRaw.byteSwapped : offsetRaw)
            let sliceSize = Int64(isByteSwapped ? sizeRaw.byteSwapped : sizeRaw)
            let align = isByteSwapped ? alignRaw.byteSwapped : alignRaw
            guard sliceOffset >= 0, sliceSize >= 0,
                  sliceOffset <= Int64(data.count),
                  sliceOffset + sliceSize <= Int64(data.count) || allowTruncatedHeader else {
                throw IPAError.invalidMachO("Fat slice at offset \(sliceOffset) size \(sliceSize) is out of bounds.")
            }
            architectures.append(MachOArchitecture(
                cpuType: cpuType, cpuSubtype: cpuSubtype,
                offset: sliceOffset, size: sliceSize, align: align
            ))
        }
        guard let first = architectures.first else {
            throw IPAError.invalidMachO("Fat binary has no architectures.")
        }
        // Parse the first slice (prefer arm64 when present and fully available).
        let preferred = architectures.first(where: { $0.isARM64 && $0.offset + $0.size <= Int64(data.count) }) ?? first
        let sliceData: Data
        if preferred.offset == 0 && preferred.size == Int64(data.count) {
            sliceData = data
        } else if preferred.offset + preferred.size <= Int64(data.count) {
            sliceData = data.subdata(in: Int(preferred.offset)..<Int(preferred.offset + preferred.size))
        } else if allowTruncatedHeader {
            let available = max(0, data.count - Int(preferred.offset))
            sliceData = data.subdata(in: Int(preferred.offset)..<(Int(preferred.offset) + available))
        } else {
            throw IPAError.invalidMachO("Fat slice data is out of bounds.")
        }
        var file = try parseThin(data: sliceData, is64Bit: true, isByteSwapped: false, sliceOffset: preferred.offset, allowTruncatedHeader: allowTruncatedHeader)
        // parseThin guessed 64-bit; re-parse as 32-bit if the magic says so.
        if sliceData.count >= 4 {
            var magicReader = MachODataReader(data: sliceData)
            if let firstMagic = try? magicReader.readUInt32(), firstMagic == magic32 {
                file = try parseThin(data: sliceData, is64Bit: false, isByteSwapped: false, sliceOffset: preferred.offset, allowTruncatedHeader: allowTruncatedHeader)
            }
        }
        file.isFat = true
        file.architectures = architectures
        return file
    }

    // MARK: Thin

    private static func parseThin(data: Data, is64Bit: Bool, isByteSwapped: Bool, sliceOffset: Int64, allowTruncatedHeader: Bool) throws -> MachOFile {
        guard data.count >= (is64Bit ? 32 : 28) else {
            if allowTruncatedHeader, data.count >= 4 {
                return MachOFile(isFat: false, sliceOffset: sliceOffset)
            }
            throw IPAError.invalidMachO("Mach-O header is truncated (\(data.count) bytes).")
        }
        var reader = MachODataReader(data: data, offset: 4)
        func next32() throws -> UInt32 {
            let raw = try reader.readUInt32()
            return isByteSwapped ? raw.byteSwapped : raw
        }
        let cpuType = try next32()
        let cpuSubtype = try next32()
        let fileType = try next32()
        let ncmds = try next32()
        let sizeofcmds = try next32()
        let flags = try next32()
        if !is64Bit {
            // 32-bit header ends here; there is no reserved field.
        } else {
            _ = try next32() // reserved
        }
        guard ncmds <= 512 else {
            throw IPAError.invalidMachO("Implausible load-command count \(ncmds).")
        }
        // A truncated header is only tolerated when the caller allows it.
        guard sizeofcmds <= UInt32(data.count) || allowTruncatedHeader else {
            throw IPAError.invalidMachO("Load commands size \(sizeofcmds) exceeds file size.")
        }

        var file = MachOFile(
            isFat: false,
            cpuType: cpuType, cpuSubtype: cpuSubtype, fileType: fileType,
            numberOfCommands: ncmds, sizeOfCommands: sizeofcmds, flags: flags,
            sliceOffset: sliceOffset
        )

        let commandsStart = reader.offset
        let (commandsEnd, overflow) = commandsStart.addingReportingOverflow(Int(sizeofcmds))
        guard !overflow else {
            throw IPAError.invalidMachO("Load-command region overflows.")
        }
        let effectiveEnd = min(commandsEnd, data.count)

        var commandOffset = commandsStart
        for _ in 0..<ncmds {
            guard commandOffset + 8 <= effectiveEnd else {
                if allowTruncatedHeader { break }
                throw IPAError.invalidMachO("Load command at offset \(commandOffset) is truncated.")
            }
            var commandReader = MachODataReader(data: data, offset: commandOffset)
            let cmdRaw = try commandReader.readUInt32()
            let cmdsizeRaw = try commandReader.readUInt32()
            let cmd = isByteSwapped ? cmdRaw.byteSwapped : cmdRaw
            let cmdsize = isByteSwapped ? cmdsizeRaw.byteSwapped : cmdsizeRaw
            guard cmdsize >= 8 else {
                if allowTruncatedHeader { break }
                throw IPAError.invalidMachO("Load command at offset \(commandOffset) has invalid size \(cmdsize).")
            }
            let (nextOffset, nextOverflow) = commandOffset.addingReportingOverflow(Int(cmdsize))
            guard !nextOverflow, nextOffset <= effectiveEnd || allowTruncatedHeader else {
                if allowTruncatedHeader { break }
                throw IPAError.invalidMachO("Load command at offset \(commandOffset) runs past the command region.")
            }
            let commandEnd = min(nextOffset, data.count)
            let command = try parseLoadCommand(
                data: data, cmd: cmd, cmdsize: cmdsize, offset: commandOffset,
                end: commandEnd, is64Bit: is64Bit, file: &file,
                allowTruncatedHeader: allowTruncatedHeader
            )
            file.loadCommands.append(command)
            commandOffset = nextOffset
        }
        return file
    }

    // MARK: Load commands

    private static func parseLoadCommand(
        data: Data, cmd: UInt32, cmdsize: UInt32, offset: Int, end: Int,
        is64Bit: Bool, file: inout MachOFile, allowTruncatedHeader: Bool
    ) throws -> MachOLoadCommand {
        func string(at stringOffset: Int, within commandEnd: Int) throws -> String {
            guard stringOffset >= 8, offset + stringOffset < commandEnd else {
                throw IPAError.invalidMachO("String offset \(stringOffset) in load command at \(offset) is out of bounds.")
            }
            var reader = MachODataReader(data: data, offset: offset + stringOffset)
            let maxLength = commandEnd - (offset + stringOffset)
            return try reader.readCString(maxLength: maxLength)
        }
        func versionString(_ raw: UInt32) -> String {
            let major = (raw >> 16) & 0xFFFF
            let minor = (raw >> 8) & 0xFF
            let patch = raw & 0xFF
            return "\(major).\(minor).\(patch)"
        }

        switch cmd {
        case lcSegment, lcSegment64:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let segmentName = try reader.readFixedString(length: 16)
            let vmaddr: UInt64
            let vmsize: UInt64
            let fileoff: UInt64
            let filesize: UInt64
            let maxprot: Int32
            let initprot: Int32
            let nsects: UInt32
            if cmd == lcSegment64 {
                vmaddr = try reader.readUInt64()
                vmsize = try reader.readUInt64()
                fileoff = try reader.readUInt64()
                filesize = try reader.readUInt64()
                maxprot = try reader.readInt32()
                initprot = try reader.readInt32()
                nsects = try reader.readUInt32()
                _ = try reader.readUInt32() // flags
            } else {
                vmaddr = UInt64(try reader.readUInt32())
                vmsize = UInt64(try reader.readUInt32())
                fileoff = UInt64(try reader.readUInt32())
                filesize = UInt64(try reader.readUInt32())
                maxprot = try reader.readInt32()
                initprot = try reader.readInt32()
                nsects = try reader.readUInt32()
                _ = try reader.readUInt32() // flags
            }
            guard nsects <= 256 else {
                throw IPAError.invalidMachO("Segment \(segmentName) claims \(nsects) sections.")
            }
            var segment = MachOSegment(
                name: segmentName, vmAddress: vmaddr, vmSize: vmsize,
                fileOffset: fileoff, fileSize: filesize,
                maxProtection: maxprot, initialProtection: initprot
            )
            for _ in 0..<nsects {
                guard reader.offset + (is64Bit ? 80 : 68) <= end else {
                    if allowTruncatedHeader { break }
                    throw IPAError.invalidMachO("Section header in segment \(segmentName) is truncated.")
                }
                let sectionName = try reader.readFixedString(length: 16)
                let sectionSegment = try reader.readFixedString(length: 16)
                let address: UInt64
                let size: UInt64
                let sectionOffset: UInt32
                let flags: UInt32
                if is64Bit {
                    address = try reader.readUInt64()
                    size = try reader.readUInt64()
                    sectionOffset = try reader.readUInt32()
                    _ = try reader.readUInt32() // align
                    _ = try reader.readUInt32() // reloff
                    _ = try reader.readUInt32() // nreloc
                    flags = try reader.readUInt32()
                    _ = try reader.readUInt32() // reserved1
                    _ = try reader.readUInt32() // reserved2
                    _ = try reader.readUInt32() // reserved3
                } else {
                    address = UInt64(try reader.readUInt32())
                    size = UInt64(try reader.readUInt32())
                    sectionOffset = try reader.readUInt32()
                    _ = try reader.readUInt32() // align
                    _ = try reader.readUInt32() // reloff
                    _ = try reader.readUInt32() // nreloc
                    flags = try reader.readUInt32()
                    _ = try reader.readUInt32() // reserved1
                    _ = try reader.readUInt32() // reserved2
                }
                segment.sections.append(MachOSection(
                    name: sectionName, segmentName: sectionSegment,
                    address: address, size: size, offset: sectionOffset, flags: flags
                ))
            }
            file.segments.append(segment)
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: cmd == lcSegment64 ? "LC_SEGMENT_64" : "LC_SEGMENT", detail: segmentName)

        case lcLoadDylib, lcIdDylib, lcLoadWeakDylib, lcReexportDylib, lcLoadUpwardDylib:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let nameOffset = try reader.readUInt32()
            let timestamp = try reader.readUInt32()
            let currentVersion = try reader.readUInt32()
            let compatVersion = try reader.readUInt32()
            let name = try string(at: Int(nameOffset), within: end)
            let isWeak = cmd == lcLoadWeakDylib
            let isReexport = cmd == lcReexportDylib
            let info = DylibInfo(
                name: name, timestamp: timestamp,
                currentVersion: versionString(currentVersion),
                compatibilityVersion: versionString(compatVersion),
                isWeak: isWeak, isReexport: isReexport
            )
            if cmd == lcIdDylib {
                file.installName = name
            } else {
                file.dylibs.append(info)
            }
            let commandName: String
            switch cmd {
            case lcLoadDylib: commandName = "LC_LOAD_DYLIB"
            case lcIdDylib: commandName = "LC_ID_DYLIB"
            case lcLoadWeakDylib: commandName = "LC_LOAD_WEAK_DYLIB"
            case lcReexportDylib: commandName = "LC_REEXPORT_DYLIB"
            default: commandName = "LC_LOAD_UPWARD_DYLIB"
            }
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: commandName, detail: name)

        case lcRpath:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let pathOffset = try reader.readUInt32()
            let path = try string(at: Int(pathOffset), within: end)
            file.rpaths.append(path)
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_RPATH", detail: path)

        case lcUUID:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let bytes = try reader.readBytes(count: 16)
            let uuid = bytes.map { String(format: "%02x", $0) }.joined()
            let formatted = "\(uuid.prefix(8))-\(uuid.dropFirst(8).prefix(4))-\(uuid.dropFirst(12).prefix(4))-\(uuid.dropFirst(16).prefix(4))-\(uuid.dropFirst(20))"
            file.uuid = formatted
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_UUID", detail: formatted)

        case lcCodeSignature:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let dataOffset = try reader.readUInt32()
            let dataSize = try reader.readUInt32()
            file.hasCodeSignature = true
            file.codeSignatureOffset = UInt64(dataOffset)
            file.codeSignatureSize = UInt64(dataSize)
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_CODE_SIGNATURE", detail: "offset=\(dataOffset) size=\(dataSize)")

        case lcEncryptionInfo, lcEncryptionInfo64:
            var reader = MachODataReader(data: data, offset: offset + 8)
            _ = try reader.readUInt32() // cryptoff
            _ = try reader.readUInt32() // cryptsize
            let cryptID = try reader.readUInt32()
            file.encryptionCryptID = cryptID
            file.isEncrypted = cryptID != 0
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: cmd == lcEncryptionInfo64 ? "LC_ENCRYPTION_INFO_64" : "LC_ENCRYPTION_INFO", detail: "cryptid=\(cryptID)")

        case lcBuildVersion:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let platform = try reader.readUInt32()
            let minOS = try reader.readUInt32()
            let sdk = try reader.readUInt32()
            let ntools = try reader.readUInt32()
            _ = ntools
            file.minimumOSVersion = versionString(minOS)
            file.sdkVersion = versionString(sdk)
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_BUILD_VERSION", detail: "platform=\(platform) minos=\(versionString(minOS)) sdk=\(versionString(sdk))")

        case lcMinVersionIOS:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let version = try reader.readUInt32()
            let sdk = try reader.readUInt32()
            file.minimumOSVersion = versionString(version)
            file.sdkVersion = versionString(sdk)
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_VERSION_MIN_IPHONEOS", detail: "minos=\(versionString(version)) sdk=\(versionString(sdk))")

        case lcMain:
            var reader = MachODataReader(data: data, offset: offset + 8)
            let entryoff = try reader.readUInt64()
            _ = try reader.readUInt64() // stacksize
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_MAIN", detail: "entryoff=\(entryoff)")

        default:
            return MachOLoadCommand(cmd: cmd, cmdsize: cmdsize, offset: offset, name: "LC_0x\(String(cmd, radix: 16))", detail: "")
        }
    }

    // MARK: - CPU names

    public static func cpuTypeName(_ cpuType: UInt32, subtype: UInt32) -> String {
        switch cpuType {
        case cpuTypeARM64:
            return subtype == 2 ? "arm64e" : "arm64"
        case cpuTypeX86_64:
            return "x86_64"
        case cpuTypeARM:
            switch subtype {
            case 9: return "armv7"
            case 11: return "armv7s"
            case 12: return "armv7k"
            default: return "arm"
            }
        case cpuTypeX86:
            return "i386"
        default:
            return "cpu(0x\(String(cpuType, radix: 16)))"
        }
    }
}
