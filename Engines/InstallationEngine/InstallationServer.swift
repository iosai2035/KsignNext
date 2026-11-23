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
// The loopback install server intentionally uses plain HTTP because it
// only ever binds 127.0.0.1. If a TLS listener is added later, add the
// swift-nio-ssl package (apple/swift-nio-ssl) — NIOSSL is NOT part of
// the swift-nio package, and declaring it there breaks SPM resolution.
//
// BEHAVIOUR:
// * Binds a random port in 4000-8000 on 127.0.0.1 (localhost) only.
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
        if isRunning {
            throw InstallationError.serverStartFailed("Installation server is already running.")
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
                let bound = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
                withLock {
                    channel = bound
                    boundBaseURL = URL(string: "http://127.0.0.1:\(port)")
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
            "Could not bind a localhost port in 4000-8000: \(lastError?.localizedDescription ?? "unknown error")"
        )
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
