import XCTest
@testable import KsignNext


final class MachOParserTests: XCTestCase {

    private func arm64Header() -> Data {
        // MH_MAGIC_64 (0xFEEDFACF, little-endian bytes CF FA ED FE) + cputype arm64 (0x0100000C).
        var data = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        data += Data(repeating: 0, count: 24)
        return data
    }

    private func architecture(of data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes == [0xCF, 0xFA, 0xED, 0xFE] { return "arm64" }
        if bytes == [0xCE, 0xFA, 0xED, 0xFE] { return "armv7" }
        if bytes == [0xCA, 0xFE, 0xBA, 0xBE] { return "fat" }
        return nil
    }

    func testArm64MagicDetected() {
        XCTAssertEqual(architecture(of: arm64Header()), "arm64")
    }

    func testArmv7MagicDetected() {
        XCTAssertEqual(architecture(of: Data([0xCE, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])), "armv7")
    }

    func testFatMagicDetected() {
        XCTAssertEqual(architecture(of: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0])), "fat")
    }

    func testNonMachORejected() {
        XCTAssertNil(architecture(of: Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertNil(architecture(of: Data()))
        XCTAssertNil(architecture(of: Data([0x7F, 0x45, 0x4C, 0x46]))) // ELF
    }

    func testShortHeaderRejected() {
        XCTAssertNil(architecture(of: Data([0xCF, 0xFA])))
    }

    func testReportFromViewModel() {
        let vm = MachOInspectorViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-macho-\(UUID().uuidString)")
        try? arm64Header().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        vm.inspect(url)
        XCTAssertEqual(vm.report.architecture, "arm64")
        XCTAssertTrue(vm.report.errorMessage.isEmpty)
    }

    func testReportRejectsNonMachOFile() {
        let vm = MachOInspectorViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-notmacho-\(UUID().uuidString)")
        try? Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        vm.inspect(url)
        XCTAssertFalse(vm.report.errorMessage.isEmpty)
    }
}
