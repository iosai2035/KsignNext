import XCTest
@testable import KsignNext

/// Sources view model ↔ engine wiring: the view model must register
/// sources with `SourcesEngine` (not keep a parallel list), refresh
/// through the engine (never `clearCache()`, which drops every
/// registered source), and list the NEWEST version of each app.
final class SourcesViewModelTests: XCTestCase {

    /// Serves one canned response for every request, so the engine's
    /// network fetch runs without touching the network.
    private final class StubURLProtocol: URLProtocol {
        static var responseData: Data?
        static var statusCode: Int = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.statusCode,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = Self.responseData { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Two apps: "App One" lists 1.0 before 2.0 in the file (so
    /// `versions.first` would show the OLD version), and "App Two"
    /// carries a malformed icon URL (it must still list).
    private var fixture: String {
        """
        {
          "name": "Test Source",
          "identifier": "com.example.test",
          "apps": [
            {
              "name": "App One",
              "bundleIdentifier": "com.example.one",
              "developerName": "Example",
              "iconURL": "https://example.com/one.png",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-01T10:30:00Z",
                  "downloadURL": "https://example.com/one-1.ipa",
                  "size": 100
                },
                {
                  "version": "2.0",
                  "date": "2024-02-01T10:30:00Z",
                  "downloadURL": "https://example.com/one-2.ipa",
                  "size": 200
                }
              ]
            },
            {
              "name": "App Two",
              "bundleIdentifier": "com.example.two",
              "developerName": "Example",
              "iconURL": "not a url :::",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-01T10:30:00Z",
                  "downloadURL": "https://example.com/two.ipa",
                  "size": 100
                }
              ]
            }
          ]
        }
        """
    }

    private let storageKey = "ksign.sources"

    private func makeViewModel() -> SourcesViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let engine = SourcesEngine(urlSession: session)
        let container = DependencyContainer(sourcesEngine: engine)
        return SourcesViewModel(container: container)
    }

    override func setUp() {
        super.setUp()
        // The view model persists to shared UserDefaults; clear it so
        // no other test's leftovers (and none of ours) leak in.
        UserDefaults.standard.removeObject(forKey: storageKey)
        StubURLProtocol.responseData = Data(fixture.utf8)
        StubURLProtocol.statusCode = 200
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        StubURLProtocol.responseData = nil
        super.tearDown()
    }

    @MainActor
    func testAddSourceRegistersWithEngine() async throws {
        let vm = makeViewModel()
        vm.newSourceName = "Test Source"
        vm.newSourceURL = "https://example.com/apps.json"
        await vm.addSource()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sources.count, 1)
        let item = try XCTUnwrap(vm.sources.first)
        XCTAssertEqual(item.status, .active)
        XCTAssertEqual(item.appCount, 2)
        XCTAssertNotNil(item.engineID, "The item must carry the engine id, or refreshes cannot find it")
    }

    @MainActor
    func testFetchAppsListsNewestVersionAndKeepsBadIconApp() async throws {
        let vm = makeViewModel()
        vm.newSourceName = "Test Source"
        vm.newSourceURL = "https://example.com/apps.json"
        await vm.addSource()
        let item = try XCTUnwrap(vm.sources.first)
        let apps = await vm.fetchApps(for: item)
        XCTAssertEqual(apps.count, 2)
        // Newest version, not the first one listed in the file.
        XCTAssertEqual(apps.first { $0.name == "App One" }?.version, "2.0")
        XCTAssertEqual(apps.first { $0.name == "App One" }?.downloadURLString, "https://example.com/one-2.ipa")
        // A malformed icon URL must not drop the app.
        XCTAssertNotNil(apps.first { $0.name == "App Two" })
    }

    @MainActor
    func testRefreshKeepsEngineRegistration() async throws {
        let vm = makeViewModel()
        vm.newSourceName = "Test Source"
        vm.newSourceURL = "https://example.com/apps.json"
        await vm.addSource()
        let item = try XCTUnwrap(vm.sources.first)
        await vm.refresh(item)
        XCTAssertNil(vm.errorMessage)
        let refreshed = try XCTUnwrap(vm.sources.first)
        XCTAssertEqual(refreshed.status, .active)
        XCTAssertEqual(refreshed.appCount, 2)
        XCTAssertEqual(refreshed.engineID, item.engineID)
        // The apps must still list after a refresh: the old code
        // cleared the engine cache first, which dropped every
        // registered source and made this return [].
        let apps = await vm.fetchApps(for: refreshed)
        XCTAssertEqual(apps.count, 2)
    }

    @MainActor
    func testRemoveAlsoRemovesFromEngine() async throws {
        let vm = makeViewModel()
        vm.newSourceName = "Test Source"
        vm.newSourceURL = "https://example.com/apps.json"
        await vm.addSource()
        let item = try XCTUnwrap(vm.sources.first)
        await vm.remove(item)
        XCTAssertTrue(vm.sources.isEmpty)
        // Re-adding the same URL must succeed: a stale engine
        // record would reject it as a duplicate.
        vm.newSourceName = "Test Source"
        vm.newSourceURL = "https://example.com/apps.json"
        await vm.addSource()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sources.count, 1)
    }

    /// Items stored before the engine-id / status / app-count fields
    /// existed must still decode, with defaults, instead of dropping
    /// the whole stored list.
    func testLegacyStoredItemDecodesWithDefaults() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Old","urlString":"https://example.com/apps.json","lastRefreshed":null}]
        """
        let items = try JSONDecoder().decode([SourceItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Old")
        XCTAssertNil(items[0].engineID)
        XCTAssertEqual(items[0].status, .active)
        XCTAssertEqual(items[0].appCount, 0)
    }
}
