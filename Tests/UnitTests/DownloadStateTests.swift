import XCTest
@testable import KsignNext

// The view model under test is @MainActor, so the whole test class runs
// on the main actor and may call its init, properties and methods directly.
@MainActor
final class DownloadStateTests: XCTestCase {

    func testHTTPURLRejected() {
        let vm = DownloadsViewModel()
        vm.newURLString = "http://example.com/app.ipa"
        vm.addDownload()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.downloads.isEmpty)
    }

    func testNonURLRejected() {
        let vm = DownloadsViewModel()
        vm.newURLString = "not a url"
        vm.addDownload()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.downloads.isEmpty)
    }

    func testEmptyURLRejected() {
        let vm = DownloadsViewModel()
        vm.newURLString = "   "
        vm.addDownload()
        XCTAssertNotNil(vm.errorMessage)
    }

    func testInitialStateIsQueued() {
        let item = DownloadItem(urlString: "https://example.com/app.ipa", fileName: "app.ipa")
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.progress, 0)
        XCTAssertEqual(item.etaText, "—")
    }

    func testPauseResumeDelete() {
        let vm = DownloadsViewModel()
        let item = DownloadItem(urlString: "https://example.com/app.ipa", fileName: "app.ipa")
        vm.downloads = [item]
        vm.pause(item)
        XCTAssertEqual(vm.downloads.first?.state, .paused)
        vm.delete(item)
        XCTAssertTrue(vm.downloads.isEmpty)
    }
}
