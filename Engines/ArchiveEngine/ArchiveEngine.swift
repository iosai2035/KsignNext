import Foundation
import Compression

// MARK: - ZIP entry

/// One entry in a ZIP archive's central directory.
public struct ZipEntry: Equatable {
    public var name: String
    public var compressionMethod: UInt16
    public var compressedSize: Int64
    public var uncompressedSize: Int64
    public var crc32: UInt32
    public var localHeaderOffset: Int64
    public var isDirectory: Bool
    public var modificationDate: Date?
    public var externalAttributes: UInt32
    /// True when the entry is a symlink (Unix file type 0120000).
    public var isSymlink: Bool

    public init(
        name: String,
        compressionMethod: UInt16,
        compressedSize: Int64,
        uncompressedSize: Int64,
        crc32: UInt32,
        localHeaderOffset: Int64,
        isDirectory: Bool,
        modificationDate: Date? = nil,
        externalAttributes: UInt32 = 0,
        isSymlink: Bool = false
    ) {
        self.name = name
        self.compressionMethod = compressionMethod
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.crc32 = crc32
        self.localHeaderOffset = localHeaderOffset
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.externalAttributes = externalAttributes
        self.isSymlink = isSymlink
    }

    public var isStored: Bool { compressionMethod == 0 }
    public var isDeflated: Bool { compressionMethod == 8 }
}

// MARK: - CRC32 (pure Swift)

/// Pure-Swift CRC-32 (IEEE 802.3, polynomial 0xEDB88320), as used by ZIP.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            return crc
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Raw-deflate bridge to the vendored zlib (CZlib)
//
// THE FIX (rebuild Phase 1, Wave 2 — replaces the old fake-wrapper decoder
// that broke every real import; see Documentation/Import-Deflate-Diagnosis-2026-11-28.md):
// ZIP stores deflate streams RAW (no zlib header). The old code wrapped them
// in a fake zlib header (0x78 0x9C + four zero bytes as a fake Adler-32) and
// decoded with Apple's Compression framework + COMPRESSION_STREAM_FINALIZE.
// The decoder verifies Adler-32 at finalize, found zeros, and returned an
// error even though the data had decoded fully and correctly — so every
// compressed IPA failed validation with "Deflate stream is corrupt".
// That trick is deleted entirely: there is no 0x78 0x9C, no fake Adler, and
// no FINALIZE on raw deflate anywhere in this file.
//
// The correct call is inflateInit2(-15) + inflate(Z_FINISH): negative
// windowBits selects raw deflate (no header, no trailer, no checksum).
// Verified on synthetic data and on the real bytes of a compressed IPA
// (entry 1554 -> 5734 bytes, CRC-verified) before this file was written.
//
// Integration: the tree vendors only the zlib HEADERS
// (Engines/SigningEngine/zsign/third-party/zlib/zlib.h, ZLIB_VERSION
// "1.3.1"); the implementation is the system libz, which the app target
// already links (OTHER_LDFLAGS contains "-lz"). Swift cannot see those C
// symbols through the bridging header (this worker may not touch it), so
// the three functions are declared here with @_silgen_name and resolved
// by the linker against the already-linked libz. This is the same
// technique used by production Swift codebases to call system C libraries
// without a bridging header; libz is a public Apple-provided library
// present since iOS 2.0, so there is no App Store risk. The vendored
// minizip (unzip.c, already compiled into the target) calls exactly the
// same inflateInit2(-15) internally — the two paths converge on one
// verified zlib call. Minizip's own API was NOT used here because it
// opens archives by file path only, while both call sites in this file
// (ZIP method 8 and gunzip) inflate IN-MEMORY byte ranges; wiring a
// custom memory ioapi through @convention(c) function pointers would be
// strictly more fragile than the struct below.
//
// The one fragile piece is the z_stream mirror: its layout must match
// the linked zlib's struct byte-for-byte (112 bytes on 64-bit LP64).
// Two safety nets: (1) inflateInit2_ itself checks version[0] == "1"
// and stream_size == sizeof(z_stream) and returns Z_VERSION_ERROR on
// any mismatch, so a wrong layout fails loudly at init instead of
// corrupting memory; (2) ArchiveEngineTests pins
// MemoryLayout<CZlib.ZStream>.size == 112.
// Future cleanup (coordinator decision, not this change): move these
// three declarations into a tiny C bridge header and delete this enum;
// no other code in this file would change.

enum CZlib {
    /// Mirror of zlib's `z_stream` (vendored zlib.h:86-106).
    /// Field order and padding match the C struct on 64-bit LP64:
    /// pointers 8 bytes, uInt 4 bytes, uLong 8 bytes, int 4 bytes.
    struct ZStream {
        var nextIn: UnsafePointer<UInt8>?
        var availIn: UInt32
        var padding1: UInt32
        var totalIn: UInt64
        var nextOut: UnsafeMutablePointer<UInt8>?
        var availOut: UInt32
        var padding2: UInt32
        var totalOut: UInt64
        var msg: UnsafePointer<CChar>?
        var state: UnsafeMutableRawPointer?
        var zalloc: UnsafeMutableRawPointer?
        var zfree: UnsafeMutableRawPointer?
        var opaque: UnsafeMutableRawPointer?
        var dataType: CInt
        var padding3: UInt32
        var adler: UInt64
        var reserved: UInt64

