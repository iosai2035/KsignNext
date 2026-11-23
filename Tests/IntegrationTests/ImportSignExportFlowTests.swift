import XCTest
@testable import KsignNext


/// Import -> inspect -> sign attempt -> verify -> export, end to end at the
/// view-model level. The signing step asserts the honest unavailable-backend
/// error when zsign is not linked — it never fakes success.
// The view models under test are @MainActor, so the whole test class
// runs on the main actor and may call their init, properties and methods directly.
@MainActor
final class ImportSignExportFlowTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ksign-flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testImportInspectSignAttemptVerifyExportFlow() async throws {
        // 1. Import: copy a small ZIP fixture into the workspace.
        let ipaData = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02, 0x03])
        let source = tempDir.appendingPathComponent("FlowApp.ipa")
        try ipaData.write(to: source)
        let appsVM = ApplicationsViewModel()
        appsVM.importIPA(source)
        XCTAssertNil(appsVM.errorMessage)

        // 2. Inspect: ZIP magic is recognised.
        let stored = StoredApp(url: source)
        let detailVM = ApplicationDetailViewModel(app: stored)
        detailVM.inspect()
        XCTAssertNil(detailVM.errorMessage)
        XCTAssertEqual(detailVM.inspection.displayName, "FlowApp")

        // 3. Sign attempt: honest unavailable-backend error.
        let signingVM = SigningCenterViewModel()
        signingVM.selectedAppName = "FlowApp.ipa"
        signingVM.selectedCertificateName = "cert.p12"
        signingVM.bundleID = "com.example.flowapp"
        XCTAssertTrue(signingVM.canAdvance(from: .bundleID))
        do {
            _ = try await UnavailableSigningService().sign(appURL: source, certificateName: "cert.p12", bundleID: "com.example.flowapp")
            XCTFail("Must throw the unavailable-backend error")
        } catch let error as SigningBackendError {
            XCTAssertEqual(error, .backendNotLinked)
        }

        // 4. Verify: no output exists, so verification is false.
        signingVM.verifySignedApp()
        XCTAssertEqual(signingVM.verificationPassed, false)

        // 5. Export: no signed output to export.
        XCTAssertNil(signingVM.exportSignedApp())
    }

    func testHexEditorChunkedReading() {
        // 64 KB chunking: a 200 KB file must be readable page by page without loading it all.
        let url = tempDir.appendingPathComponent("big.bin")
        let data = Data((0..<200_000).map { UInt8($0 % 256) })
        try? data.write(to: url)
        let vm = HexEditorViewModel()
        vm.open(url)
        XCTAssertEqual(vm.pageCount, 4) // 200000 / 65536 -> 4 pages
        XCTAssertEqual(vm.pageData.count, HexEditorViewModel.chunkSize)
        vm.loadPage(3)
        XCTAssertEqual(vm.pageData.count, 200_000 - 3 * HexEditorViewModel.chunkSize)
    }

    func testPlistEditorRoundTripInFlow() {
        let url = tempDir.appendingPathComponent("Info.plist")
        let dict: [String: Any] = ["CFBundleIdentifier": "com.example.flowapp"]
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try? data?.write(to: url)
        let vm = PlistEditorViewModel()
        vm.open(url)
        XCTAssertEqual(vm.root["CFBundleIdentifier"] as? String, "com.example.flowapp")
        vm.setValue(key: "CFBundleVersion", value: "2.0")
        XCTAssertTrue(vm.save())
        let reloaded = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
        XCTAssertEqual(reloaded?["CFBundleVersion"] as? String, "2.0")
    }
}
