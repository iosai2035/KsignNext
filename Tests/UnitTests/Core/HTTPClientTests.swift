import XCTest
@testable import KsignNext

/// Stub URLProtocol: no HTTPClient test touches the network.
private final class StubURLProtocol: URLProtocol {
    /// Set per test: either a response to return or an error to throw.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {

    private func stubbedClient() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return HTTPClient(session: session)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testConfiguration_defaultsAre30And300() {
        let configuration = HTTPClient.Configuration()
        XCTAssertEqual(configuration.requestTimeout, 30)
        XCTAssertEqual(configuration.resourceTimeout, 300)
        XCTAssertEqual(configuration.maxRedirects, 5)
        XCTAssertTrue(configuration.allowsCellularAccess)
    }

    func testSend_rejectsNonHTTPS() async {
        let client = stubbedClient()
        let request = HTTPClient.Request(url: URL(string: "http://example.invalid/file")!)
        await XCTAssertThrowsErrorAsync({ try await client.send(request) }) { error in
            guard case AppError.network = error else {
                return XCTFail("Expected AppError.network for plain HTTP, got \(error)")
            }
        }
    }

    func testSend_mapsTimeoutToNetworkTimeout() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let client = stubbedClient()
        let request = HTTPClient.Request(url: URL(string: "https://example.invalid/file")!)
        await XCTAssertThrowsErrorAsync({ try await client.send(request) }) { error in
            XCTAssertEqual(error as? AppError, AppError.network(.timeout))
        }
    }

    func testSend_rejectsNon2xxAsHTTPStatus() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = stubbedClient()
        let request = HTTPClient.Request(url: URL(string: "https://example.invalid/missing")!)
        await XCTAssertThrowsErrorAsync({ try await client.send(request) }) { error in
            XCTAssertEqual(error as? AppError, AppError.network(.httpStatus(404)))
        }
    }
}

/// Async variant of `XCTAssertThrowsError`: awaits the throwing
/// operation, then hands the caught error to the validator.
func XCTAssertThrowsErrorAsync<T>(
    _ operation: @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    validate: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await operation()
        XCTFail("Expected an error to be thrown.", file: file, line: line)
    } catch {
        validate(error)
    }
}
