import Foundation

// MARK: - InstallationEngine
//
// Installation layer for Ksign Next. Three install paths:
//
// 1. Local-server install (`prepareInstall`): the signed IPA is served by
//    a localhost HTTP server (`NIOInstallationServer`, in
//    InstallationServer.swift) together with a generated `itms-services`
//    manifest, and iOS installs the app from the returned
//    `itms-services://` URL. The server is an SPM dependency (SwiftNIO,
//    declared in the Xcode project); when SwiftNIO is not linked, the
//    engine is constructed with `UnsupportedInstallationServer`, which
//    throws a clear error instead of pretending the install works.
//    The server binds a random port in 4000-8000 on all interfaces
//    (0.0.0.0). Two destinations: `.thisDevice` advertises loopback
//    (127.0.0.1), which the device can always reach itself — on Wi-Fi,
//    on cellular data, or with no network at all, so no Wi-Fi is needed;
//    `.anotherDevice` advertises the Wi-Fi (LAN) address and throws
//    when the device has no Wi-Fi address. The server serves ONLY the
//    single IPA + manifest + icons for the install in progress (no
//    directory listing, no access to other user files), and shuts down
//    after the install or after the timeout.
// 2. SideStore export (`exportForSideStore`): produces a valid signed IPA
//    file in the Files-visible `Documents/SideStoreExports` folder, plus a
//    `SideStoreGuide` (ordered steps as data) explaining the import.
// 3. iDevice (USB) install: NOT available from a normal stock-iOS app.
//    `IDeviceAdapterProtocol` exists so the UI can show the option honestly
//    as unsupported (`UnavailableIDeviceAdapter`); nothing here pretends
//    pairing, AFC, or USB install works on-device.
//
// This file imports Foundation only. SwiftNIO imports live exclusively in
// InstallationServer.swift.

// MARK: - Errors

/// Every failure an installation operation can report.
public enum InstallationError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case invalidIPA(String)
    case manifestFailed(String)
    case serverUnavailable(String)
    case serverStartFailed(String)
    case exportFailed(String)
    case iDeviceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let detail):
            return "Invalid input: \(detail)"
        case .invalidIPA(let detail):
            return "Invalid IPA: \(detail)"
        case .manifestFailed(let detail):
            return "Could not build the install manifest: \(detail)"
        case .serverUnavailable(let detail):
            return "Installation server unavailable: \(detail)"
        case .serverStartFailed(let detail):
            return "Could not start the installation server: \(detail)"
        case .exportFailed(let detail):
            return "SideStore export failed: \(detail)"
        case .iDeviceUnavailable(let detail):
            return "USB install is not available: \(detail)"
        }
    }
}

// MARK: - Installation session

/// A prepared over-the-air install: the served manifest URL, the
/// `itms-services://` URL to open, and when the local server stops.
public struct InstallationSession: Sendable, Equatable {
    public let ipaURL: URL
    public let manifestURL: URL
    public let installURL: URL
    public let expiresAt: Date

    public init(ipaURL: URL, manifestURL: URL, installURL: URL, expiresAt: Date) {
        self.ipaURL = ipaURL
        self.manifestURL = manifestURL
        self.installURL = installURL
        self.expiresAt = expiresAt
    }
}

// MARK: - Installation server

/// One file served by the local installation server, at a fixed route.
public struct InstallationServerFile: Sendable, Equatable {
    public let route: String
    public let fileURL: URL
    public let contentType: String

    public init(route: String, fileURL: URL, contentType: String) {
        var normalized = route
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        self.route = normalized
        self.fileURL = fileURL
        self.contentType = contentType
    }
}

/// How the local server advertises itself in the returned base URL.
public enum ServerAdvertiseMode: Sendable {
    /// Wi-Fi address (en0), then cellular (pdp_ip0), then loopback.
    /// The default: reachable from another device on Wi-Fi when there
    /// is one, and from this device itself otherwise.
    case automatic
    /// Always 127.0.0.1 — reachable from this device on any connection
    /// (Wi-Fi, cellular data, or no network at all). Only this device
    /// can install from it; another device cannot reach loopback.
    case loopback
    /// Wi-Fi address (en0) only. Throws when the device has no Wi-Fi
    /// address, because loopback and the cellular address are not
    /// reachable from another device.
    case lan
}

