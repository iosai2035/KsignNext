import Foundation

/// Minimal Mach-O parsing: thin + fat headers, architectures,
/// code-signature presence, load-command free space, encryption.
///
/// Pure Swift, no dependencies. Every read is bounds-checked against
/// the buffer before it happens; a truncated or lying header throws
/// `AppError.ipa(.invalidMachO)` instead of trapping. Only the arm64
/// slice is ever inspected: iOS 16+ devices run arm64 only, and a
/// binary without an arm64 slice cannot be signed for this app.
///
/// Layout facts (Mach-O format, verified against the vendored zsign
/// parser `archo.cpp` which reads the same fields):
/// - fat headers and their arch table are big-endian on disk;
///   thin headers are little-endian on arm64 iOS.
/// - `m_uLoadCommandsFreeSpace` in zsign = `__text` section offset
///   minus (header size + sizeofcmds); signing a binary without an
///   existing LC_CODE_SIGNATURE needs >= 16 free bytes there
///   (`sizeof(codesignature_command)`), or the backend fails with
///   "Can't find free space of LoadCommands for CodeSignature!".
public enum MachOEngine {

    // MARK: - Constants

    private static let mhMagic: UInt32 = 0xfeedface
    private static let mhCigam: UInt32 = 0xcefaedfe
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let mhCigam64: UInt32 = 0xcffaedfe
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatCigam: UInt32 = 0xbebafeca

    private static let cpuArm64: Int32 = 0x0100000C

    private static let lcSegment: UInt32 = 0x1
    private static let lcSegment64: UInt32 = 0x19
    private static let lcCodeSignature: UInt32 = 0x1d
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2c

    private static let codesignatureCommandSize = 16

    // MARK: - Public API

    /// Architectures in a thin or fat Mach-O.
    public static func architectures(of data: Data) throws -> [MachOArchitecture] {
        let slices = try slices(of: data)
        return slices.map { $0.architecture }
    }

    /// True when the arm64 slice (or the thin binary) carries an
    /// LC_CODE_SIGNATURE load command (0x1d). Throws when the data
    /// is not a valid Mach-O or has no arm64 slice.
    public static func hasCodeSignature(data: Data) throws -> Bool {
        let slice = try arm64Slice(of: data)
        return try scanLoadCommands(in: slice) { cmd, _, _ in cmd == lcCodeSignature }
    }

    /// Free bytes between the end of the load commands and the first
    /// section data in the arm64 slice. `nil` when there is no
    /// __text section to measure against. zsign needs >= 16 bytes
    /// when no LC_CODE_SIGNATURE exists yet.
    public static func codeSignatureFreeSpace(data: Data) throws -> Int? {
        let slice = try arm64Slice(of: data)
        guard let textOffset = try textSectionOffset(in: slice) else { return nil }
        let used = slice.headerSize + Int(try slice.sizeofcmds)
        guard textOffset >= used else { return 0 }
        return textOffset - used
    }

    /// True when LC_ENCRYPTION_INFO(_64) reports cryptid >= 1
    /// (an encrypted App Store binary, which cannot be re-signed).
    public static func isEncrypted(data: Data) throws -> Bool {
        let slice = try arm64Slice(of: data)
        return try scanLoadCommands(in: slice) { cmd, commandOffset, commandSize in
            guard cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64 else { return false }
            // encryption_info_command: cmd, cmdsize, cryptoff, cryptsize, cryptid (20 bytes).
            guard commandSize >= 20 else { return false }
            let cryptid = try slice.readUInt32(at: commandOffset + 16)
            return cryptid != 0
        }
    }

    // MARK: - Slice model

    /// One thin Mach-O image inside `data` (the whole buffer for a
    /// thin binary, one arch entry for a fat binary).
    private struct Slice {
        let base: Int        // offset of the slice in `data`
        let length: Int      // slice length in bytes
        let data: Data       // the whole file buffer (reads are offset by `base`)
        let is64Bit: Bool
        let swapped: Bool    // true for CIGAM (big-endian thin) headers
        let architecture: MachOArchitecture

        var headerSize: Int { is64Bit ? 32 : 28 }
        /// sizeofcmds from the Mach-O header.
        var sizeofcmds: UInt32 {
            get throws {
                // mach_header: magic(4) cputype(4) cpusubtype(4) filetype(4)
                //   ncmds(4) sizeofcmds(4) flags(4) [reserved(4) for 64-bit]
                try readUInt32(at: base + 20)
            }
        }
        var ncmds: UInt32 {
            get throws { try readUInt32(at: base + 16) }
        }

