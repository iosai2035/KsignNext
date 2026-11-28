//  InstallationServer.swift
//  KsignNext
//
//  Minimal Phase 1 install server.
//
//  A real loopback (127.0.0.1) HTTP listener built on NIO + NIOHTTP1, serving
//  the files the install engine registers (the signed IPA at /app.ipa and the
//  OTA manifest at /manifest.plist). This follows the rebuild blueprint (§6)
//  two-listener design — loopback HTTP for this device, LAN HTTPS for another
//  device — but the LAN HTTPS listener is NOT in this build. It needs the
//  NIOSSL dependency and the per-device TLS identity, both of which land in
//  Phase 2. Until then `startLAN` throws an honest typed error instead of
//  pretending to serve. No bundled or shared TLS key is ever used.
//
//  Phase 1 scope: `startLoopback`, `serve`, `stop`, `isRunning`,
//  `loopbackBaseURL`. `lanBaseURL` is always nil in this build.

import Foundation
import NIO
import NIOHTTP1

/// Loopback-only install server for Phase 1. Conforms to the full
/// `InstallationServerProtocol`; the LAN half throws until Phase 2.
public final class NIOInstallationServer: InstallationServerProtocol, @unchecked Sendable {

    private let group: EventLoopGroup
    private let lock = NSLock()
    private var loopbackChannel: Channel?
    private var timeoutTask: Scheduled<Void>?
    private let registry = FileRegistry()

    public init(eventLoopGroup: EventLoopGroup? = nil) {
        self.group = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public var isRunning: Bool {
        lock.lock()
        let running = loopbackChannel != nil
        lock.unlock()
        return running
    }

    public var loopbackBaseURL: URL? {
        lock.lock()
        let channel = loopbackChannel
        lock.unlock()
        guard let channel else { return nil }
        return Self.baseURL(for: channel)
    }

    public var lanBaseURL: URL? { nil }

    public func startLoopback(serving files: [InstallationServerFile],
                              timeout: TimeInterval) async throws -> URL {
        let base = try await startLoopbackListener(timeout: timeout)
        for file in files { registry.register(file) }
        return base
    }

    public func startLAN(serving files: [InstallationServerFile], tlsCertificateDER: Data,
                         tlsPrivateKeyPKCS8DER: Data, timeout: TimeInterval) async throws -> URL {
        throw AppError.network(.tlsFailure(reason: "LAN HTTPS install is not available in this build. "
            + "It arrives in Phase 2 with the NIOSSL dependency and the per-device TLS identity."))
    }

    public func serve(file: InstallationServerFile) async throws {
        guard isRunning else { throw AppError.network(.offline) }
        registry.register(file)
    }

    public func stop() async {
        lock.lock()
        let channel = loopbackChannel
        loopbackChannel = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        if let channel { try? await channel.close().get() }
        registry.clear()
    }

    // MARK: - Private

    private var bootstrap: ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [registry] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(InstallHTTPHandler(registry: registry))
                }
            }
    }

    private static func baseURL(for channel: Channel) -> URL? {
        guard let address = channel.localAddress, let port = address.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Binds the loopback listener (or returns the existing base URL when it
    /// is already running). Tries random ports in 4000...8000, up to 20 times.
    private func startLoopbackListener(timeout: TimeInterval) async throws -> URL {
        lock.lock()
        let existing = loopbackChannel
        lock.unlock()
        if let existing, let base = Self.baseURL(for: existing) {
            scheduleTimeout(timeout)
            return base
        }
        var lastError: Error?
        for _ in 0..<20 {
            let port = Int.random(in: 4000...8000)
            do {
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
                guard let base = Self.baseURL(for: channel) else {
                    try? await channel.close().get()
                    throw AppError.network(.invalidResponse)
                }
                lock.lock()
                loopbackChannel = channel
                lock.unlock()
                scheduleTimeout(timeout)
                return base
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppError.network(.underlying(
            "Could not bind the loopback install server."))
    }

    private func scheduleTimeout(_ timeout: TimeInterval) {
        lock.lock()
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        guard timeout > 0 else { return }
        let task = group.next().scheduleTask(in: .seconds(Int64(timeout))) { [weak self] in
            _ = Task { await self?.stop() }
        }
        lock.lock()
        timeoutTask = task
        lock.unlock()
    }
}

// MARK: - File registry

/// Route → file map for the install server. Thread-safe: all state sits
/// behind one lock, so the registry is safe to share with NIO handlers.
private final class FileRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: InstallationServerFile] = [:]

    func register(_ file: InstallationServerFile) {
        lock.lock()
        files[file.route] = file
        lock.unlock()
    }

    func file(for path: String) -> InstallationServerFile? {
        var normalized = path
        if let queryIndex = normalized.firstIndex(of: "?") {
            normalized = String(normalized[..<queryIndex])
        }
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        lock.lock()
        let file = files[normalized]
        lock.unlock()
        return file
    }

    func clear() {
        lock.lock()
        files.removeAll()
        lock.unlock()
    }
}

// MARK: - HTTP handler

/// One HTTP handler per channel. Serves only the files the registry holds;
/// anything else is a 404. GET only.
private final class InstallHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let registry: FileRegistry
    private var requestHead: HTTPRequestHead?

    init(registry: FileRegistry) {
        self.registry = registry
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            handleRequest(head, context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func handleRequest(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .GET, let file = registry.file(for: head.uri) else {
            sendError(status: .notFound, message: "Not found", version: head.version, context: context)
            return
        }
        do {
            let data = try Data(contentsOf: file.fileURL)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: file.contentType)
            headers.add(name: "Content-Length", value: "\(data.count)")
            headers.add(name: "Connection", value: "close")
            let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        } catch {
            sendError(status: .internalServerError, message: "Could not read file",
                      version: head.version, context: context)
        }
    }

    private func sendError(status: HTTPResponseStatus, message: String, version: HTTPVersion,
                           context: ChannelHandlerContext) {
        let body = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