/// The local install server. `start` binds all interfaces (0.0.0.0),
/// serves the given files, and returns the base URL (e.g.
/// `http://192.168.1.5:5231` on the LAN, `http://127.0.0.1:5231`
/// when no LAN address exists).
/// `serve` adds one more file to a running server. `stop` shuts it down.
public protocol InstallationServerProtocol: AnyObject, Sendable {
    var isRunning: Bool { get }
    var baseURL: URL? { get }
    func start(serving files: [InstallationServerFile], timeout: TimeInterval) async throws -> URL
    func start(serving files: [InstallationServerFile], timeout: TimeInterval, advertise: ServerAdvertiseMode) async throws -> URL
    func serve(file: InstallationServerFile) async throws
    func stop() async
}

public extension InstallationServerProtocol {
    /// Default: ignore the advertise mode and use the plain start
    /// (automatic). Servers that support the mode override this method.
    func start(serving files: [InstallationServerFile], timeout: TimeInterval, advertise: ServerAdvertiseMode) async throws -> URL {
        try await start(serving: files, timeout: timeout)
    }
}

/// Fallback used when SwiftNIO is not linked: every start/serve throws a
/// clear error instead of pretending a local install is possible.
public final class UnsupportedInstallationServer: InstallationServerProtocol, @unchecked Sendable {

    public init() {}

    public var isRunning: Bool { false }
    public var baseURL: URL? { nil }

    public func start(serving files: [InstallationServerFile], timeout: TimeInterval) async throws -> URL {
        throw InstallationError.serverUnavailable(
            "The local installation server needs SwiftNIO, which is not linked in this build. Use the SideStore export instead."
        )
    }

    public func serve(file: InstallationServerFile) async throws {
        throw InstallationError.serverUnavailable(
            "The local installation server needs SwiftNIO, which is not linked in this build. Use the SideStore export instead."
        )
    }

    public func stop() async {}
}

// MARK: - iDevice (USB)

/// One USB-connected iOS device, as reported by a host-side service.
public struct IDeviceInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let udid: String
    public let name: String
    public let model: String?
    public let iOSVersion: String?

    public init(udid: String, name: String, model: String? = nil, iOSVersion: String? = nil) {
        self.id = udid
        self.udid = udid
        self.name = name
        self.model = model
        self.iOSVersion = iOSVersion
    }
}

/// Pairing, device discovery, AFC, and USB install. Defined so the UI can
/// represent the option; on a stock-iOS app the only honest implementation
/// is `UnavailableIDeviceAdapter` below.
public protocol IDeviceAdapterProtocol: Sendable {
    func availableDevices() async throws -> [IDeviceInfo]
    func pair(device: IDeviceInfo) async throws
    func install(ipaURL: URL, on device: IDeviceInfo) async throws
}

/// Honest implementation: USB device pairing, AFC, and USB install are NOT
/// available from a normal stock-iOS app. They need a paired host computer
/// (or an external service running on one) — no on-device code can do them.
/// Every method throws so the UI must show this path as unsupported.
public struct UnavailableIDeviceAdapter: IDeviceAdapterProtocol {

    public init() {}

    private static let message = "USB install is not available from this app. Pairing, AFC, and USB installation need a paired host computer or an external service; a normal stock-iOS app cannot perform them."

    public func availableDevices() async throws -> [IDeviceInfo] {
        throw InstallationError.iDeviceUnavailable(Self.message)
    }

    public func pair(device: IDeviceInfo) async throws {
        throw InstallationError.iDeviceUnavailable(Self.message)
    }

    public func install(ipaURL: URL, on device: IDeviceInfo) async throws {
        throw InstallationError.iDeviceUnavailable(Self.message)
    }
}

