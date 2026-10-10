import Darwin
import Foundation

/// Bounded real TCP fixture; only 127.0.0.1 and a test-created listener port.
/// Read/write operations have kernel timeouts and run off the Swift executor.
final class HTTPRawSocket: @unchecked Sendable {
    enum Failure: Error { case socket, connect, write, read, limit }
    private let lock = NSLock()
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }
    func close() {
        let fd = lock.withLock { let value = descriptor; descriptor = -1; return value }
        if fd >= 0 { Darwin.close(fd) }
    }
    func halfCloseWrite() throws {
        let fd = lock.withLock { descriptor }
        guard Darwin.shutdown(fd, SHUT_WR) == 0 else { throw Failure.write }
    }

    static func open(port: UInt16, request: Data) async throws -> HTTPRawSocket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { throw Failure.socket }
                    let socket = HTTPRawSocket(fd)
                    var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
                    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                        throw Failure.socket
                    }
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw Failure.socket }
                    let connected = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    guard connected == 0 else { throw Failure.connect }
                    try request.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let wrote = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                            guard wrote > 0 else { throw Failure.write }; offset += wrote
                        }
                    }
                    continuation.resume(returning: socket)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func read(until marker: String) async throws -> String {
        let fd = lock.withLock { descriptor }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while ContinuousClock.now < deadline {
                        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                        guard count > 0 else { throw Failure.read }
                        guard bytes.count + count <= 262_144 else { throw Failure.limit }
                        bytes.append(contentsOf: buffer.prefix(count))
                        let text = String(decoding: bytes, as: UTF8.self)
                        if text.contains(marker) { continuation.resume(returning: text); return }
                    }
                    throw Failure.read
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
