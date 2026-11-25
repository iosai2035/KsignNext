import Foundation
import NIO
import NIOHTTP1

// MARK: - InstallationServer (SwiftNIO)
//
// Local install server for Ksign Next, built on SwiftNIO.
//
// DEPENDENCY: SwiftNIO is an SPM dependency declared in the Xcode project.
// This file is the ONLY file in the installation engine that imports NIO;
// the rest of the engine is guarded from it (see InstallationEngine.swift).
// The server intentionally uses plain HTTP: it binds all interfaces
// (0.0.0.0) so another device on the LAN can reach it, but it serves
// ONLY the files registered for the install in progress — the single
// IPA, the manifest plist, and the install icons. There is no directory
// listing and no route that can reach any other user file. If a TLS
// listener is added later, add the swift-nio-ssl package
// (apple/swift-nio-ssl) — NIOSSL is NOT part of the swift-nio package,
// and declaring it there breaks SPM resolution.
//
// BEHAVIOUR:
// * Binds a random port in 4000-8000 on all interfaces (0.0.0.0) and
//   advertises, by default (`.automatic`), the device's Wi-Fi address
//   (en0), then its cellular address (pdp_ip0), then loopback
//   (127.0.0.1) — so the itms-services URL works from another device
//   on the same network as well as on this device.
// * `.loopback` always advertises 127.0.0.1: the device can always
//   reach its own loopback, on Wi-Fi, on cellular data, or with no
//   network at all — no Wi-Fi required to install on this device.
// * `.lan` advertises the Wi-Fi address only and throws when the
//   device has no Wi-Fi address, because loopback and the cellular
//   address are not reachable from another device.
// * Serves ONLY the files registered for the install in progress — the
//   single IPA, the manifest plist, and the install icons. There is no
//   directory listing and no route that can reach any other user file.
// * Shuts down after the install timeout (`start(serving:timeout:)`), or
//   sooner when `stop()` is called.
// * Request bodies are ignored; only GET is served.

// MARK: - Server

/// SwiftNIO implementation of `InstallationServerProtocol`.
public final class NIOInstallationServer: InstallationServerProtocol, @unchecked Sendable {