/// Where an over-the-air install is meant to run.
public enum InstallDestination: Sendable {
    /// This device. The server is advertised on loopback (127.0.0.1),
    /// which the device can always reach itself — on Wi-Fi, on cellular
    /// data, or with no network at all. No Wi-Fi required.
    case thisDevice
    /// Another device on the same network. The server is advertised on
    /// the Wi-Fi (LAN) address; throws when the device has no Wi-Fi
    /// address, because loopback is not reachable from another device.
    case anotherDevice
}

// MARK: - Engine

/// Coordinates the three install paths: local-server install, SideStore
/// export, and the (unsupported) iDevice path.
public final class InstallationEngine: @unchecked Sendable {

    /// How long the local server stays up for one install (10 minutes).
    public static let defaultServerTimeout: TimeInterval = 600

    private let server: any InstallationServerProtocol
    private let fileManager: FileManager

    /// - Parameters:
    ///   - server: the local install server. Defaults to
    ///     `UnsupportedInstallationServer`; pass a `NIOInstallationServer`
    ///     when SwiftNIO is linked.
    public init(server: any InstallationServerProtocol = UnsupportedInstallationServer(), fileManager: FileManager = .default) {
        self.server = server
        self.fileManager = fileManager
    }

    public var isServing: Bool {
        server.isRunning
    }

    public var servedBaseURL: URL? {
        server.baseURL
    }

    // MARK: Local-server install

    /// Prepares an over-the-air install and returns the session, including
    /// the `itms-services://` URL to open. The local server serves the IPA
    /// first (so its base URL is known), then the manifest is generated
    /// against that base URL and served too. The server stops by itself
    /// after `timeout`; call `stopServing()` to stop it sooner.
    ///
    /// - Parameter destination: `.thisDevice` (default) advertises the
    ///   server on loopback, so the install works without Wi-Fi — on
    ///   cellular data or with no network at all. `.anotherDevice`
    ///   advertises the Wi-Fi (LAN) address and throws when the device
    ///   has no Wi-Fi address.
    public func prepareInstall(
        ipaURL: URL,
        bundleIdentifier: String,
        bundleVersion: String,
        title: String,
        destination: InstallDestination = .thisDevice,
        displayImageURL: URL? = nil,
        fullSizeImageURL: URL? = nil,
        timeout: TimeInterval = InstallationEngine.defaultServerTimeout
    ) async throws -> InstallationSession {
        _ = try Self.validateIPA(at: ipaURL)
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallationError.invalidInput("bundleIdentifier must not be empty.")
        }
        guard !bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallationError.invalidInput("bundleVersion must not be empty.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallationError.invalidInput("title must not be empty.")
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNextInstall-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw InstallationError.manifestFailed(error.localizedDescription)
        }

        // Start the server with the IPA so the base URL (and port) is known
        // before the manifest is generated. `.thisDevice` advertises
        // loopback (no Wi-Fi needed); `.anotherDevice` advertises the
        // Wi-Fi address and throws when there is none.
        let advertiseMode: ServerAdvertiseMode = switch destination {
        case .thisDevice: .loopback
        case .anotherDevice: .lan
        }
        let baseURL: URL
        do {
            baseURL = try await server.start(
                serving: [InstallationServerFile(route: "/app.ipa", fileURL: ipaURL, contentType: "application/octet-stream")],
                timeout: timeout,
                advertise: advertiseMode
            )
        } catch let error as InstallationError {
            throw error
        } catch {
            throw InstallationError.serverStartFailed(error.localizedDescription)
        }

