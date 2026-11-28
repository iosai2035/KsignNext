import Foundation

/// Coordinates the install paths: local-server install (loopback
/// HTTP for this device, LAN HTTPS for another device) for one
/// signed IPA.
///
/// `.thisDevice` starts the loopback listener only (no Wi-Fi
/// needed); `.anotherDevice` starts the LAN listener only (needs
/// Wi-Fi — without a LAN address it fails with a specific error,
/// never a half-started server). The manifest is generated AFTER
/// the listener binds, because its URLs carry the bound port. On
/// any failure after a listener starts, the listeners are stopped
/// again — a failed `prepareInstall` never leaves an orphan server.
public final class InstallationEngine: InstallationEngineProtocol, @unchecked Sendable {
    public static let ipaRoute = "/app.ipa"
    public static let manifestRoute = "/manifest.plist"

    private let server: InstallationServerProtocol
    private let tlsIdentity: TLSIdentityServiceProtocol
    private let fileSystem: FileSystemManager
    private let lock = NSLock()
    private var manifestDirectory: URL?
    /// Every install step is logged here (P0: the logs must trace
    /// every stage of the install cycle).
    private let logger: AppLogger

    public init(server: InstallationServerProtocol, tlsIdentity: TLSIdentityServiceProtocol,
                fileSystem: FileSystemManager = .shared, logger: AppLogger = .shared) {
        self.server = server
        self.tlsIdentity = tlsIdentity
        self.fileSystem = fileSystem
        self.logger = logger
    }

    public var isServing: Bool { server.isRunning }
    public var servedLoopbackBaseURL: URL? { server.loopbackBaseURL }
    public var servedLANBaseURL: URL? { server.lanBaseURL }

    public func prepareInstall(ipaURL: URL, bundleIdentifier: String, bundleVersion: String,
                               title: String, destination: InstallDestination,
                               displayImageURL: URL?, fullSizeImageURL: URL?,
                               timeout: TimeInterval = 600) async throws -> InstallationSession {
        _ = try Self.validateIPA(at: ipaURL)
        await logger.info("Preparing install for \(ipaURL.lastPathComponent) (\(bundleIdentifier), destination: \(destination)).")
        let manifestDir = try fileSystem.createTempDirectory(named: "install-\(UUID().uuidString)")
        lock.lock()
        manifestDirectory = manifestDir
        lock.unlock()
        do {
            let session = try await prepare(ipaURL: ipaURL, bundleIdentifier: bundleIdentifier,
                                            bundleVersion: bundleVersion, title: title,
                                            destination: destination, displayImageURL: displayImageURL,
                                            fullSizeImageURL: fullSizeImageURL,
                                            timeout: timeout, manifestDir: manifestDir)
            await logger.info("Install ready: \(session.installURL.absoluteString) (expires \(session.expiresAt)).")
            return session
        } catch {
            await logger.logError(error, context: "InstallationEngine")
            await stopServing()
            throw error
        }
    }

    public func stopServing() async {
        await logger.info("Stopping the install server.")
        await server.stop()
        lock.lock()
        let directory: URL? = manifestDirectory
        manifestDirectory = nil
        lock.unlock()
        if let directory { fileSystem.cleanupTempDirectory(directory) }
    }

    public static func validateIPA(at url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.ipa(.fileNotFound(path: url.path))
        }
        guard url.pathExtension.lowercased() == "ipa" else {
            throw AppError.ipa(.notAnIPA(url))
        }
        let size: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw AppError.ipa(.unreadable(path: url.path))
        }
        guard size > 0 else {
            throw AppError.ipa(.invalidZIP("IPA file is empty."))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 4), header == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw AppError.ipa(.invalidZIP("Not a ZIP archive (missing PK\\u{03}\\u{04} magic)."))
        }
        return size
    }

    // MARK: - Internals

    private func prepare(ipaURL: URL, bundleIdentifier: String, bundleVersion: String,
                         title: String, destination: InstallDestination,
                         displayImageURL: URL?, fullSizeImageURL: URL?,
                         timeout: TimeInterval, manifestDir: URL) async throws -> InstallationSession {
        let ipaFile = InstallationServerFile(route: Self.ipaRoute, fileURL: ipaURL,
                                             contentType: "application/octet-stream")
        let expiresAt = Date().addingTimeInterval(timeout)
        switch destination {
        case .thisDevice:
            let base = try await server.startLoopback(serving: [ipaFile], timeout: timeout)
            await logger.info("Loopback install server started at \(base.absoluteString).")
            let manifestURL = base.appendingPathComponent("manifest.plist")
            let packageURL = base.appendingPathComponent("app.ipa")
            let manifestFileURL = try InstallManifest.write(
                packageURL: packageURL, bundleIdentifier: bundleIdentifier, bundleVersion: bundleVersion,
                title: title, displayImageURL: displayImageURL, fullSizeImageURL: fullSizeImageURL,
                to: manifestDir)
            try await server.serve(file: InstallationServerFile(route: Self.manifestRoute,
                                                                 fileURL: manifestFileURL,
                                                                 contentType: "application/x-plist"))
            return InstallationSession(ipaURL: ipaURL, manifestURL: manifestURL,
                                       installURL: try InstallManifest.installURL(manifestURL: manifestURL),
                                       loopbackBaseURL: base, lanBaseURL: nil,
                                       tlsFingerprint: nil, expiresAt: expiresAt)
        case .anotherDevice:
            guard TLSIdentityService.lanIPv4Address() != nil else {
                throw AppError.network(.underlying(
                    "No Wi-Fi address: installing on another device needs this device on Wi-Fi."))
            }
            let identity = try await tlsIdentity.currentIdentity()
            let privateKeyDER = try await tlsIdentity.privateKeyPKCS8DER()
            let base = try await server.startLAN(serving: [ipaFile], tlsCertificateDER: identity.certificateDER,
                                                 tlsPrivateKeyPKCS8DER: privateKeyDER, timeout: timeout)
            await logger.info("LAN install server started at \(base.absoluteString) (TLS fingerprint \(identity.fingerprintSHA256.prefix(12))…).")
            let manifestURL = base.appendingPathComponent("manifest.plist")
            let packageURL = base.appendingPathComponent("app.ipa")
            let manifestFileURL = try InstallManifest.write(
                packageURL: packageURL, bundleIdentifier: bundleIdentifier, bundleVersion: bundleVersion,
                title: title, displayImageURL: displayImageURL, fullSizeImageURL: fullSizeImageURL,
                to: manifestDir)
            try await server.serve(file: InstallationServerFile(route: Self.manifestRoute,
                                                                 fileURL: manifestFileURL,
                                                                 contentType: "application/x-plist"))
            return InstallationSession(ipaURL: ipaURL, manifestURL: manifestURL,
                                       installURL: try InstallManifest.installURL(manifestURL: manifestURL),
                                       loopbackBaseURL: nil, lanBaseURL: base,
                                       tlsFingerprint: identity.fingerprintSHA256, expiresAt: expiresAt)
        }
    }
}