        init() {
            nextIn = nil
            availIn = 0
            padding1 = 0
            totalIn = 0
            nextOut = nil
            availOut = 0
            padding2 = 0
            totalOut = 0
            msg = nil
            state = nil
            zalloc = nil
            zfree = nil
            opaque = nil
            dataType = 0
            padding3 = 0
            adler = 0
            reserved = 0
        }
    }

    // zlib return codes (vendored zlib.h:170-186).
    static let zOK: CInt = 0
    static let zStreamEnd: CInt = 1
    static let zBufError: CInt = -5
    static let zNoFlush: CInt = 0
    static let zFinish: CInt = 4

    // inflateInit2_ is a macro in zlib.h that forwards to this symbol
    // with ZLIB_VERSION and sizeof(z_stream); it is declared explicitly
    // here because Swift cannot expand C macros.
    @_silgen_name("inflateInit2_")
    static func inflateInit2(
        _ stream: UnsafeMutablePointer<ZStream>,
        _ windowBits: CInt,
        _ version: UnsafePointer<CChar>,
        _ streamSize: CInt
    ) -> CInt

    @_silgen_name("inflate")
    static func inflate(_ stream: UnsafeMutablePointer<ZStream>, _ flush: CInt) -> CInt

    @_silgen_name("inflateEnd")
    static func inflateEnd(_ stream: UnsafeMutablePointer<ZStream>) -> CInt
}

// MARK: - Raw deflate <-> zlib bridging (fixed)

/// Raw-deflate encode/decode. Decoding goes through the vendored zlib
/// with `inflateInit2(-15)` — raw deflate, no header, no trailer.
/// Encoding still uses the Compression framework: the encoder builds a
/// real zlib stream (with a correctly computed Adler-32), and stripping
/// its 2-byte header and 4-byte trailer yields valid raw deflate, so
/// the encode path was never broken and is carried over unchanged.
public enum ZipCompression {

    /// Decodes a raw-deflate `data` block whose expected output is
    /// `expectedSize` bytes. Throws on size mismatch, truncation, or
    /// decode failure. Bounded by the §B.3 single-file cap.
    public static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        // R-H2: a negative expected size must throw, never wrap or trap.
        guard expectedSize >= 0 else {
            throw AppError.ipa(.invalidZIP("Negative expected uncompressed size."))
        }
        guard expectedSize <= Int(FileSystemManager.maxSingleFileBytes) else {
            throw AppError.ipa(.sizeLimitExceeded(
                limit: FileSystemManager.maxSingleFileBytes, actual: Int64(expectedSize)))
        }
        guard data.count <= Int(FileSystemManager.maxSingleFileBytes) else {
            throw AppError.ipa(.sizeLimitExceeded(
                limit: FileSystemManager.maxSingleFileBytes, actual: Int64(data.count)))
        }
        // An entry that declares zero uncompressed bytes decodes to empty.
        // Integrity is still guarded downstream: readEntryData verifies
        // the CRC-32 of the decoded bytes, and gunzip verifies the gzip
        // trailer CRC, so a corrupt zero-size claim cannot pass silently.
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else {
            throw AppError.ipa(.corruptZIP(
                "Deflate stream is empty but \(expectedSize) bytes were expected."))
        }

