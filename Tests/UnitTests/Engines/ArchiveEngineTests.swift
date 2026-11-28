import XCTest
@testable import KsignNext

/// Regression tests for the deflate bug (M10 fix — see
/// Documentation/Import-Deflate-Diagnosis-2026-11-28.md): the old ZIP
/// reader decoded method 8 through a fake zlib wrapper and rejected
/// every real IPA, while CI stayed green because every fixture used
/// stored (method 0) entries only. These tests pin the fixed path:
/// real deflate round-trips, a real method-8 fixture, CRC verification,
/// size limits, gunzip, and the negative controls.
///
/// Fixture loading: the test target does not bundle fixture files (the
/// project generator only adds `.swift` files under `Tests/`), so the
/// committed fixture is located via `#filePath` relative to the repo
/// checkout. Tests run on the same checkout they were built from in CI.
final class ArchiveEngineTests: XCTestCase {

    private let engine = ArchiveEngine()

    // MARK: - Helpers

    /// Locates Tests/Fixtures/Archive/minimal-ipa-method8.zip by walking
    /// up from this test file until the fixture exists (bounded search,
    /// so the test survives the file being moved within the repo).
    /// Falls back to the documented 3-level path so the fileExists
    /// assertion in the fixture test still reports the expected path.
    private var fixtureURL: URL {
        let fileManager = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("Fixtures/Archive/minimal-ipa-method8.zip")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            // The fixture lives under Tests/; keep walking up while the
            // parent still looks like the repo (stop at the filesystem root).
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Engines
            .deletingLastPathComponent() // UnitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/Archive/minimal-ipa-method8.zip")
    }

    /// The exact Info.plist bytes of the fixture (base64), for a
    /// byte-for-byte assertion. Generated from the fixture file itself.
    private var expectedFixturePlist: Data {
        // swiftlint:disable:next line_length
        let base64 = "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHBsaXN0IFBVQkxJQyAiLS8vQXBwbGUvL0RURCBQTElTVCAxLjAvL0VOIiAiaHR0cDovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+CjxwbGlzdCB2ZXJzaW9uPSIxLjAiPgo8ZGljdD4KCTxrZXk+Q0ZCdW5kbGVJZGVudGlmaWVyPC9rZXk+Cgk8c3RyaW5nPmNvbS5leGFtcGxlLlRlc3RBcHA8L3N0cmluZz4KCTxrZXk+Q0ZCdW5kbGVOYW1lPC9rZXk+Cgk8c3RyaW5nPlRlc3RBcHA8L3N0cmluZz4KCTxrZXk+Q0ZCdW5kbGVFeGVjdXRhYmxlPC9rZXk+Cgk8c3RyaW5nPlRlc3RBcHA8L3N0cmluZz4KCTxrZXk+Q0ZCdW5kbGVWZXJzaW9uPC9rZXk+Cgk8c3RyaW5nPjE8L3N0cmluZz4KCTxrZXk+Q0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmc8L2tleT4KCTxzdHJpbmc+MS4wPC9zdHJpbmc+Cgk8a2V5Pk1pbmltdW1PU1ZlcnNpb248L2tleT4KCTxzdHJpbmc+MTYuMDwvc3RyaW5nPgo8L2RpY3Q+CjwvcGxpc3Q+Cg=="
        guard let data = Data(base64Encoded: base64) else {
            XCTFail("Test bug: embedded fixture plist is not valid base64.")
            return Data()
        }
        return data
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Asserts the expression throws exactly `AppError.ipa` with a case
    /// matching `check` (D.5: exact error cases, never just "throws").
    private func assertThrowsIPA<T>(
        _ expression: @autoclosure () throws -> T,
        matching check: (IPAError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let appError = error as? AppError,
                  case .ipa(let ipaError) = appError,
                  check(ipaError) else {
                XCTFail("Expected AppError.ipa, got \(error)", file: file, line: line)
                return
            }
        }
    }

    /// One entry of a synthetic ZIP built by `makeZIPData`.
    private struct TestZIPEntry {
        var name: String
        var method: UInt16
        /// Raw bytes as stored in the archive (stored bytes, or deflate bytes).
        var payload: Data
        var crc: UInt32
        var uncompressedSize: Int64
        var externalAttributes: UInt32 = 0
    }

    /// Builds a minimal valid ZIP32 archive in memory with fully
    /// controllable per-entry fields (method, CRC, declared sizes,
    /// external attributes), so negative cases can be constructed
    /// exactly. No data descriptors are written; sizes in the local
    /// header match the central directory.
    private func makeZIPData(_ entries: [TestZIPEntry]) -> Data {
        var out = Data()
        var central: [(entry: TestZIPEntry, offset: Int64)] = []
        var offset: Int64 = 0
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0x0800)
            local.appendUInt16(entry.method)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(entry.crc)
            local.appendUInt32(UInt32(entry.payload.count))
            local.appendUInt32(UInt32(entry.uncompressedSize))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            local.append(entry.payload)
            out.append(local)
            central.append((entry, offset))
            offset += Int64(local.count)
        }
        let centralOffset = offset
        for (entry, localOffset) in central {
            let nameData = Data(entry.name.utf8)
            var record = Data()
            record.appendUInt32(0x02014b50)
            record.appendUInt16(20)
            record.appendUInt16(20)
            record.appendUInt16(0x0800)
            record.appendUInt16(entry.method)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(entry.crc)
            record.appendUInt32(UInt32(entry.payload.count))
            record.appendUInt32(UInt32(entry.uncompressedSize))
            record.appendUInt16(UInt16(nameData.count))
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(entry.externalAttributes)
            record.appendUInt32(UInt32(localOffset))
            record.append(nameData)
            out.append(record)
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
        out.append(eocd)
        return out
    }