        // Local icon files are served by the server; remote icon URLs are
        // referenced directly from the manifest.
        var manifestDisplayURL = displayImageURL
        var manifestFullSizeURL = fullSizeImageURL
        var extraFiles: [InstallationServerFile] = []
        if let displayImageURL, displayImageURL.isFileURL {
            manifestDisplayURL = baseURL.appendingPathComponent("icon.png")
            extraFiles.append(InstallationServerFile(route: "/icon.png", fileURL: displayImageURL, contentType: "image/png"))
        }
        if let fullSizeImageURL, fullSizeImageURL.isFileURL {
            manifestFullSizeURL = baseURL.appendingPathComponent("icon@2x.png")
            extraFiles.append(InstallationServerFile(route: "/icon@2x.png", fileURL: fullSizeImageURL, contentType: "image/png"))
        }

        let manifest: InstallManifest
        do {
            manifest = try InstallManifest(
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion,
                title: title,
                packageURL: baseURL.appendingPathComponent("app.ipa"),
                displayImageURL: manifestDisplayURL,
                fullSizeImageURL: manifestFullSizeURL
            )
        } catch {
            await server.stop()
            throw InstallationError.manifestFailed(error.localizedDescription)
        }

        let manifestFileURL: URL
        do {
            manifestFileURL = try manifest.write(to: workDirectory)
        } catch {
            await server.stop()
            throw InstallationError.manifestFailed(error.localizedDescription)
        }

        do {
            for file in extraFiles {
                try await server.serve(file: file)
            }
            try await server.serve(file: InstallationServerFile(
                route: "/manifest.plist",
                fileURL: manifestFileURL,
                contentType: "application/xml"
            ))
        } catch let error as InstallationError {
            await server.stop()
            throw error
        } catch {
            await server.stop()
            throw InstallationError.serverStartFailed(error.localizedDescription)
        }

        let servedManifestURL = baseURL.appendingPathComponent("manifest.plist")
        guard let installURL = InstallManifestURL.installURL(manifestURL: servedManifestURL) else {
            await server.stop()
            throw InstallationError.manifestFailed("Could not build the itms-services URL for the manifest.")
        }
        return InstallationSession(
            ipaURL: ipaURL,
            manifestURL: servedManifestURL,
            installURL: installURL,
            expiresAt: Date().addingTimeInterval(timeout)
        )
    }

    /// Stops the local installation server, if running.
    public func stopServing() async {
        await server.stop()
    }

    // MARK: SideStore export

    /// Copies a signed IPA into the Files-visible SideStore exports folder
    /// and returns the export record (file URL, name, size, date).
    public func exportForSideStore(ipaURL: URL, fileName: String? = nil) throws -> SideStoreExport {
        do {
            return try SideStoreExporter.export(ipaURL: ipaURL, fileName: fileName)
        } catch {
            throw InstallationError.exportFailed(error.localizedDescription)
        }
    }

    /// The ordered SideStore import guide (steps as data, not UI).
    public func sideStoreGuide() -> SideStoreGuide {
        SideStoreGuide.standard()
    }

    // MARK: iDevice (USB)

    /// The USB adapter. On stock iOS this is always
    /// `UnavailableIDeviceAdapter`: the UI must show USB install as
    /// unsupported rather than offering it as a working path.
    public func iDeviceAdapter() -> any IDeviceAdapterProtocol {
        UnavailableIDeviceAdapter()
    }

    // MARK: IPA validation

    /// Validates that a URL points at a real, non-empty IPA (ZIP magic
    /// `PK\x03\x04`) and returns its size in bytes. Throws
    /// `InstallationError.invalidIPA` otherwise.
    @discardableResult
    public static func validateIPA(at url: URL) throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw InstallationError.invalidIPA("File not found: \(url.lastPathComponent)")
        }
        guard url.pathExtension.lowercased() == "ipa" else {
            throw InstallationError.invalidIPA("Not an IPA file: \(url.lastPathComponent)")
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw InstallationError.invalidIPA("IPA file is empty: \(url.lastPathComponent)")
        }
        let magic: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            magic = try handle.read(upToCount: 4) ?? Data()
        } catch {
            throw InstallationError.invalidIPA("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw InstallationError.invalidIPA("File does not look like an IPA (missing ZIP header): \(url.lastPathComponent)")
        }
        return size
    }
}
