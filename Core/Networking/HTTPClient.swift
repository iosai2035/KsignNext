import Foundation

/// URLSession wrapper.
///
/// - HTTPS-only by default (`allowInsecureHTTP` must be opted into per
///   request and is never used for sources or downloads).
/// - Certificate validation is never disabled; there is no custom
///   `URLSessionDelegate` that trusts arbitrary certificates.
/// - Timeouts and typed errors; callers receive `AppError.network`.
public final class HTTPClient {
    public static let shared = HTTPClient()

    public struct Configuration {
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
            self.session = URLSession(configuration: config)
        }
    }

    public struct Request {
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
        guard let value = response.headers["Content-Length"] as? String ?? (response.headers["content-length"] as? String),
              let length = Int64(value) else { return nil }
        return length
    }
}