    private func writeZIP(_ data: Data, named name: String = "test.zip") throws -> URL {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Builds a minimal gzip stream: 10-byte header + raw-deflate body
    /// + CRC-32 + ISIZE trailer. `corruptCRC` flips the trailer CRC.
    private func makeGzipData(_ payload: Data, fileName: String? = nil, corruptCRC: Bool = false) throws -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        if let fileName {
            out[3] = out[3] | 0x08 // FNAME
            out.append(Data(fileName.utf8))
            out.append(0)
        }
        out.append(try ZipCompression.deflateRaw(payload))
        var crc = CRC32.checksum(payload)
        if corruptCRC { crc ^= 0xFFFFFFFF }
        var crcLE = crc.littleEndian
        out.append(Data(bytes: &crcLE, count: 4))
        var isize = UInt32(payload.count).littleEndian
        out.append(Data(bytes: &isize, count: 4))
        return out
    }

    // MARK: - Raw deflate (the fix)

    /// Real deflate round-trip: encode then decode, byte-for-byte match.
    /// This is the test that would have caught the fake-wrapper bug.
    func testInflateRawDeflate_roundTripByteIdentical() throws {
        let original = Data((0..<100_000).map { UInt8($0 % 251) })
        let compressed = try ZipCompression.deflateRaw(original)
        XCTAssertLessThan(compressed.count, original.count)
        let decoded = try ZipCompression.inflateRawDeflate(compressed, expectedSize: original.count)
        XCTAssertEqual(decoded, original)
    }

    func testInflateRawDeflate_emptyInputReturnsEmpty() throws {
        let emptyBlock = try ZipCompression.deflateRaw(Data())
        XCTAssertEqual(emptyBlock, Data([0x03, 0x00]))
        XCTAssertEqual(try ZipCompression.inflateRawDeflate(emptyBlock, expectedSize: 0), Data())
        XCTAssertEqual(try ZipCompression.inflateRawDeflate(Data(), expectedSize: 0), Data())
    }