    private let group: MultiThreadedEventLoopGroup
    private let handler: InstallationHTTPHandler
    private let lock = NSLock()
    private var channel: Channel?
    private var boundBaseURL: URL?
    private var autoStopTask: Task<Void, Never>?

    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.handler = InstallationHTTPHandler()
    }

    deinit {
        // Best-effort shutdown if `stop()` was never called.
        try? group.syncShutdownGracefully()
    }

    public var isRunning: Bool {
        withLock { channel?.isActive ?? false }
    }

    public var baseURL: URL? {
        withLock { boundBaseURL }
    }

    public func start(serving files: [InstallationServerFile], timeout: TimeInterval) async throws -> URL {
        try await start(serving: files, timeout: timeout, advertise: .automatic)
    }

    public func start(serving files: [InstallationServerFile], timeout: TimeInterval, advertise: ServerAdvertiseMode) async throws -> URL {
        if isRunning {
            throw InstallationError.serverStartFailed("Installation server is already running.")
        }
        // Resolve the advertised host BEFORE binding: `.lan` fails fast
        // when the device has no Wi-Fi address instead of trying every
        // port first. Loopback is always valid; `.automatic` always
        // resolves (en0 -> pdp_ip0 -> loopback).
        let advertisedHost: String
        switch advertise {
        case .loopback:
            advertisedHost = "127.0.0.1"
        case .lan:
            guard let lan = Self.lanIPAddress() else {
                throw InstallationError.serverStartFailed("No Wi-Fi connection: installing on another device needs this device on Wi-Fi so the other device can reach the install server.")
            }
            advertisedHost = lan
        case .automatic:
            advertisedHost = Self.advertisedIPAddress() ?? "127.0.0.1"
        }
        for file in files {
            handler.register(file: file)
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [handler] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        var lastError: Error?
        for port in Array(4000...8000).shuffled() {
            do {
                // `get()` blocks the calling (non-event-loop) thread until
                // the bind completes; it is a one-time startup cost.
                // 0.0.0.0: listen on every interface (Wi-Fi/LAN included),
                // so another device on the same network can install.
                let bound = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
                withLock {
                    channel = bound
                    boundBaseURL = URL(string: "http://\(advertisedHost):\(port)")
                }
                scheduleAutoStop(after: timeout)
                guard let base = baseURL else {
                    throw InstallationError.serverStartFailed("Could not determine the bound address.")
                }
                return base
            } catch {
                lastError = error
                continue
            }
        }
        throw InstallationError.serverStartFailed(
            "Could not bind a port in 4000-8000: \(lastError?.localizedDescription ?? "unknown error")"
        )
    }

    /// The device's IPv4 LAN address (en0), for advertising the server
    /// to other devices on the same network. Nil when there is no Wi-Fi
    /// interface address.
    private static func lanIPAddress() -> String? {
        address(ofInterfaceNamed: "en0")
    }

    /// The address to advertise in `.automatic` mode: the Wi-Fi address
    /// (en0) first, then the cellular address (pdp_ip0) — the device can
    /// reach its own cellular address locally, so installs keep working
    /// on cellular data — then nil (the caller falls back to loopback).
    private static func advertisedIPAddress() -> String? {
        address(ofInterfaceNamed: "en0") ?? address(ofInterfaceNamed: "pdp_ip0")
    }

    /// The IPv4 address of one named interface, or nil when it has none.
    private static func address(ofInterfaceNamed interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == interfaceName else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }

    public func serve(file: InstallationServerFile) async throws {
        guard isRunning else {
            throw InstallationError.serverUnavailable("Installation server is not running.")
        }
        handler.register(file: file)
    }

    public func stop() async {
        withLock {
            autoStopTask?.cancel()
            autoStopTask = nil
        }
        let boundChannel = withLock { channel }
        if let boundChannel {
            // `try?`: the channel may already be closed; there is nothing
            // further to report in that case.
            _ = try? await boundChannel.close().get()
        }
        withLock {
            channel = nil
            boundBaseURL = nil
        }
        // Non-blocking shutdown; the group finishes once its channels close.
        group.shutdownGracefully { _ in }
    }

    private func scheduleAutoStop(after timeout: TimeInterval) {
        withLock {
            autoStopTask?.cancel()
            autoStopTask = nil
        }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
        withLock { autoStopTask = task }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - HTTP handler

/// Serves only the registered routes. Per-connection request state is kept
/// in a lock-guarded dictionary keyed by channel, because one handler
/// instance is shared by every accepted connection.
final class InstallationHTTPHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let lock = NSLock()
    private var files: [String: InstallationServerFile] = [:]
    private var pendingHeads: [ObjectIdentifier: HTTPRequestHead] = [:]

    func register(file: InstallationServerFile) {
        withLock { files[file.route] = file }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        let channelID = ObjectIdentifier(context.channel)
        switch part {
        case .head(let head):
            withLock { pendingHeads[channelID] = head }
        case .body:
            // Request bodies are ignored; this server only serves GETs.
            break
        case .end:
            let head = withLock { pendingHeads.removeValue(forKey: channelID) }
            guard let head else {
                context.close(promise: nil)
                return
            }
            respond(context: context, head: head)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: Responses

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard head.method == .GET else {
            sendText(context: context, status: .methodNotAllowed, text: "Method not allowed.")
            return
        }
        // Unknown routes (including "/" and any directory path) are 404:
        // there is no directory listing and no way to reach other files.
        guard let file = withLock({ files[path] }) else {
            sendText(context: context, status: .notFound, text: "Not found.")
            return
        }
        sendFile(context: context, file: file)
    }

    private func sendText(context: ChannelHandlerContext, status: HTTPResponseStatus, text: String) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "content-length", value: "\(text.utf8.count)")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendFile(context: ChannelHandlerContext, file: InstallationServerFile) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: file.contentType)
            headers.add(name: "content-length", value: "\(size)")
            headers.add(name: "connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            // Chunked streaming keeps memory bounded for large IPAs. The
            // reads happen on the event loop; for a single-install
            // localhost server this is acceptable and keeps the code free
            // of a separate file-IO thread pool.
            let handle = try FileHandle(forReadingFrom: file.fileURL)
            defer { try? handle.close() }
            while true {
                guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { break }
                var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } catch {
            sendText(context: context, status: .internalServerError, text: "Could not read file.")
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