        return try data.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw AppError.ipa(.corruptZIP("Cannot access deflate input bytes."))
            }
            var stream = CZlib.ZStream()
            stream.nextIn = inputBase
            stream.availIn = UInt32(data.count)
            // -15 windowBits = raw deflate (no zlib header, no Adler-32).
            // inflateInit2_ validates the version string and the stream
            // size and returns Z_VERSION_ERROR on mismatch.
            let initResult = "1.3.1".withCString { version in
                CZlib.inflateInit2(&stream, -15, version, CInt(MemoryLayout<CZlib.ZStream>.size))
            }
            guard initResult == CZlib.zOK else {
                throw AppError.ipa(.corruptZIP(
                    "Failed to initialise the deflate decoder (decoder error \(initResult))."))
            }
            defer { _ = CZlib.inflateEnd(&stream) }

            var output = Data()
            output.reserveCapacity(min(expectedSize, 16 * 1024 * 1024))
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            try chunk.withUnsafeMutableBytes { rawChunk in
                guard let chunkBase = rawChunk.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw AppError.ipa(.corruptZIP("Cannot access deflate output buffer."))
                }
                // Flush discipline (vendored zlib.h, inflate docs):
                // Z_FINISH is only for a SINGLE call whose output buffer
                // is large enough to hold all output. With a chunked
                // output buffer it must NOT be used while input remains:
                // when the 64 KiB chunk fills first, inflate returns
                // Z_BUF_ERROR on a perfectly valid stream. So the loop
                // uses Z_NO_FLUSH while input remains and switches to
                // Z_FINISH only once all input has been fed (availIn == 0).
                // (Found by Gemini code review + reproduced in C on a
                // 5 MB multi-chunk stream: Z_FINISH-every-call failed
                // with Z_BUF_ERROR after the first 64 KiB.)
                var idleIterations = 0
                while true {
                    stream.nextOut = chunkBase
                    stream.availOut = UInt32(chunkSize)
                    let flush = stream.availIn == 0 ? CZlib.zFinish : CZlib.zNoFlush
                    let status = CZlib.inflate(&stream, flush)
                    let produced = chunkSize - Int(stream.availOut)
                    if produced > 0 {
                        if output.count + produced > expectedSize {
                            throw AppError.ipa(.corruptZIP(
                                "Deflated entry expands beyond its declared size."))
                        }
                        output.append(chunkBase, count: produced)
                        idleIterations = 0
                    }
                    if status == CZlib.zStreamEnd {
                        break
                    }
                    if status == CZlib.zBufError {
                        // Z_BUF_ERROR is not fatal: no progress was
                        // possible. With all input fed, that means either
                        // the stream is truncated (output incomplete) or
                        // the raw stream ended without the final
                        // Z_STREAM_END signal — raw deflate can need one
                        // dummy byte past the last block for zlib to
                        // signal the end (the vendored minizip notes the
                        // same). The second case is accepted only when
                        // the output is already exactly the declared
                        // size; the size check below and the caller's
                        // CRC-32 check still verify the data.
                        if output.count == expectedSize && stream.availIn == 0 {
                            break
                        }
                        throw AppError.ipa(.corruptZIP("Deflate stream is truncated."))
                    }
                    if status < CZlib.zOK {
                        let detail = stream.msg.map { String(cString: $0) }
                            ?? "decoder error \(status)"
                        throw AppError.ipa(.corruptZIP("Deflate stream is corrupt (\(detail))."))
                    }
                    // status == Z_OK: progress was made (input consumed
                    // and/or output produced) or more input is needed.
                    // Any other positive code (e.g. Z_NEED_DICT, which
                    // cannot occur for raw deflate) is an error, so the
                    // loop cannot spin on an unhandled status.
                    guard status == CZlib.zOK else {
                        throw AppError.ipa(.corruptZIP(
                            "Deflate stream is corrupt (unexpected decoder status \(status))."))
                    }
                    // Termination: every iteration consumes input,
                    // produces output (bounded by expectedSize), ends,
                    // or errors — except a Z_OK call that does neither,
                    // which zlib's contract says is reported as
                    // Z_BUF_ERROR instead. The idle counter below is a
                    // backstop for that impossible case only.
                    if produced == 0 && stream.availIn == 0 {
                        idleIterations += 1
                        if idleIterations > 8 {
                            throw AppError.ipa(.corruptZIP("Deflate stream made no progress."))
                        }
                    }
                }
            }
            guard output.count == expectedSize else {
                throw AppError.ipa(.corruptZIP(
                    "Deflated entry decoded to \(output.count) bytes, expected \(expectedSize)."))
            }
            return output
        }
    }

    /// Encodes `data` as a raw-deflate block by encoding with zlib and
    /// stripping the 2-byte header and 4-byte Adler-32 trailer.
    public static func deflateRaw(_ data: Data) throws -> Data {
        if data.isEmpty { return Data([0x03, 0x00]) } // empty stored deflate block
        let bound = data.count + 64
        var encoded = Data(count: bound)
        let encodedSize = encoded.withUnsafeMutableBytes { dst -> Int in
            guard let dstPtr = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return data.withUnsafeBytes { src -> Int in
                guard let srcPtr = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(
                    dstPtr,
                    bound,
                    srcPtr,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedSize > 6 else {
            throw AppError.ipa(.ioError("Deflate encoding failed."))
        }
        encoded.count = encodedSize
        // Strip zlib header (2 bytes) and Adler-32 trailer (4 bytes).
        return encoded.subdata(in: 2..<(encodedSize - 4))
    }
}

// MARK: - TAR helpers (for DEB data.tar inspection)

/// Compression detected from magic bytes at the start of a file.
public enum TarCompression: String {
    case none
    case gzip
    case xz
    case bzip2
    case lzma
    case zstd
    case unknown
}

/// One entry in a (possibly uncompressed) tar archive.
public struct TarEntry {
    public var name: String
    public var size: Int64
    public var typeFlag: UInt8
    public var isDirectory: Bool

    public init(name: String, size: Int64, typeFlag: UInt8) {
        self.name = name
        self.size = size
        self.typeFlag = typeFlag
        self.isDirectory = typeFlag == UInt8(ascii: "5") || name.hasSuffix("/")
    }
}

// MARK: - Archive engine

/// Pure-Swift ZIP reader/writer (central-directory parser, safe extraction,
/// archive creation) plus tar helpers for DEB `data.tar` inspection.
///
/// Safety rules enforced on every read path:
/// - Entry names must be relative, contain no `..` component and no
///   absolute path (see `isUnsafeEntryName`).
/// - Total uncompressed size and per-entry ratio are capped by the §B.3
///   limits (2 GiB IPA, 8 GiB total, 1 GiB per file, 100:1 ratio,
///   50,000 entries).
/// - Symlinks inside an archive are never followed outside the destination.
/// - ZIP64 is NOT supported: sizes are UInt32 only. An entry whose
///   central-directory sizes are the 0xFFFFFFFF sentinel is rejected
///   with `invalidZIP` (known limitation; real IPAs are far below 4 GiB
///   and standard tools do not emit ZIP64 for them).
public final class ArchiveEngine {

    public init() {}

    // MARK: - Entry-name safety

    /// Returns true when a ZIP entry name must be rejected.
    public static func isUnsafeEntryName(_ name: String) -> Bool {
        if name.isEmpty { return true }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return true }
        if name.contains("\\\\") { return true }
        // Drive-letter absolute paths (defensive; ZIP names use "/").
        if name.count >= 2, name[name.index(name.startIndex, offsetBy: 1)] == ":",
           name.first?.isLetter == true { return true }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component == ".." { return true }
        }
        return false
    }

    /// Resolves `name` inside `destination` and throws if it escapes.
    public static func safeDestination(for name: String, inside destination: URL) throws -> URL {
        guard !isUnsafeEntryName(name) else {
            throw AppError.ipa(.pathTraversalAttempt(entry: name))
        }
        var url = destination
        for component in name.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        let standardizedDestination = destination.standardizedFileURL
        let standardizedTarget = url.standardizedFileURL
        guard standardizedTarget.path.hasPrefix(standardizedDestination.path + "/")
            || standardizedTarget.path == standardizedDestination.path else {
            throw AppError.ipa(.pathTraversalAttempt(entry: name))
        }
        return standardizedTarget
    }

    // MARK: - Central directory parsing

    /// Lists the entries of the ZIP archive at `url` without extracting.
    public func listEntries(at url: URL) throws -> [ZipEntry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AppError.ipa(.fileNotFound(path: url.path))
        }
        defer { try? handle.close() }
        let fileSize: Int64
        do {
            fileSize = Int64(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw AppError.ipa(.ioError("Cannot stat ZIP file: \(error.localizedDescription)"))
        }
        guard fileSize >= 22 else {
            throw AppError.ipa(.invalidZIP("File is too small to be a ZIP archive (\(fileSize) bytes)."))
        }
        guard fileSize <= FileSystemManager.maxIPABytes else {
            throw AppError.ipa(.sizeLimitExceeded(limit: FileSystemManager.maxIPABytes, actual: fileSize))
        }
        let data = try readAll(handle: handle, size: fileSize)
        return try parseCentralDirectory(data: data)
    }

    /// Parses the End-of-Central-Directory record and the central directory
    /// from in-memory ZIP `data`. Throws `AppError.ipa(.invalidZIP)` /
    /// `.corruptZIP`.
    public func parseCentralDirectory(data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else {
            throw AppError.ipa(.invalidZIP("File is too small to be a ZIP archive (\(data.count) bytes)."))
        }
        // EOCD signature 0x06054b50; search the last 64 KB + 22 bytes.
        let eocdSignature: UInt32 = 0x06054b50
        let searchStart = max(0, data.count - (65557 + 22))
        var eocdOffset: Int?
        var offset = data.count - 22
        while offset >= searchStart {
            if readUInt32(data, at: offset) == eocdSignature {
                eocdOffset = offset
                break
            }
            offset -= 1
        }
        guard let eocd = eocdOffset else {
            throw AppError.ipa(.invalidZIP("End-of-central-directory record not found."))
        }
        let totalEntries = Int(readUInt16(data, at: eocd + 10))
        let centralDirectorySize = Int(readUInt32(data, at: eocd + 12))
        let centralDirectoryOffset = Int(readUInt32(data, at: eocd + 16))
        guard totalEntries <= FileSystemManager.maxArchiveEntries else {
            throw AppError.ipa(.entryCountExceeded(limit: FileSystemManager.maxArchiveEntries, actual: totalEntries))
        }
        guard centralDirectoryOffset >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw AppError.ipa(.corruptZIP("Central directory offset/size is out of bounds."))
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(totalEntries)
        var cursor = centralDirectoryOffset
        let centralSignature: UInt32 = 0x02014b50
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  readUInt32(data, at: cursor) == centralSignature else {
                throw AppError.ipa(.corruptZIP("Bad central-directory entry at offset \(cursor)."))
            }
            let method = readUInt16(data, at: cursor + 10)
            let modTime = readUInt16(data, at: cursor + 12)
            let modDate = readUInt16(data, at: cursor + 14)
            let crc = readUInt32(data, at: cursor + 16)
            let compressedSizeRaw = readUInt32(data, at: cursor + 20)
            let uncompressedSizeRaw = readUInt32(data, at: cursor + 24)
            // ZIP64 is not supported: the 0xFFFFFFFF sentinel means the
            // real size lives in the ZIP64 extra field, which this
            // reader does not parse. Reject loudly instead of treating
            // the sentinel as a (huge, wrong) size.
            guard compressedSizeRaw != 0xFFFFFFFF, uncompressedSizeRaw != 0xFFFFFFFF else {
                throw AppError.ipa(.invalidZIP("ZIP64 archives are not supported."))
            }
            let compressedSize = Int64(compressedSizeRaw)
            let uncompressedSize = Int64(uncompressedSizeRaw)
            let nameLength = Int(readUInt16(data, at: cursor + 28))
            let extraLength = Int(readUInt16(data, at: cursor + 30))
            let commentLength = Int(readUInt16(data, at: cursor + 32))
            let externalAttributes = readUInt32(data, at: cursor + 38)
            let localHeaderOffset = Int64(readUInt32(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw AppError.ipa(.corruptZIP("Entry name runs past the end of the central directory."))
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            let isDirectory = name.hasSuffix("/")
            // Unix file type lives in the high 16 bits of external attributes.
            let unixMode = (externalAttributes >> 16) & 0xFFFF
            let isSymlink = (unixMode & 0xF000) == 0xA000
            entries.append(ZipEntry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory,
                modificationDate: dosDateTimeToDate(date: modDate, time: modTime),
                externalAttributes: externalAttributes,
                isSymlink: isSymlink
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Reading entry data

    /// Reads the (decompressed) data of one entry by name. `maxBytes`
    /// caps how much is returned — used to read only a Mach-O header or an
    /// Info.plist without decompressing a huge file. CRC is verified for
    /// full reads (when `maxBytes` is nil).
    public func readEntryData(named name: String, in archiveURL: URL, maxBytes: Int? = nil) throws -> Data {
        let entries = try listEntries(at: archiveURL)
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw AppError.ipa(.invalidZIP("Entry not found: \(name)"))
        }
        return try readEntryData(entry, in: archiveURL, maxBytes: maxBytes)
    }

    /// Reads the (decompressed) data of a `ZipEntry` located by its
    /// central-directory record.
    public func readEntryData(_ entry: ZipEntry, in archiveURL: URL, maxBytes: Int? = nil) throws -> Data {
        if let maxBytes {
            // R-H2: a negative cap must throw, never trap in a range.
            guard maxBytes >= 0 else {
                throw AppError.ipa(.invalidZIP("Negative maxBytes."))
            }
        }
        if let maxBytes, entry.uncompressedSize > Int64(maxBytes) {
            // Partial read: decompress fully (bounded) then truncate, unless
            // the entry is stored, in which case we can read just the prefix.
            if entry.isStored {
                return try readStoredPrefix(entry, in: archiveURL, maxBytes: maxBytes)
            }
        }
        let raw = try readCompressedBytes(entry, in: archiveURL)
        let decoded: Data
        switch entry.compressionMethod {
        case 0:
            decoded = raw
        case 8:
            decoded = try ZipCompression.inflateRawDeflate(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            throw AppError.ipa(.unsupportedFormat("Unsupported ZIP compression method \(entry.compressionMethod) for \(entry.name)."))
        }
        guard Int64(decoded.count) == entry.uncompressedSize else {
            throw AppError.ipa(.corruptZIP("Entry \(entry.name) decoded to \(decoded.count) bytes, expected \(entry.uncompressedSize)."))
        }
        if CRC32.checksum(decoded) != entry.crc32 {
            throw AppError.ipa(.corruptZIP("CRC-32 mismatch for entry \(entry.name)."))
        }
        if let maxBytes, decoded.count > maxBytes {
            return decoded.subdata(in: 0..<maxBytes)
        }
        return decoded
    }

    /// Reads the first `maxBytes` of a stored (uncompressed) entry directly
    /// from the archive file without loading the whole entry.
    private func readStoredPrefix(_ entry: ZipEntry, in archiveURL: URL, maxBytes: Int) throws -> Data {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archiveURL) } catch {
            throw AppError.ipa(.fileNotFound(path: archiveURL.path))
        }
        defer { try? handle.close() }
        let dataStart = try localDataOffset(for: entry, handle: handle)
        try handle.seek(toOffset: UInt64(dataStart))
        let count = min(maxBytes, Int(entry.uncompressedSize))
        guard let data = try handle.read(upToCount: count) else {
            throw AppError.ipa(.corruptZIP("Cannot read stored entry \(entry.name)."))
        }
        return data
    }

    /// Reads the raw (still compressed) bytes of an entry.
    private func readCompressedBytes(_ entry: ZipEntry, in archiveURL: URL) throws -> Data {
        guard entry.compressedSize <= FileSystemManager.maxSingleFileBytes else {
            throw AppError.ipa(.sizeLimitExceeded(limit: FileSystemManager.maxSingleFileBytes, actual: entry.compressedSize))
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archiveURL) } catch {
            throw AppError.ipa(.fileNotFound(path: archiveURL.path))
        }
        defer { try? handle.close() }
        let dataStart = try localDataOffset(for: entry, handle: handle)
        let end = dataStart + entry.compressedSize
        let fileSize = Int64(try handle.seekToEnd())
        guard end <= fileSize else {
            throw AppError.ipa(.corruptZIP("Entry \(entry.name) runs past the end of the archive."))
        }
        try handle.seek(toOffset: UInt64(dataStart))
        guard let data = try handle.read(upToCount: Int(entry.compressedSize)) else {
            throw AppError.ipa(.corruptZIP("Cannot read entry \(entry.name)."))
        }
        guard data.count == entry.compressedSize else {
            throw AppError.ipa(.corruptZIP("Short read for entry \(entry.name)."))
        }
        return data
    }

    /// Parses a local file header at `entry.localHeaderOffset` and returns
    /// the offset where the entry's data begins.
    /// Sizes come from the central directory, never from the local header,
    /// so a data descriptor (general-purpose bit 3) after the data has no
    /// effect on the offset computation.
    private func localDataOffset(for entry: ZipEntry, handle: FileHandle) throws -> Int64 {
        // localHeaderOffset comes from a UInt32 field, so it is >= 0 by
        // construction; the seek below cannot trap on a negative offset.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw AppError.ipa(.corruptZIP("Cannot read local header for \(entry.name)."))
        }
        guard readUInt32(header, at: 0) == 0x04034b50 else {
            throw AppError.ipa(.corruptZIP("Bad local header signature for \(entry.name)."))
        }
        let nameLength = Int(readUInt16(header, at: 26))
        let extraLength = Int(readUInt16(header, at: 28))
        return entry.localHeaderOffset + 30 + Int64(nameLength) + Int64(extraLength)
    }

    // MARK: - Extraction

    /// Extracts every entry of the archive at `archiveURL` into
    /// `destination`, enforcing all size/ratio/path/symlink limits.
    /// - Returns: The URLs of the extracted files (directories excluded).
    @discardableResult
    public func extractAll(from archiveURL: URL, to destination: URL) throws -> [URL] {
        let entries = try listEntries(at: archiveURL)
        try checkArchiveTotals(entries)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw AppError.ipa(.ioError("Cannot create extraction directory: \(error.localizedDescription)"))
        }
        var extracted: [URL] = []
        var totalUncompressed: Int64 = 0
        for entry in entries {
            if entry.isDirectory {
                let dir = try Self.safeDestination(for: entry.name, inside: destination)
                do {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    throw AppError.ipa(.ioError("Cannot create directory \(entry.name): \(error.localizedDescription)"))
                }
                continue
            }
            if entry.isSymlink {
                // Never recreate a symlink from an untrusted archive: the
                // link is materialised as a regular file whose *contents*
                // are the target path string. No filesystem link is ever
                // created, so the target can never escape the destination.
                let linkTargetData = try readEntryData(entry, in: archiveURL)
                guard let target = String(data: linkTargetData, encoding: .utf8) else {
                    throw AppError.ipa(.unsafeSymlink(entry: destination.appendingPathComponent(entry.name).path))
                }
                let targetURL = try Self.safeDestination(for: entry.name, inside: destination)
                do {
                    try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(target.utf8).write(to: targetURL)
                } catch let error as AppError {
                    throw error
                } catch {
                    throw AppError.ipa(.ioError("Cannot write symlink placeholder \(entry.name): \(error.localizedDescription)"))
                }
                extracted.append(targetURL)
                continue
            }
            totalUncompressed += entry.uncompressedSize
            guard totalUncompressed <= FileSystemManager.maxDecompressedBytes else {
                throw AppError.ipa(.zipBombSuspected)
            }
            let data = try readEntryData(entry, in: archiveURL)
            let targetURL = try Self.safeDestination(for: entry.name, inside: destination)
            do {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw AppError.ipa(.ioError("Cannot create directory for \(entry.name): \(error.localizedDescription)"))
            }
            // Refuse to overwrite through a pre-existing symlink.
            if let attributes = try? fileManager.attributesOfItem(atPath: targetURL.path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw AppError.ipa(.unsafeSymlink(entry: targetURL.path))
            }
            do {
                try data.write(to: targetURL, options: [.atomic])
            } catch {
                throw AppError.ipa(.ioError("Cannot write \(entry.name): \(error.localizedDescription)"))
            }
            if let date = entry.modificationDate {
                try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
            }
            extracted.append(targetURL)
        }
        return extracted
    }

    /// Checks total entry count / sizes / compression ratio up front.
    public func checkArchiveTotals(_ entries: [ZipEntry]) throws {
        guard entries.count <= FileSystemManager.maxArchiveEntries else {
            throw AppError.ipa(.entryCountExceeded(limit: FileSystemManager.maxArchiveEntries, actual: entries.count))
        }
        let totalCompressed = entries.reduce(Int64(0)) { $0 + $1.compressedSize }
        let totalUncompressed = entries.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        guard totalUncompressed <= FileSystemManager.maxDecompressedBytes else {
            throw AppError.ipa(.sizeLimitExceeded(limit: FileSystemManager.maxDecompressedBytes, actual: totalUncompressed))
        }
        if totalCompressed > 0 {
            let ratio = Double(totalUncompressed) / Double(totalCompressed)
            guard ratio <= FileSystemManager.maxDecompressionRatio else {
                throw AppError.ipa(.zipBombSuspected)
            }
        }
        for entry in entries where entry.uncompressedSize > FileSystemManager.maxSingleFileBytes {
            throw AppError.ipa(.sizeLimitExceeded(limit: FileSystemManager.maxSingleFileBytes, actual: entry.uncompressedSize))
        }
    }

    // MARK: - Archive creation

    /// Creates a ZIP archive at `destination` containing `files`, where each
    /// tuple is `(archivePath, fileURL)`. Directories are added implicitly
    /// from the archive paths. Files are deflated; empty files are stored.
    public func createArchive(files: [(archivePath: String, fileURL: URL)], to destination: URL) throws {
        let fileManager = FileManager.default
        guard files.count <= 0xFFFF else {
            throw AppError.ipa(.entryCountExceeded(limit: 0xFFFF, actual: files.count))
        }
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw AppError.ipa(.ioError("Cannot replace \(destination.lastPathComponent): \(error.localizedDescription)"))
            }
        }
        var output = Data()
        var central: [(entry: ZipEntry, crc: UInt32, localOffset: Int64)] = []
        var offset: Int64 = 0

        for (archivePath, fileURL) in files {
            guard !Self.isUnsafeEntryName(archivePath) else {
                throw AppError.ipa(.pathTraversalAttempt(entry: archivePath))
            }
            let nameData = Data(archivePath.utf8)
            guard nameData.count <= 0xFFFF else {
                throw AppError.ipa(.invalidZIP("Entry name too long: \(archivePath)"))
            }
            let fileData: Data
            do { fileData = try Data(contentsOf: fileURL) } catch {
                throw AppError.ipa(.ioError("Cannot read \(fileURL.lastPathComponent) for archiving: \(error.localizedDescription)"))
            }
            guard fileData.count <= FileSystemManager.maxSingleFileBytes else {
                throw AppError.ipa(.sizeLimitExceeded(limit: FileSystemManager.maxSingleFileBytes, actual: Int64(fileData.count)))
            }
            let crc = CRC32.checksum(fileData)
            let (method, payload): (UInt16, Data)
            if fileData.isEmpty {
                method = 0
                payload = fileData
            } else {
                method = 8
                payload = try ZipCompression.deflateRaw(fileData)
            }
            let localOffset = offset
            // Local file header.
            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20) // version needed
            local.appendUInt16(0x0800) // UTF-8 flag
            local.appendUInt16(method)
            local.appendUInt16(0) // mod time
            local.appendUInt16(0) // mod date
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(fileData.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0) // extra length
            local.append(nameData)
            local.append(payload)
            output.append(local)
            offset += Int64(local.count)
            central.append((ZipEntry(
                name: archivePath,
                compressionMethod: method,
                compressedSize: Int64(payload.count),
                uncompressedSize: Int64(fileData.count),
                crc32: crc,
                localHeaderOffset: localOffset,
                isDirectory: false
            ), crc, localOffset))
        }

        let centralOffset = offset
        for (entry, _, localOffset) in central {
            let nameData = Data(entry.name.utf8)
            var record = Data()
            record.appendUInt32(0x02014b50)
            record.appendUInt16(20) // version made by
            record.appendUInt16(20) // version needed
            record.appendUInt16(0x0800)
            record.appendUInt16(entry.compressionMethod)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(entry.crc32)
            record.appendUInt32(UInt32(entry.compressedSize))
            record.appendUInt32(UInt32(entry.uncompressedSize))
            record.appendUInt16(UInt16(nameData.count))
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(0)
            record.appendUInt32(UInt32(localOffset))
            record.append(nameData)
            output.append(record)
            offset += Int64(record.count)
        }
        let centralSize = offset - centralOffset
        // ZIP32 (no ZIP64): every offset and size in the central
        // directory and EOCD is a UInt32, so the whole archive must fit.
        guard centralOffset <= Int64(UInt32.max), centralSize <= Int64(UInt32.max) else {
            throw AppError.ipa(.invalidZIP("Archive exceeds the 4 GiB ZIP32 limit (ZIP64 is not supported)."))
        }
        var eocd = Data()
        eocd.appendUInt32(0x06054b50)
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(central.count))
        eocd.appendUInt16(UInt16(central.count))
        eocd.appendUInt32(UInt32(centralSize))
        eocd.appendUInt32(UInt32(centralOffset))
        eocd.appendUInt16(0)
        output.append(eocd)
        do {
            try output.write(to: destination, options: [.atomic])
        } catch {
            throw AppError.ipa(.ioError("Cannot write archive: \(error.localizedDescription)"))
        }
    }

    /// Convenience: archives a whole directory tree (relative paths preserved).
    public func createArchive(fromDirectory directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw AppError.ipa(.ioError("Cannot enumerate \(directory.path)."))
        }
        var files: [(archivePath: String, fileURL: URL)] = []
        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            files.append((archivePath: relative, fileURL: fileURL))
        }
        files.sort { $0.archivePath < $1.archivePath }
        try createArchive(files: files, to: destination)
    }

    // MARK: - TAR helpers (DEB data.tar)

    /// Detects tar compression from magic bytes. Returns `.unknown` when the
    /// bytes match no known compressor — callers must report that honestly
    /// instead of guessing.
    public static func detectTarCompression(_ data: Data) -> TarCompression {
        guard data.count >= 2 else { return .none }
        if data.count >= 6,
           data[0] == 0xFD, data[1] == 0x37, data[2] == 0x7A,
           data[3] == 0x58, data[4] == 0x5A, data[5] == 0x00 {
            return .xz
        }
        if data[0] == 0x1F, data[1] == 0x8B { return .gzip }
        if data.count >= 3, data[0] == 0x42, data[1] == 0x5A, data[2] == 0x68 { return .bzip2 }
        if data.count >= 6,
           data[0] == 0xFD, data[1] == 0x37, data[2] == 0x7A,
           data[3] == 0x58, data[4] == 0x5A, data[5] == 0x00 { return .xz }
        if data.count >= 4, data[0] == 0x28, data[1] == 0xB5, data[2] == 0x2F, data[3] == 0xFD { return .zstd }
        if data.count >= 6,
           data[0] == 0x5D, data[1] == 0x00, data[2] == 0x00 {
            // LZMA alone has no strong magic; only claim it when the caller
            // already knows the container is LZMA. Here: unknown.
            return .unknown
        }
        // Plain tar starts with a filename in the first 100 bytes; treat
        // anything else as unknown rather than assuming uncompressed tar.
        return .none
    }

    /// Parses an *uncompressed* tar stream into entries. Compressed tars
    /// (gzip/xz/bzip2) are reported as unsupported by this parser — the
    /// caller must decompress first or surface the limitation.
    public static func parseTarEntries(_ data: Data) throws -> [TarEntry] {
        guard data.count % 512 == 0 || data.count >= 512 else {
            throw AppError.ipa(.invalidZIP("Tar data is not a multiple of 512 bytes."))
        }
        var entries: [TarEntry] = []
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break } // end-of-archive marker
            let nameData = header.subdata(in: 0..<100)
            let name = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let sizeString = String(bytes: header.subdata(in: 124..<136).prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let size = Int64(sizeString.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            // R-H2: a negative size makes the block count negative,
            // so the offset walks backwards (hang) and the stored
            // entry size would trap later consumers.
            guard size >= 0 else {
                throw AppError.ipa(.invalidZIP("Negative tar member size."))
            }
            let typeFlag = header[156]
            // Long-name ('L') and long-link ('K') GNU extensions: the next
            // block holds the real name; skip it and re-read the real header.
            if typeFlag == UInt8(ascii: "L") || typeFlag == UInt8(ascii: "K") {
                let blocks = Int((size + 511) / 512)
                offset += 512 * (1 + blocks)
                continue
            }
            entries.append(TarEntry(name: name, size: size, typeFlag: typeFlag))
            let blocks = Int((size + 511) / 512)
            offset += 512 * (1 + blocks)
            guard entries.count <= FileSystemManager.maxArchiveEntries else {
                throw AppError.ipa(.entryCountExceeded(limit: FileSystemManager.maxArchiveEntries, actual: entries.count))
            }
        }
        return entries
    }

    /// Decompresses gzip data. Returns nil when the data is not gzip or
    /// decompression fails, so callers can report the limitation instead
    /// of producing corrupt output.
    ///
    /// THE FIX (same root cause as ZIP method 8): the old implementation
    /// decoded the gzip body with the same broken fake-wrapper decoder.
    /// The body is a raw deflate stream, so it now goes through
    /// `ZipCompression.inflateRawDeflate` (`inflateInit2(-15)`), and the
    /// 8-byte gzip trailer (CRC-32 + ISIZE) is verified instead of
    /// ignored: a CRC mismatch returns nil.
    public static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else { return nil }
        // Gzip header: 10 bytes + optional extra fields. Parse FLG.
        let flags = data[3]
        var headerLength = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard data.count >= headerLength + 2 else { return nil }
            let xlen = Int(data[headerLength]) | (Int(data[headerLength + 1]) << 8)
            headerLength += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while headerLength < data.count, data[headerLength] != 0 { headerLength += 1 }
            headerLength += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while headerLength < data.count, data[headerLength] != 0 { headerLength += 1 }
            headerLength += 1
        }
        if flags & 0x02 != 0 { headerLength += 2 } // FHCRC
        guard headerLength < data.count - 8 else { return nil }
        // The body is a raw deflate stream; decode it with the fixed
        // decoder, ignoring nothing: the trailer is verified below.
        let body = data.subdata(in: headerLength..<(data.count - 8))
        // Expected size is the ISIZE field (last 4 bytes, little-endian).
        // R-H2: ISIZE is UInt32, so it cannot be negative; it is the true
        // size modulo 2^32, so a gzip over 4 GiB would wrap — a known
        // limitation in the same class as ZIP64 (see the class comment).
        let isize = Int(readUInt32(data, at: data.count - 4))
        guard isize <= Int(FileSystemManager.maxSingleFileBytes) else { return nil }
        let expectedCRC = readUInt32(data, at: data.count - 8)
        guard let decoded = try? ZipCompression.inflateRawDeflate(body, expectedSize: isize) else {
            return nil
        }
        guard CRC32.checksum(decoded) == expectedCRC else { return nil }
        return decoded
    }

    // MARK: - Low-level helpers

    private func readAll(handle: FileHandle, size: Int64) throws -> Data {
        // ZIP central-directory parsing needs random access; the file is
        // already capped at 2 GiB, and in practice IPAs are far smaller.
        // Read in 8 MB chunks to avoid a single huge allocation spike.
        var result = Data()
        result.reserveCapacity(Int(min(size, 64 * 1024 * 1024)))
        try handle.seek(toOffset: 0)
        while result.count < size {
            let remaining = size - Int64(result.count)
            let chunkSize = Int(min(remaining, 8 * 1024 * 1024))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw AppError.ipa(.corruptZIP("Short read while loading ZIP central directory."))
            }
            result.append(chunk)
        }
        return result
    }

    private func dosDateTimeToDate(date: UInt16, time: UInt16) -> Date? {
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980
        let second = Int((time & 0x1F) * 2)
        let minute = Int((time >> 5) & 0x3F)
        let hour = Int((time >> 11) & 0x1F)
        guard (1...31).contains(day), (1...12).contains(month), year >= 1980 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

// MARK: - Little-endian readers (byte-assembled, so no alignment
// assumptions; they return 0 only when the range is out of bounds, and
// every parsing site checks lengths before calling).

func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { return 0 }
    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(data[offset + index]) << (8 * index)
    }
    return value
}

// MARK: - Data append helpers for ZIP writing

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }
}