    func testDeflateRaw_emptyProducesEmptyStoredBlock() throws {
        XCTAssertEqual(try ZipCompression.deflateRaw(Data()), Data([0x03, 0x00]))
    }

    /// Negative control: garbage bytes are not a deflate stream.
    func testInflateRawDeflate_corruptInputThrowsCorruptZIP() throws {
        let original = Data((0..<100_000).map { UInt8($0 % 251) })
        var compressed = try ZipCompression.deflateRaw(original)
        // Flip bytes in the middle of the deflate body so the bitstream
        // itself is invalid (not just truncated).
        for index in [compressed.count / 3, compressed.count / 3 + 1, compressed.count / 2] {
            compressed[index] ^= 0xFF
        }
        assertThrowsIPA(try ZipCompression.inflateRawDeflate(compressed, expectedSize: original.count)) { error in
            if case .corruptZIP = error { return true }
            return false
        }
    }

    /// Negative control: a valid stream cut in half is truncated, not valid.
    func testInflateRawDeflate_truncatedInputThrowsCorruptZIP() throws {
        let original = Data((0..<10_000).map { UInt8($0 % 251) })
        let compressed = try ZipCompression.deflateRaw(original)
        let truncated = compressed.subdata(in: 0..<(compressed.count / 2))
        assertThrowsIPA(try ZipCompression.inflateRawDeflate(truncated, expectedSize: original.count)) { error in
            if case .corruptZIP = error { return true }
            return false
        }
    }

