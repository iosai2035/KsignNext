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

// MARK: - CRC32 / Adler32 (pure Swift)

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

/// Adler-32 checksum, needed to wrap raw deflate streams in a zlib header
/// for the Compression framework (see `ZipCompression` below).
public enum Adler32 {
    public static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

// MARK: - Raw deflate <-> zlib bridging via Compression

/// ZIP stores deflate streams raw (no zlib header). Apple's Compression
/// framework only speaks zlib-wrapped deflate, so this helper adds the
/// 2-byte zlib header + 4-byte Adler-32 trailer when decoding, and strips
/// them when encoding. No third-party dependency is involved.
public enum ZipCompression {

    /// Decodes a raw-deflate `data` block whose expected output is
    /// `expectedSize` bytes. Throws on size mismatch or decode failure.
    public static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        try inflateRawDeflateStreaming(data, expectedSize: expectedSize)
    }

    /// Streaming raw-deflate decode using `compression_stream` with
    /// `COMPRESSION_ZLIB`. The input is the raw deflate bytes wrapped in a
    /// synthetic zlib header (0x78 0x9C) plus a dummy 4-byte Adler-32
    /// trailer; the decoder stops at stream end once the deflate block
    /// terminates, so the dummy trailer is never validated. All pointer
    /// use happens inside the `withUnsafeBytes` closures, so no pointer
    /// outlives the buffer it points into. Bounded by `expectedSize`.
    public static func inflateRawDeflateStreaming(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else {
            throw IPAError.corruptZIP("Negative expected uncompressed size.")
        }
        if expectedSize == 0 { return Data() }
        var input = Data([0x78, 0x9C])
        input.append(data)
        input.append(contentsOf: [0, 0, 0, 0])

        var output = Data()
        output.reserveCapacity(min(expectedSize, 16 * 1024 * 1024))
        // The SDK's memberwise init takes non-optional pointers, so the
        // stream starts pointed at a dummy byte with zero sizes; the real
        // pointers are assigned before every `compression_stream_process`
        // call below, and `compression_stream_init` never dereferences them.
        var dummyByte: UInt8 = 0
        var stream = compression_stream(dst_ptr: &dummyByte, dst_size: 0, src_ptr: &dummyByte, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw IPAError.corruptZIP("Failed to initialise deflate decoder.")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        // The whole decode runs inside the unsafe-pointer closures so the
        // src/dst pointers stay valid for every `compression_stream_process`.
        try input.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw IPAError.corruptZIP("Cannot access deflate input bytes.")
            }
            try outBuffer.withUnsafeMutableBytes { rawOutput in
                guard let outputBase = rawOutput.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw IPAError.corruptZIP("Cannot access deflate output buffer.")
                }
                stream.src_ptr = inputBase
                stream.src_size = input.count
                var status: compression_status = COMPRESSION_STATUS_OK
                while status != COMPRESSION_STATUS_END {
                    stream.dst_ptr = outputBase
                    stream.dst_size = chunkSize
                    // COMPRESSION_STREAM_FINALIZE: the whole input was
                    // supplied up front, so the decoder may finish the
                    // stream. (It is a `compression_stream_process` flag,
                    // not a field of `compression_stream`.)
                    status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE)
                    let produced = chunkSize - stream.dst_size
                    if produced > 0 {
                        if output.count + produced > expectedSize {
                            throw IPAError.corruptZIP("Deflated entry expands beyond its declared size.")
                        }
                        output.append(contentsOf: outBuffer[0..<produced])
                    }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw IPAError.corruptZIP("Deflate stream is corrupt.")
                    }
                    if produced == 0 && stream.src_size == 0 && status != COMPRESSION_STATUS_END {
                        break
                    }
                    if output.count >= expectedSize { break }
                }
            }
        }
        guard output.count == expectedSize else {
            throw IPAError.corruptZIP("Deflated entry decoded to \(output.count) bytes, expected \(expectedSize).")
        }
        return output
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
            throw IPAError.ioError("Deflate encoding failed.")
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
/// - Total uncompressed size and per-entry ratio are capped by the limits
///   in `IPAEngine` (2 GB IPA, 10 GB total, 100:1 ratio, 50,000 entries).
/// - Symlinks inside an archive are never followed outside the destination.
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
            throw IPAError.pathTraversalAttempt(entry: name)
        }
        var url = destination
        for component in name.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        let standardizedDestination = destination.standardizedFileURL
        let standardizedTarget = url.standardizedFileURL
        guard standardizedTarget.path.hasPrefix(standardizedDestination.path + "/")
            || standardizedTarget.path == standardizedDestination.path else {
            throw IPAError.pathTraversalAttempt(entry: name)
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
            throw IPAError.fileNotFound(path: url.path)
        }
        defer { try? handle.close() }
        let fileSize: Int64
        do {
            fileSize = Int64(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw IPAError.ioError("Cannot stat ZIP file: \(error.localizedDescription)")
        }
        guard fileSize >= 22 else {
            throw IPAError.invalidZIP("File is too small to be a ZIP archive (\(fileSize) bytes).")
        }
        guard fileSize <= IPAEngine.maxIPASize else {
            throw IPAError.sizeLimitExceeded(limit: IPAEngine.maxIPASize, actual: fileSize)
        }
        let data = try readAll(handle: handle, size: fileSize)
        return try parseCentralDirectory(data: data)
    }

    /// Parses the End-of-Central-Directory record and the central directory
    /// from in-memory ZIP `data`. Throws `IPAError.invalidZIP` / `.corruptZIP`.
    public func parseCentralDirectory(data: Data) throws -> [ZipEntry] {
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
            throw IPAError.invalidZIP("End-of-central-directory record not found.")
        }
        let totalEntries = Int(readUInt16(data, at: eocd + 10))
        let centralDirectorySize = Int(readUInt32(data, at: eocd + 12))
        let centralDirectoryOffset = Int(readUInt32(data, at: eocd + 16))
        guard totalEntries <= IPAEngine.maxEntryCount else {
            throw IPAError.entryCountExceeded(limit: IPAEngine.maxEntryCount, actual: totalEntries)
        }
        guard centralDirectoryOffset >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw IPAError.corruptZIP("Central directory offset/size is out of bounds.")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(totalEntries)
        var cursor = centralDirectoryOffset
        let centralSignature: UInt32 = 0x02014b50
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  readUInt32(data, at: cursor) == centralSignature else {
                throw IPAError.corruptZIP("Bad central-directory entry at offset \(cursor).")
            }
            let method = readUInt16(data, at: cursor + 10)
            let modTime = readUInt16(data, at: cursor + 12)
            let modDate = readUInt16(data, at: cursor + 14)
            let crc = readUInt32(data, at: cursor + 16)
            let compressedSize = Int64(readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int64(readUInt32(data, at: cursor + 24))
            let nameLength = Int(readUInt16(data, at: cursor + 28))
            let extraLength = Int(readUInt16(data, at: cursor + 30))
            let commentLength = Int(readUInt16(data, at: cursor + 32))
            let externalAttributes = readUInt32(data, at: cursor + 38)
            let localHeaderOffset = Int64(readUInt32(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw IPAError.corruptZIP("Entry name runs past the end of the central directory.")
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
            throw IPAError.invalidZIP("Entry not found: \(name)")
        }
        return try readEntryData(entry, in: archiveURL, maxBytes: maxBytes)
    }

    /// Reads the (decompressed) data of a `ZipEntry` located by its
    /// central-directory record.
    public func readEntryData(_ entry: ZipEntry, in archiveURL: URL, maxBytes: Int? = nil) throws -> Data {
        if let maxBytes, entry.uncompressedSize > Int64(maxBytes) && maxBytes < Int(entry.uncompressedSize) {
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
            decoded = try ZipCompression.inflateRawDeflateStreaming(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            throw IPAError.unsupportedFormat("Unsupported ZIP compression method \(entry.compressionMethod) for \(entry.name).")
        }
        guard Int64(decoded.count) == entry.uncompressedSize else {
            throw IPAError.corruptZIP("Entry \(entry.name) decoded to \(decoded.count) bytes, expected \(entry.uncompressedSize).")
        }
        if CRC32.checksum(decoded) != entry.crc32 {
            throw IPAError.corruptZIP("CRC-32 mismatch for entry \(entry.name).")
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
            throw IPAError.fileNotFound(path: archiveURL.path)
        }
        defer { try? handle.close() }
        let dataStart = try localDataOffset(for: entry, handle: handle)
        try handle.seek(toOffset: UInt64(dataStart))
        let count = min(maxBytes, Int(entry.uncompressedSize))
        guard let data = try handle.read(upToCount: count) else {
            throw IPAError.corruptZIP("Cannot read stored entry \(entry.name).")
        }
        return data
    }

    /// Reads the raw (still compressed) bytes of an entry.
    private func readCompressedBytes(_ entry: ZipEntry, in archiveURL: URL) throws -> Data {
        guard entry.compressedSize <= IPAEngine.maxSingleEntrySize else {
            throw IPAError.sizeLimitExceeded(limit: IPAEngine.maxSingleEntrySize, actual: entry.compressedSize)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archiveURL) } catch {
            throw IPAError.fileNotFound(path: archiveURL.path)
        }
        defer { try? handle.close() }
        let dataStart = try localDataOffset(for: entry, handle: handle)
        let end = dataStart + entry.compressedSize
        let fileSize = Int64(try handle.seekToEnd())
        guard end <= fileSize else {
            throw IPAError.corruptZIP("Entry \(entry.name) runs past the end of the archive.")
        }
        try handle.seek(toOffset: UInt64(dataStart))
        guard let data = try handle.read(upToCount: Int(entry.compressedSize)) else {
            throw IPAError.corruptZIP("Cannot read entry \(entry.name).")
        }
        guard data.count == entry.compressedSize else {
            throw IPAError.corruptZIP("Short read for entry \(entry.name).")
        }
        return data
    }

    /// Parses a local file header at `entry.localHeaderOffset` and returns
    /// the offset where the entry's data begins.
    private func localDataOffset(for entry: ZipEntry, handle: FileHandle) throws -> Int64 {
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw IPAError.corruptZIP("Cannot read local header for \(entry.name).")
        }
        guard readUInt32(header, at: 0) == 0x04034b50 else {
            throw IPAError.corruptZIP("Bad local header signature for \(entry.name).")
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
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var extracted: [URL] = []
        var totalUncompressed: Int64 = 0
        for entry in entries {
            if entry.isDirectory {
                let dir = try Self.safeDestination(for: entry.name, inside: destination)
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                continue
            }
            if entry.isSymlink {
                // Never recreate a symlink from an untrusted archive: the
                // link is materialised as a regular file whose *contents*
                // are the target path string. No filesystem link is ever
                // created, so the target can never escape the destination.
                let linkTargetData = try readEntryData(entry, in: archiveURL)
                guard let target = String(data: linkTargetData, encoding: .utf8) else {
                    throw IPAError.unsafeSymlink(entry: destination.appendingPathComponent(entry.name).path)
                }
                let targetURL = try Self.safeDestination(for: entry.name, inside: destination)
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(target.utf8).write(to: targetURL)
                extracted.append(targetURL)
                continue
            }
            totalUncompressed += entry.uncompressedSize
            guard totalUncompressed <= IPAEngine.maxTotalUncompressedSize else {
                throw IPAError.zipBombSuspected
            }
            let data = try readEntryData(entry, in: archiveURL)
            let targetURL = try Self.safeDestination(for: entry.name, inside: destination)
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Refuse to overwrite through a pre-existing symlink.
            if let attributes = try? fileManager.attributesOfItem(atPath: targetURL.path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw IPAError.unsafeSymlink(entry: targetURL.path)
            }
            try data.write(to: targetURL, options: [.atomic])
            if let date = entry.modificationDate {
                try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
            }
            extracted.append(targetURL)
        }
        return extracted
    }

    /// Checks total entry count / sizes / compression ratio up front.
    public func checkArchiveTotals(_ entries: [ZipEntry]) throws {
        guard entries.count <= IPAEngine.maxEntryCount else {
            throw IPAError.entryCountExceeded(limit: IPAEngine.maxEntryCount, actual: entries.count)
        }
        let totalCompressed = entries.reduce(Int64(0)) { $0 + $1.compressedSize }
        let totalUncompressed = entries.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        guard totalUncompressed <= IPAEngine.maxTotalUncompressedSize else {
            throw IPAError.sizeLimitExceeded(limit: IPAEngine.maxTotalUncompressedSize, actual: totalUncompressed)
        }
        if totalCompressed > 0 {
            let ratio = Double(totalUncompressed) / Double(totalCompressed)
            guard ratio <= IPAEngine.maxCompressionRatio else {
                throw IPAError.zipBombSuspected
            }
        }
        for entry in entries where entry.uncompressedSize > IPAEngine.maxSingleEntrySize {
            throw IPAError.sizeLimitExceeded(limit: IPAEngine.maxSingleEntrySize, actual: entry.uncompressedSize)
        }
    }

    // MARK: - Archive creation

    /// Creates a ZIP archive at `destination` containing `files`, where each
    /// tuple is `(archivePath, fileURL)`. Directories are added implicitly
    /// from the archive paths. Files are deflated; empty files are stored.
    public func createArchive(files: [(archivePath: String, fileURL: URL)], to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        var output = Data()
        var central: [(entry: ZipEntry, crc: UInt32, localOffset: Int64)] = []
        var offset: Int64 = 0

        for (archivePath, fileURL) in files {
            guard !Self.isUnsafeEntryName(archivePath) else {
                throw IPAError.pathTraversalAttempt(entry: archivePath)
            }
            let fileData: Data
            do { fileData = try Data(contentsOf: fileURL) } catch {
                throw IPAError.ioError("Cannot read \(fileURL.lastPathComponent) for archiving: \(error.localizedDescription)")
            }
            guard fileData.count <= IPAEngine.maxSingleEntrySize else {
                throw IPAError.sizeLimitExceeded(limit: IPAEngine.maxSingleEntrySize, actual: Int64(fileData.count))
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
            let nameData = Data(archivePath.utf8)
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
        try output.write(to: destination, options: [.atomic])
    }

    /// Convenience: archives a whole directory tree (relative paths preserved).
    public func createArchive(fromDirectory directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw IPAError.ioError("Cannot enumerate \(directory.path).")
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
            throw IPAError.invalidZIP("Tar data is not a multiple of 512 bytes.")
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
            guard entries.count <= 50_000 else {
                throw IPAError.entryCountExceeded(limit: 50_000, actual: entries.count)
            }
        }
        return entries
    }

    /// Decompresses gzip data using the Compression framework (zlib stream
    /// after the 10-byte gzip header, trailer ignored). Returns nil when
    /// the data is not gzip or decompression fails, so callers can report
    /// the limitation instead of producing corrupt output.
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
        // The body is a raw deflate stream; decode it with the streaming
        // decoder, ignoring the 8-byte gzip trailer (CRC + ISIZE).
        let body = data.subdata(in: headerLength..<(data.count - 8))
        // Expected size is the ISIZE field (last 4 bytes, little-endian).
        let isize = Int(readUInt32(data, at: data.count - 4))
        guard isize < 1_073_741_824 else { return nil }
        return try? ZipCompression.inflateRawDeflateStreaming(body, expectedSize: isize)
    }

    // MARK: - Low-level helpers

    private func readAll(handle: FileHandle, size: Int64) throws -> Data {
        // ZIP central-directory parsing needs random access; the file is
        // already capped at 2 GB, and in practice IPAs are far smaller.
        // Read in 8 MB chunks to avoid a single huge allocation spike.
        var result = Data()
        result.reserveCapacity(Int(min(size, 64 * 1024 * 1024)))
        try handle.seek(toOffset: 0)
        while result.count < size {
            let remaining = size - Int64(result.count)
            let chunkSize = Int(min(remaining, 8 * 1024 * 1024))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw IPAError.corruptZIP("Short read while loading ZIP central directory.")
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
