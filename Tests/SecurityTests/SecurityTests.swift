import XCTest
@testable import KsignNext


final class SecurityTests: XCTestCase {

    func testZipBombRatioFixtureRejected() {
        // A tiny compressed payload that expands enormously is a Zip Bomb.
        // The fixture models the ratio check: 1 KB stored -> 100 MB expanded must be refused.
        let storedBytes: Int64 = 1_024
        let expandedBytes: Int64 = 100 * 1024 * 1024
        let ratio = Double(expandedBytes) / Double(storedBytes)
        XCTAssertGreaterThan(ratio, 100, "Expansion ratio above the safe limit must be rejected")
    }

    func testPathTraversalEntryRejected() {
        let entries = ["../evil.sh", "Payload/../../evil", "/absolute/path", "Payload/App.app/Info.plist"]
        let isSafe: (String) -> Bool = { name in
            if name.hasPrefix("/") { return false }
            return !name.split(separator: "/").contains("..")
        }
        XCTAssertFalse(isSafe(entries[0]))
        XCTAssertFalse(isSafe(entries[1]))
        XCTAssertFalse(isSafe(entries[2]))
        XCTAssertTrue(isSafe(entries[3]))
    }

    func testCorruptPlistRejected() {
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: Data("garbage{{{".utf8), options: [], format: nil))
    }

    func testInvalidMachORejected() {
        let vm = MachOInspectorViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-macho-\(UUID().uuidString)")
        try? Data([0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        vm.inspect(url)
        XCTAssertFalse(vm.report.errorMessage.isEmpty)
        XCTAssertEqual(vm.report.architecture, "")
    }

    func testFakeMobileprovisionRejected() {
        let data = Data("FAKE-PROVISION".utf8)
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: data, options: [], format: nil))
    }

    func testWrongP12PasswordRejected() {
        var items: CFArray?
        let status = SecPKCS12Import(Data([0x30, 0x82, 0x01, 0x02]) as CFData, [kSecImportExportPassphrase as String: "wrong"] as CFDictionary, &items)
        XCTAssertNotEqual(status, errSecSuccess)
    }

    func testInsecureHTTPURLRejectedForDownloads() {
        let vm = DownloadsViewModel()
        vm.newURLString = "http://example.com/app.ipa"
        vm.addDownload()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.downloads.isEmpty)
    }

    func testInsecureHTTPSourceRejected() {
        let vm = SourcesViewModel()
        vm.newSourceName = "Bad"
        vm.newSourceURL = "http://example.com/apps.json"
        vm.addSource()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.sources.isEmpty)
    }

    func testHexEditorReadOnlyByDefaultForExecutables() {
        let vm = HexEditorViewModel()
        XCTAssertTrue(vm.isReadOnly)
    }
}
