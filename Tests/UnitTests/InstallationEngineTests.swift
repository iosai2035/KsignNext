import XCTest
@testable import KsignNext


/// Real end-to-end test of the installation server: build a tiny valid
/// IPA in memory, prepare an install, fetch the served IPA + manifest
/// over plain HTTP from the session's own URLs, and stop. No external
/// network; the fetch goes to loopback even when the server advertises
/// a LAN address (it binds 0.0.0.0).
final class InstallationEngineTests: XCTestCase {

    /// Little-endian encoders for the ZIP fixture (same pattern as
    /// IPAValidationTests).
    private func u16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private func u32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    /// Minimal valid ZIP (stored entries, correct CRC-32), one append
    /// per field so the type checker stays fast.
    private func zipData(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let offset = UInt32(out.count)
            var crc: UInt32 = 0
            crc = entry.data.reduce(UInt32(0xFFFF_FFFF)) { acc, byte in
                var c = acc ^ UInt32(byte)
                for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
                return c
            } ^ 0xFFFF_FFFF
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

    func testPrepareInstallServesIPAAndManifest() async throws {
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.installtest</string><key>CFBundleExecutable</key><string>InstallTest</string><key>CFBundleName</key><string>InstallTest</string><key>CFBundleVersion</key><string>1.2.3</string></dict></plist>"
        let ipaData = zipData(entries: [("Payload/InstallTest.app/Info.plist", Data(plist.utf8))])
        let ipaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallTest-\(UUID().uuidString).ipa")
        try ipaData.write(to: ipaURL)
        defer { try? FileManager.default.removeItem(at: ipaURL) }

        let engine = InstallationEngine(server: NIOInstallationServer())
        let session = try await engine.prepareInstall(
            ipaURL: ipaURL,
            bundleIdentifier: "com.example.installtest",
            bundleVersion: "1.2.3",
            title: "InstallTest",
            timeout: 60
        )

        XCTAssertTrue(engine.isServing)
        XCTAssertTrue(session.installURL.absoluteString.hasPrefix("itms-services://"))
        XCTAssertTrue(session.installURL.absoluteString.contains("manifest.plist"))

        // Fetch from the session's own base URL, but rewritten to
        // loopback: the server binds 0.0.0.0, so loopback always works,
        // and it stays inside App Transport Security's localhost
        // exemption even when the advertised host is a LAN address.
        var components = URLComponents(url: session.manifestURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false)
        components?.host = "127.0.0.1"
        guard let loopbackBase = components?.url else {
            XCTFail("Could not build the loopback base URL from \(session.manifestURL)")
            await engine.stopServing()
            return
        }
        let (servedIPA, ipaResponse) = try await URLSession.shared.data(from: loopbackBase.appendingPathComponent("app.ipa"))
        XCTAssertEqual((ipaResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(servedIPA, ipaData)

        let (servedManifest, manifestResponse) = try await URLSession.shared.data(from: loopbackBase.appendingPathComponent("manifest.plist"))
        XCTAssertEqual((manifestResponse as? HTTPURLResponse)?.statusCode, 200)
        let manifest = String(data: servedManifest, encoding: .utf8) ?? ""
        XCTAssertTrue(manifest.contains("com.example.installtest"), "Manifest must name the bundle id: \(manifest)")
        XCTAssertTrue(manifest.contains("1.2.3"), "Manifest must name the bundle version: \(manifest)")

        await engine.stopServing()
        XCTAssertFalse(engine.isServing)
    }

    /// Same-device install needs no Wi-Fi: `.thisDevice` must advertise
    /// loopback (127.0.0.1) in the manifest and install URLs, and the
    /// served IPA must be fetchable from that loopback base URL.
    func testPrepareInstallThisDeviceUsesLoopback() async throws {
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.installtest</string><key>CFBundleExecutable</key><string>InstallTest</string><key>CFBundleName</key><string>InstallTest</string><key>CFBundleVersion</key><string>1.2.3</string></dict></plist>"
        let ipaData = zipData(entries: [("Payload/InstallTest.app/Info.plist", Data(plist.utf8))])
        let ipaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallTest-\(UUID().uuidString).ipa")
        try ipaData.write(to: ipaURL)
        defer { try? FileManager.default.removeItem(at: ipaURL) }

        let engine = InstallationEngine(server: NIOInstallationServer())
        let session = try await engine.prepareInstall(
            ipaURL: ipaURL,
            bundleIdentifier: "com.example.installtest",
            bundleVersion: "1.2.3",
            title: "InstallTest",
            destination: .thisDevice,
            timeout: 60
        )

        XCTAssertTrue(engine.isServing)
        XCTAssertEqual(session.manifestURL.host, "127.0.0.1", "Same-device install must use loopback: \(session.manifestURL)")
        XCTAssertTrue(session.installURL.absoluteString.contains("127.0.0.1"), "Install URL must use loopback: \(session.installURL)")

        let loopbackBase = session.manifestURL.deletingLastPathComponent()
        let (servedIPA, ipaResponse) = try await URLSession.shared.data(from: loopbackBase.appendingPathComponent("app.ipa"))
        XCTAssertEqual((ipaResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(servedIPA, ipaData)

        await engine.stopServing()
        XCTAssertFalse(engine.isServing)
    }
}
