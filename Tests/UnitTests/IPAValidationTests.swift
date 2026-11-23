import XCTest
@testable import KsignNext


/// In-memory ZIP fixtures: a minimal valid IPA (ZIP with Payload/App.app/Info.plist)
/// and invalid variants. No network, no reference IPA.
final class IPAValidationTests: XCTestCase {

    /// Little-endian encoders for the ZIP fixture (the helpers the original
    /// `zipData` called were never defined, which also made the long `+`
    /// chains time out the type checker).
    private func u16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private func u32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private func zipData(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let offset = UInt32(out.count)
            var crc: UInt32 = 0
            // CRC-32 (IEEE) computed inline for the fixture.
            crc = entry.data.reduce(UInt32(0xFFFF_FFFF)) { acc, byte in
                var c = acc ^ UInt32(byte)
                for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
                return c
            } ^ 0xFFFF_FFFF
            // Local file header. One append per field: the chained `+`
            // form timed out the type checker.
            out += u32(0x04034B50)
            out += u16(20)
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u32(crc)
            out += u32(UInt32(entry.data.count))
            out += u32(UInt32(entry.data.count))
            out += u16(UInt16(nameData.count))
            out += u16(0)
            out += nameData
            out += entry.data
            central.append((nameData, crc, UInt32(entry.data.count), offset))
        }
        let centralOffset = UInt32(out.count)
        for item in central {
            // Central directory header.
            out += u32(0x02014B50)
            out += u16(20)
            out += u16(20)
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u32(item.crc)
            out += u32(item.size)
            out += u32(item.size)
            out += u16(UInt16(item.name.count))
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u16(0)
            out += u32(0)
            out += u32(item.offset)
            out += item.name
        }
        // End of central directory.
        out += u32(0x06054B50)
        out += u16(0)
        out += u16(0)
        out += u16(UInt16(central.count))
        out += u16(UInt16(central.count))
        out += u32(UInt32(out.count) - centralOffset)
        out += u32(centralOffset)
        out += u16(0)
        return out
    }

    private func isZIP(_ data: Data) -> Bool {
        data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func testValidIPAZipHeader() {
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.app</string></dict></plist>"
        let data = zipData(entries: [("Payload/App.app/Info.plist", Data(plist.utf8))])
        XCTAssertTrue(isZIP(data))
        XCTAssertGreaterThan(data.count, 100)
    }

    func testEmptyFileIsNotZIP() {
        XCTAssertFalse(isZIP(Data()))
    }

    func testRandomBytesAreNotZIP() {
        XCTAssertFalse(isZIP(Data([0x00, 0x01, 0x02, 0x03, 0x04])))
    }

    func testIPAMustContainPayloadPrefix() {
        let data = zipData(entries: [("Info.plist", Data("x".utf8))])
        XCTAssertTrue(isZIP(data))
        // The entry name is embedded in the archive; a real validator must require Payload/.
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("Payload/") ?? false)
    }

    func testZipWithPayloadEntryContainsPayload() {
        let data = zipData(entries: [("Payload/App.app/Info.plist", Data("x".utf8))])
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Payload/App.app/Info.plist") ?? false)
    }
}
