/// LocalCDNFileServer -- a real Hummingbird HTTP server on 127.0.0.1:0 (the
/// MockCoordinator pattern) that plays the model CDN for live-isolated tests:
/// path -> bytes, with a request log.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore

/// Minimal file-serving HTTP server: path -> bytes, with a request log so
/// tests can prove which paths were (not) fetched. Honors `Range: bytes=N-`
/// the way the real CDN does, since the downloader byte-resumes.
final class LocalCDNFileServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var requested: [String] = []
    private var serverTask: Task<Void, Never>?
    private var responseDelayNanoseconds: UInt64 = 0

    func setFiles(_ files: [String: Data]) {
        lock.lock(); self.files = files; lock.unlock()
    }

    func requestedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requested
    }

    func clearRequested() {
        lock.lock(); requested = []; lock.unlock()
    }

    func setResponseDelay(milliseconds: UInt64) {
        lock.withLock { responseDelayNanoseconds = milliseconds * 1_000_000 }
    }

    private func record(_ path: String) {
        lock.lock(); requested.append(path); lock.unlock()
    }

    private func body(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return files[path]
    }

    private func responseDelay() -> UInt64 {
        lock.withLock { responseDelayNanoseconds }
    }

    /// Bind 127.0.0.1 on a system-assigned port and return the base URL.
    func start() async throws -> URL {
        var logger = Logger(label: "LocalCDNFileServer")
        logger.logLevel = .critical

        let router = Router(context: BasicRequestContext.self)
        router.get("**") { [weak self] request, _ -> Response in
            guard let self else { return Response(status: .internalServerError) }
            let path = request.uri.path
            self.record(path)
            let delay = self.responseDelay()
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let full = self.body(for: path) else {
                return Response(status: .notFound)
            }
            var data = full
            var status = HTTPResponse.Status.ok
            var headers = HTTPFields()
            if let range = request.headers[.range],
               range.hasPrefix("bytes="), range.hasSuffix("-"),
               let start = Int(range.dropFirst("bytes=".count).dropLast()), start <= full.count
            {
                data = Data(full.dropFirst(start))
                status = .partialContent
                headers[.contentRange] = "bytes \(start)-\(full.count - 1)/\(full.count)"
            }
            return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        let portBox = OneShotPortBox()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "LocalCDNFileServer"),
            onServerRunning: { @Sendable channel in
                portBox.complete(channel.localAddress?.port ?? 0)
            },
            logger: logger
        )
        let task = Task<Void, Never> {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                logger.warning("LocalCDNFileServer crashed: \(error)")
            }
        }

        let port = await portBox.value
        guard port > 0 else {
            task.cancel()
            throw URLError(.cannotConnectToHost)
        }
        lock.withLock { serverTask = task }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func shutdown() async {
        let task: Task<Void, Never>? = lock.withLock {
            let t = serverTask
            serverTask = nil
            return t
        }
        task?.cancel()
        _ = await task?.value
    }
}

/// One-shot async box for the bound port (MockCoordinator's PortBox pattern).
final class OneShotPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    var value: Int {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                lock.withLock {
                    if let p = port { cont.resume(returning: p) } else { continuation = cont }
                }
            }
        }
    }

    func complete(_ port: Int) {
        let cont: CheckedContinuation<Int, Never>? = lock.withLock {
            if self.port != nil { return nil }
            self.port = port
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.resume(returning: port)
    }
}