    func testInflateRawDeflate_negativeExpectedSizeThrowsInvalidZIP() {
        XCTAssertThrowsError(try ZipCompression.inflateRawDeflate(Data([0x03, 0x00]), expectedSize: -1)) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.ipa(.invalidZIP("Negative expected uncompressed size.")))
        }
    }

    func testInflateRawDeflate_oversizedExpectedSizeThrowsSizeLimitExceeded() {
        let tooBig = Int(FileSystemManager.maxSingleFileBytes) + 1
        XCTAssertThrowsError(try ZipCompression.inflateRawDeflate(Data([0x03, 0x00]), expectedSize: tooBig)) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.ipa(.sizeLimitExceeded(
                    limit: FileSystemManager.maxSingleFileBytes, actual: Int64(tooBig))))
        }
    }

    /// Pins the C layout the @_silgen_name bridge depends on: zlib's
    /// z_stream is 112 bytes on 64-bit LP64. If this fails, the mirror
    /// in CZlib no longer matches the linked zlib.
    func testZStreamLayoutIs112Bytes() {
        XCTAssertEqual(MemoryLayout<CZlib.ZStream>.size, 112)
        XCTAssertEqual(MemoryLayout<CZlib.ZStream>.stride, 112)
        XCTAssertEqual(MemoryLayout<CZlib.ZStream>.alignment, 8)
    }

    // MARK: - Fixture: minimal compressed IPA

    /// The M10 regression test: a real method-8 entry read through the
    /// full listEntries -> readEntryData path, byte-for-byte.
    func testMinimalIPA_method8InfoPlistExtracts() throws {
        let fixture = fixtureURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path),
                      "Fixture missing: \(fixture.path)")
        let entries = try engine.listEntries(at: fixture)
        XCTAssertEqual(entries.count, 2)
        guard let plistEntry = entries.first(where: { $0.name == "Payload/TestApp.app/Info.plist" }) else {
            XCTFail("Info.plist entry missing from fixture.")
            return
        }
        XCTAssertEqual(plistEntry.compressionMethod, 8)
        XCTAssertEqual(plistEntry.uncompressedSize, 526)
        XCTAssertEqual(plistEntry.crc32, 0xd3d4f4f4)
        let decoded = try engine.readEntryData(
            named: "Payload/TestApp.app/Info.plist", in: fixture)
        XCTAssertEqual(decoded, expectedFixturePlist)
        XCTAssertTrue(decoded.starts(with: Data("<?xml".utf8)))
        XCTAssertTrue(String(decoding: decoded, as: UTF8.self).contains("com.example.TestApp"))
    }

    /// Stored-entry (method 0) control from the same fixture.
    func testMinimalIPA_storedEntryControl() throws {
        let fixture = fixtureURL
        let decoded = try engine.readEntryData(
            named: "Payload/TestApp.app/TestApp", in: fixture)
        XCTAssertEqual(decoded, Data("dummy-executable-bytes".utf8))
    }

    // MARK: - In-memory archives (no fixture dependency)

    /// createArchive deflates non-empty files; reading them back must be
    /// byte-identical, and empty files stay stored.
    func testCreateArchive_deflatedRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plistURL = dir.appendingPathComponent("Info.plist")
        let emptyURL = dir.appendingPathComponent("Empty.txt")
        try expectedFixturePlist.write(to: plistURL)
        try Data().write(to: emptyURL)
        let archiveURL = dir.appendingPathComponent("roundtrip.zip")
        try engine.createArchive(files: [
            (archivePath: "Payload/TestApp.app/Info.plist", fileURL: plistURL),
            (archivePath: "Payload/TestApp.app/Empty.txt", fileURL: emptyURL),
        ], to: archiveURL)
        let entries = try engine.listEntries(at: archiveURL)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first(where: { $0.name.hasSuffix("Info.plist") })?.compressionMethod, 8)
        XCTAssertEqual(entries.first(where: { $0.name.hasSuffix("Empty.txt") })?.compressionMethod, 0)
        XCTAssertEqual(
            try engine.readEntryData(named: "Payload/TestApp.app/Info.plist", in: archiveURL),
            expectedFixturePlist)
        XCTAssertEqual(
            try engine.readEntryData(named: "Payload/TestApp.app/Empty.txt", in: archiveURL),
            Data())
    }

    /// Non-empty stored (method 0) entry round-trips byte-for-byte.
    func testStoredEntry_nonEmptyRoundTrip() throws {
        let content = Data("stored-content, never compressed".utf8)
        let zip = makeZIPData([TestZIPEntry(
            name: "stored.txt", method: 0, payload: content,
            crc: CRC32.checksum(content), uncompressedSize: Int64(content.count))])
        let url = try writeZIP(zip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try engine.readEntryData(named: "stored.txt", in: url), content)
    }

    /// A CRC-32 mismatch between the decoded bytes and the central
    /// directory is rejected, even when the deflate stream itself is valid.
    func testCRC32MismatchRejected() throws {
        let content = Data("crc-protected content".utf8)
        let zip = makeZIPData([TestZIPEntry(
            name: "file.txt", method: 8, payload: try ZipCompression.deflateRaw(content),
            crc: 0xDEADBEEF, uncompressedSize: Int64(content.count))])
        let url = try writeZIP(zip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        assertThrowsIPA(try engine.readEntryData(named: "file.txt", in: url)) { error in
            if case .corruptZIP = error { return true }
            return false
        }
    }

    /// An entry declaring an uncompressed size over the §B.3 single-file
    /// cap is rejected before any decoding happens.
    func testOversizedEntryRejected() throws {
        let content = Data("small".utf8)
        let tooBig = FileSystemManager.maxSingleFileBytes + 1
        let zip = makeZIPData([TestZIPEntry(
            name: "huge.bin", method: 8, payload: try ZipCompression.deflateRaw(content),
            crc: CRC32.checksum(content), uncompressedSize: tooBig)])
        let url = try writeZIP(zip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try engine.readEntryData(named: "huge.bin", in: url)) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.ipa(.sizeLimitExceeded(
                    limit: FileSystemManager.maxSingleFileBytes, actual: tooBig)))
        }
    }

    /// ZIP64 is not supported: the 0xFFFFFFFF sentinel is rejected
    /// loudly instead of being treated as a (huge, wrong) size.
    func testZip64SentinelRejected() throws {
        let zip = makeZIPData([TestZIPEntry(
            name: "big.bin", method: 8, payload: Data([0x03, 0x00]),
            crc: 0, uncompressedSize: Int64(0xFFFFFFFF))])
        XCTAssertThrowsError(try engine.parseCentralDirectory(data: zip)) { error in
            XCTAssertEqual(
                error as? AppError,
                AppError.ipa(.invalidZIP("ZIP64 archives are not supported.")))
        }
    }

    // MARK: - Gunzip (same fix)

    /// Gzip round-trip: header + raw-deflate body + trailer, including
    /// the FNAME-flag header variant.
    func testGunzip_roundTrip() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        XCTAssertEqual(ArchiveEngine.gunzip(try makeGzipData(payload)), payload)
        XCTAssertEqual(ArchiveEngine.gunzip(try makeGzipData(payload, fileName: "data.tar")), payload)
    }

    /// A gzip trailer CRC mismatch is rejected (returns nil).
    func testGunzip_rejectsBadTrailerCRC() throws {
        let payload = Data("integrity matters".utf8)
        XCTAssertNil(ArchiveEngine.gunzip(try makeGzipData(payload, corruptCRC: true)))
    }

    /// Non-gzip input is reported as unsupported (nil), not decoded.
    func testGunzip_rejectsNonGzip() {
        XCTAssertNil(ArchiveEngine.gunzip(Data("this is not gzip".utf8)))
        XCTAssertNil(ArchiveEngine.gunzip(Data()))
    }

    // MARK: - Path / symlink safety (M11)

    func testEntryNameSafety() throws {
        XCTAssertTrue(ArchiveEngine.isUnsafeEntryName("../evil.txt"))
        XCTAssertTrue(ArchiveEngine.isUnsafeEntryName("/absolute/path"))
        XCTAssertTrue(ArchiveEngine.isUnsafeEntryName(""))
        XCTAssertTrue(ArchiveEngine.isUnsafeEntryName("a/../../b"))
        XCTAssertTrue(ArchiveEngine.isUnsafeEntryName("C:\\evil.txt"))
        XCTAssertFalse(ArchiveEngine.isUnsafeEntryName("Payload/TestApp.app/Info.plist"))
        let destination = URL(fileURLWithPath: "/tmp/dest")
        assertThrowsIPA(try ArchiveEngine.safeDestination(for: "../evil.txt", inside: destination)) { error in
            if case .pathTraversalAttempt = error { return true }
            return false
        }
        let safe = try ArchiveEngine.safeDestination(
            for: "Payload/TestApp.app/Info.plist", inside: destination)
        XCTAssertTrue(safe.path.hasPrefix(destination.standardizedFileURL.path))
    }

    /// A symlink entry is materialised as a regular file containing the
    /// target path string; no filesystem link is ever created (M11).
    func testExtractAll_symlinkMaterialisedAsRegularFile() throws {
        let target = Data("Payload/Target".utf8)
        // Unix mode 0120777: symlink file type in the high 16 bits.
        let symlinkMode: UInt32 = UInt32(0o120777) << 16
        let zip = makeZIPData([TestZIPEntry(
            name: "link", method: 0, payload: target,
            crc: CRC32.checksum(target), uncompressedSize: Int64(target.count),
            externalAttributes: symlinkMode)])
        let zipURL = try writeZIP(zip)
        let dir = zipURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try engine.listEntries(at: zipURL)
        XCTAssertEqual(entries.first?.isSymlink, true)
        let destination = dir.appendingPathComponent("extracted")
        let extracted = try engine.extractAll(from: zipURL, to: destination)
        XCTAssertEqual(extracted.count, 1)
        let linkURL = extracted[0]
        let attributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try Data(contentsOf: linkURL), target)
    }
}
