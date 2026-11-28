import Foundation

/// URLSession wrapper.
///
/// - HTTPS-only by default (`allowInsecureHTTP` must be opted into per
///   request and is never used for sources or downloads).
/// - Certificate validation is never disabled; there is no custom
///   `URLSessionDelegate` that trusts arbitrary certificates.
/// - Timeouts and typed errors; callers receive `AppError.network`.
/// - The session is injectable for tests; the redirect cap applies via
///   the delegate on the default session the client builds itself.
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    public struct Configuration: Sendable {
        public var requestTimeout: TimeInterval = 30
        public var resourceTimeout: TimeInterval = 300
        public var allowsCellularAccess: Bool = true
        public var maxRedirects: Int = 5

        public init() {}
    }

    private let session: URLSession
    private let configuration: Configuration

    public init(configuration: Configuration = Configuration(), session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = configuration.resourceTimeout
            config.allowsCellularAccess = configuration.allowsCellularAccess
            config.httpMaximumConnectionsPerHost = 4
            // Enforces `maxRedirects` (previously declared but never
            // applied): the delegate counts redirects per task and
            // stops following them past the limit instead of letting
            // URLSession chase an open redirect chain.
            self.session = URLSession(
                configuration: config,
                delegate: RedirectLimitDelegate(maxRedirects: configuration.maxRedirects),
                delegateQueue: nil
            )
        }
    }

    public struct Request: Sendable {
        public var url: URL
        public var method: String = "GET"
        public var headers: [String: String] = [:]
        public var body: Data? = nil
        /// Set only for local test servers; never for remote sources.
        public var allowInsecureHTTP: Bool = false

        public init(url: URL) { self.url = url }
    }

    public struct Response {
        public let data: Data
        public let statusCode: Int
        public let headers: [AnyHashable: Any]
        public let url: URL?
    }

    public func send(_ request: Request) async throws -> Response {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && request.allowInsecureHTTP) else {
            throw AppError.network(.tlsFailure(reason: "Only HTTPS URLs are allowed."))
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("KsignNext/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, urlResponse) = try await session.data(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw AppError.network(.invalidResponse)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AppError.network(.httpStatus(httpResponse.statusCode))
            }
            return Response(data: data, statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields, url: httpResponse.url)
        } catch let error as AppError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw AppError.network(.offline)
            case .timedOut:
                throw AppError.network(.timeout)
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw AppError.network(.tlsFailure(reason: urlError.localizedDescription))
            default:
                throw AppError.network(.underlying(urlError.localizedDescription))
            }
        } catch {
            throw AppError.network(.underlying(error.localizedDescription))
        }
    }

    public func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let response = try await send(Request(url: url))
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw AppError.network(.invalidResponse)
        }
    }

    /// HEAD request returning the content length, if the server reports one.
    public func contentLength(for url: URL) async throws -> Int64? {
        var request = Request(url: url)
        request.method = "HEAD"
        let response = try await send(request)
        // allHeaderFields keys are case-sensitive in the dictionary even
        // though HTTP header names are not, so search case-insensitively.
        let value = response.headers.first { entry in
            (entry.key as? String)?.lowercased() == "content-length"
        }?.value as? String
        guard let value, let length = Int64(value) else { return nil }
        return length
    }
}

/// `URLSessionTaskDelegate` that caps the redirect chain per task.
///
/// URLSession follows redirects by default with no limit exposed on
/// `URLSessionConfiguration`; without this delegate a server could
/// bounce a request forever (or into a loop) while the caller waits.
/// Counts are keyed by `taskIdentifier` and dropped when the task
/// finishes, so a reused session never leaks entries.
final class RedirectLimitDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    init(maxRedirects: Int) {
        self.maxRedirects = max(0, maxRedirects)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let count = (counts[task.taskIdentifier] ?? 0) + 1
        counts[task.taskIdentifier] = count
        lock.unlock()
        guard count <= maxRedirects else {
            // Stop following: the caller sees the last 3xx response
            // as a non-2xx status error instead of an endless chain.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        counts[task.taskIdentifier] = nil
        lock.unlock()
    }
}
