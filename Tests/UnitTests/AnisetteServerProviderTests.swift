import XCTest
@testable import KsignNext

/// Anisette server selection, URL validation, rotation, and the
/// defensive remote-list parser. The live fetch is not tested here
/// (network); the parser is fed canned payloads.
final class AnisetteServerProviderTests: XCTestCase {

    private var suite: UserDefaults!
    private var provider: AnisetteServerProvider!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "AnisetteServerProviderTests")!
        suite.removePersistentDomain(forName: "AnisetteServerProviderTests")
        provider = AnisetteServerProvider(defaults: suite)
    }

    func testDefaultServerIsMacAni() {
        XCTAssertEqual(provider.selectedServer, "https://mac-ani.jkcoxson.com")
        XCTAssertFalse(provider.isCustomServer)
    }

    func testServersToTryCapsAtTwo() {
        let servers = provider.serversToTry()
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0], "https://mac-ani.jkcoxson.com")
        XCTAssertEqual(servers[1], "https://ani.jkcoxson.com")
    }

    func testCustomServerGoesFirst() {
        provider.selectedServer = "https://ani2.stikstore.app"
        let servers = provider.serversToTry()
        XCTAssertEqual(servers[0], "https://ani2.stikstore.app")
        XCTAssertEqual(servers[1], "https://mac-ani.jkcoxson.com")
        XCTAssertTrue(provider.isCustomServer)
    }

    func testValidServerURLs() {
        XCTAssertTrue(AnisetteServerProvider.isValidServerURL("https://mac-ani.jkcoxson.com"))
        XCTAssertTrue(AnisetteServerProvider.isValidServerURL("https://example.com:8443/v3"))
        XCTAssertFalse(AnisetteServerProvider.isValidServerURL("http://mac-ani.jkcoxson.com"))
        XCTAssertFalse(AnisetteServerProvider.isValidServerURL("https://"))
        XCTAssertFalse(AnisetteServerProvider.isValidServerURL("not a url"))
        XCTAssertFalse(AnisetteServerProvider.isValidServerURL(""))
    }

    func testParseRemoteListObjectShape() throws {
        let data = """
        {"servers": [{"url": "https://a.example.com"}, {"url": "https://b.example.com"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(AnisetteServerProvider.parseRemoteList(data: data),
                       ["https://a.example.com", "https://b.example.com"])
    }

    func testParseRemoteListStringShape() throws {
        let data = """
        {"servers": ["https://a.example.com", "http://bad.example.com"]}
        """.data(using: .utf8)!
        XCTAssertEqual(AnisetteServerProvider.parseRemoteList(data: data),
                       ["https://a.example.com"])
    }

    func testParseRemoteListBareArray() throws {
        let data = """
        ["https://a.example.com"]
        """.data(using: .utf8)!
        XCTAssertEqual(AnisetteServerProvider.parseRemoteList(data: data),
                       ["https://a.example.com"])
    }

    func testParseRemoteListGarbageIsEmpty() {
        XCTAssertTrue(AnisetteServerProvider.parseRemoteList(data: Data("nope".utf8)).isEmpty)
        XCTAssertTrue(AnisetteServerProvider.parseRemoteList(data: Data("{}".utf8)).isEmpty)
    }
}