        func readUInt32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else {
                throw AppError.ipa(.invalidMachO("Read past the end of the Mach-O file at offset \(offset)."))
            }
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            return swapped ? value.byteSwapped : value
        }

        func readUInt64(at offset: Int) throws -> UInt64 {
            guard offset >= 0, offset + 8 <= data.count else {
                throw AppError.ipa(.invalidMachO("Read past the end of the Mach-O file at offset \(offset)."))
            }
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) }
            return swapped ? value.byteSwapped : value
        }
    }

    // MARK: - Slicing

    private static func slices(of data: Data) throws -> [Slice] {
        guard data.count >= 4 else {
            throw AppError.ipa(.invalidMachO("File is too small to be a Mach-O binary (\(data.count) bytes)."))
        }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case fatMagic, fatCigam:
            // Fat header (big-endian on disk): magic + nfat_arch.
            guard data.count >= 8 else {
                throw AppError.ipa(.invalidMachO("Truncated fat Mach-O header."))
            }
            let nfat = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.bigEndian)
            guard nfat > 0, nfat <= 64 else {
                throw AppError.ipa(.invalidMachO("Unreasonable fat architecture count: \(nfat)."))
            }
            var result: [Slice] = []
            for i in 0..<nfat {
                let entry = 8 + i * 20
                guard entry + 20 <= data.count else {
                    throw AppError.ipa(.invalidMachO("Truncated fat architecture table."))
                }
                let be32: (Int) -> UInt32 = { off in
                    data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian
                }
                let cpuType = Int32(bitPattern: be32(entry))
                let cpuSubtype = Int32(bitPattern: be32(entry + 4))
                let offset = Int(be32(entry + 8))
                let size = Int(be32(entry + 12))
                guard offset >= 0, size >= 4, offset + size <= data.count else {
                    throw AppError.ipa(.invalidMachO("Fat slice \(i) lies outside the file."))
                }
                result.append(try thinSlice(base: offset, length: size, data: data,
                                            cpuType: cpuType, cpuSubtype: cpuSubtype))
            }
            return result
        case mhMagic, mhMagic64, mhCigam, mhCigam64:
            return [try thinSlice(base: 0, length: data.count, data: data, cpuType: nil, cpuSubtype: nil)]
        default:
            throw AppError.ipa(.invalidMachO("Not a Mach-O binary (magic 0x\(String(magic, radix: 16)))."))
        }
    }

    private static func thinSlice(base: Int, length: Int, data: Data,
                                  cpuType: Int32?, cpuSubtype: Int32?) throws -> Slice {
        guard base + 4 <= data.count else {
            throw AppError.ipa(.invalidMachO("Truncated Mach-O header."))
        }
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: base, as: UInt32.self) }
        let is64Bit: Bool
        let swapped: Bool
        switch magic {
        case mhMagic: is64Bit = false; swapped = false
        case mhMagic64: is64Bit = true; swapped = false
        case mhCigam: is64Bit = false; swapped = true
        case mhCigam64: is64Bit = true; swapped = true
        default:
            throw AppError.ipa(.invalidMachO("Not a Mach-O binary (magic 0x\(String(magic, radix: 16)))."))
        }
        let headerSize = is64Bit ? 32 : 28
        guard base + headerSize <= data.count, base + headerSize <= base + length else {
            throw AppError.ipa(.invalidMachO("Truncated Mach-O header."))
        }
        func u32(_ offset: Int) -> UInt32 {
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: base + offset, as: UInt32.self) }
            return swapped ? value.byteSwapped : value
        }
        let type = cpuType ?? Int32(bitPattern: u32(4))
        let subtype = cpuSubtype ?? Int32(bitPattern: u32(8))
        return Slice(base: base, length: length, data: data, is64Bit: is64Bit, swapped: swapped,
                     architecture: MachOArchitecture(cpuType: type, cpuSubtype: subtype, is64Bit: is64Bit))
    }

    private static func arm64Slice(of data: Data) throws -> Slice {
        let all = try slices(of: data)
        guard let slice = all.first(where: { $0.architecture.isArm64 }) else {
            throw AppError.ipa(.invalidMachO("No arm64 slice in this Mach-O binary."))
        }
        return slice
    }

    // MARK: - Load-command scan

    /// Walks the load commands of `slice`, calling `body` for each
    /// command (cmd, absolute file offset, cmdsize). Returns true as
    /// soon as `body` returns true. Every step is bounds-checked.
    private static func scanLoadCommands(in slice: Slice,
                                         body: (UInt32, Int, Int) throws -> Bool) throws -> Bool {
        let ncmds = try slice.ncmds
        guard ncmds <= 10_000 else {
            throw AppError.ipa(.invalidMachO("Unreasonable load-command count: \(ncmds)."))
        }
        let sizeofcmds = try slice.sizeofcmds
        guard slice.headerSize + Int(sizeofcmds) <= slice.length else {
            throw AppError.ipa(.invalidMachO("Load commands run past the end of the Mach-O slice."))
        }
        var offset = slice.base + slice.headerSize
        let end = slice.base + slice.headerSize + Int(sizeofcmds)
        for _ in 0..<ncmds {
            guard offset + 8 <= end, offset + 8 <= slice.data.count else {
                throw AppError.ipa(.invalidMachO("Truncated load command."))
            }
            let cmd = try slice.readUInt32(at: offset)
            let cmdsize = Int(try slice.readUInt32(at: offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= end, offset + cmdsize <= slice.data.count else {
                throw AppError.ipa(.invalidMachO("Load command size \(cmdsize) is out of bounds."))
            }
            if try body(cmd, offset, cmdsize) { return true }
            offset += cmdsize
        }
        return false
    }

    /// File offset of the __text section in the __TEXT segment, or
    /// nil when there is no __text section.
    private static func textSectionOffset(in slice: Slice) throws -> Int? {
        var found: Int?
        _ = try scanLoadCommands(in: slice) { cmd, commandOffset, commandSize in
            guard found == nil else { return true }
            if slice.is64Bit {
                guard cmd == lcSegment64, commandSize >= 72 else { return false }
                let segname = segmentName(data: slice.data, offset: commandOffset + 8)
                guard segname == "__TEXT" else { return false }
                let nsects = Int(try slice.readUInt32(at: commandOffset + 64))
                guard nsects <= 512 else {
                    throw AppError.ipa(.invalidMachO("Unreasonable section count: \(nsects)."))
                }
                for j in 0..<nsects {
                    let sectionOffset = commandOffset + 72 + j * 80
                    guard sectionOffset + 80 <= commandOffset + commandSize,
                          sectionOffset + 80 <= slice.data.count else {
                        throw AppError.ipa(.invalidMachO("Section header runs past its segment command."))
                    }
                    let sectname = segmentName(data: slice.data, offset: sectionOffset)
                    guard sectname == "__text" else { continue }
                    found = Int(try slice.readUInt32(at: sectionOffset + 48))
                    return true
                }
            } else {
                guard cmd == lcSegment, commandSize >= 56 else { return false }
                let segname = segmentName(data: slice.data, offset: commandOffset + 8)
                guard segname == "__TEXT" else { return false }
                let nsects = Int(try slice.readUInt32(at: commandOffset + 48))
                guard nsects <= 512 else {
                    throw AppError.ipa(.invalidMachO("Unreasonable section count: \(nsects)."))
                }
                for j in 0..<nsects {
                    let sectionOffset = commandOffset + 56 + j * 68
                    guard sectionOffset + 68 <= commandOffset + commandSize,
                          sectionOffset + 68 <= slice.data.count else {
                        throw AppError.ipa(.invalidMachO("Section header runs past its segment command."))
                    }
                    let sectname = segmentName(data: slice.data, offset: sectionOffset)
                    guard sectname == "__text" else { continue }
                    found = Int(try slice.readUInt32(at: sectionOffset + 40))
                    return true
                }
            }
            return false
        }
        return found
    }

    /// A 16-byte segment/section name (NUL-padded) as a String.
    private static func segmentName(data: Data, offset: Int) -> String {
        guard offset >= 0, offset + 16 <= data.count else { return "" }
        let bytes = data[offset..<(offset + 16)]
        let trimmed = bytes.prefix(while: { $0 != 0 })
        return String(bytes: trimmed, encoding: .utf8) ?? ""
    }
}
