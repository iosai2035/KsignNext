import Foundation

/// One file served by the local install server, at a fixed route.
public struct InstallationServerFile: Sendable, Equatable {
    public let route: String
    public let fileURL: URL
    public let contentType: String

    public init(route: String, fileURL: URL, contentType: String) {
        var normalized = route
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        self.route = normalized
        self.fileURL = fileURL
        self.contentType = contentType
    }
}

/// Where an over-the-air install is meant to run.
public enum InstallDestination: Sendable {
    /// This device. Loopback HTTP only — no Wi-Fi needed.
    case thisDevice
    /// Another device on the same network. LAN HTTPS only.
    case anotherDevice
}

/// A prepared over-the-air install: the served manifest URL, the
/// `itms-services://` URL to open, and when the local server stops.
public struct InstallationSession: Sendable, Equatable {
    public let ipaURL: URL
    public let manifestURL: URL
    public let installURL: URL
    public let loopbackBaseURL: URL?
    public let lanBaseURL: URL?
    public let tlsFingerprint: String?
    public let expiresAt: Date

    public init(ipaURL: URL, manifestURL: URL, installURL: URL, loopbackBaseURL: URL?,
                lanBaseURL: URL?, tlsFingerprint: String?, expiresAt: Date) {
        self.ipaURL = ipaURL
        self.manifestURL = manifestURL
        self.installURL = installURL
        self.loopbackBaseURL = loopbackBaseURL
        self.lanBaseURL = lanBaseURL
        self.tlsFingerprint = tlsFingerprint
        self.expiresAt = expiresAt
    }
}

/// The local install server: TWO listeners (blueprint §6 — a single
/// port can never be both HTTP and HTTPS, because TLS negotiates
/// before any HTTP is visible). Loopback HTTP on 127.0.0.1 for this
/// device; LAN HTTPS on 0.0.0.0 with the per-device TLS identity for
/// another device. Each listener binds a DIFFERENT random port.
public protocol InstallationServerProtocol: AnyObject, Sendable {
    var isRunning: Bool { get }
    var loopbackBaseURL: URL? { get }
    var lanBaseURL: URL? { get }
    func startLoopback(serving files: [InstallationServerFile], timeout: TimeInterval) async throws -> URL
    func startLAN(serving files: [InstallationServerFile], tlsCertificateDER: Data,
                  tlsPrivateKeyPKCS8DER: Data, timeout: TimeInterval) async throws -> URL
    func serve(file: InstallationServerFile) async throws
    func stop() async
}

/// Coordinates the install paths: local-server install (loopback HTTP
/// or LAN HTTPS) for one signed IPA.
public protocol InstallationEngineProtocol: AnyObject, Sendable {
    var isServing: Bool { get }
    var servedLoopbackBaseURL: URL? { get }
    var servedLANBaseURL: URL? { get }
    func prepareInstall(ipaURL: URL, bundleIdentifier: String, bundleVersion: String,
                        title: String, destination: InstallDestination,
                        displayImageURL: URL?, fullSizeImageURL: URL?,
                        timeout: TimeInterval) async throws -> InstallationSession
    func stopServing() async
    static func validateIPA(at url: URL) throws -> Int64
}
