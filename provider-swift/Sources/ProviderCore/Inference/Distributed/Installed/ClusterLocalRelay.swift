import Foundation
import Darwin

/// `darkbloom cluster local` on the Mac that is not rank 0: its own port answers too, by passing each connection
/// over the cable to the API on the rank 0 Mac, byte for byte (the API's key is checked there). Which Mac is rank 0
/// follows the plan and can change between starts; without this the API's address changed with it (M4 Max rank 0 on
/// one start, M5 Max on the next, 2026-10-16). TCP only: no HTTP is read, nothing is kept.
public final class ClusterLocalRelay: @unchecked Sendable {
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) { self.host = host; self.port = port }
    }

    public let port: Int
    public let target: Target
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var open: Set<Int32> = []

    /// Listens on every IPv4 address at `port` (nil when it cannot: another program holds it) and passes each
    /// connection to `target`.
    public init?(port: Int, bind: String = "0.0.0.0", target: Target) {
        guard (1...65_535).contains(port), (1...65_535).contains(target.port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, bind, &address.sin_addr) == 1 else { close(fd); return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); return nil }
        self.port = port; self.target = target; listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    /// Closes the listener and every passed connection.
    public func stop() {
        let descriptors = lock.withLock { () -> [Int32] in
            guard !stopped else { return [] }
            stopped = true
            defer { open.removeAll() }
            return [listener] + Array(open)
        }
        for fd in descriptors { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    public var isStopped: Bool { lock.withLock { stopped } }

    private func track(_ fd: Int32) -> Bool {
        lock.withLock { guard !stopped else { return false }; open.insert(fd); return true }
    }

    private func untrack(_ fd: Int32) -> Bool { lock.withLock { open.remove(fd) != nil } }

    private func acceptLoop() {
        while !isStopped {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR || errno == ECONNABORTED { continue } else { return } }
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            guard track(client) else { close(client); return }
            Thread.detachNewThread { [self] in pass(client) }
        }
    }

    private func pass(_ client: Int32) {
        guard let upstream = Self.connect(target), track(upstream) else {
            if untrack(client) { close(client) }
            return
        }
        let done = DispatchGroup()
        for (from, to) in [(client, upstream), (upstream, client)] {
            done.enter()
            Thread.detachNewThread {
                Self.pump(from: from, to: to)
                done.leave()
            }
        }
        done.wait()
        if untrack(client) { close(client) }
        if untrack(upstream) { close(upstream) }
    }

    /// Copies until either side ends, then half-closes the other's write side (a request body's end reaches the API).
    static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { shutdown(from, SHUT_RD); return }
                offset += written
            }
        }
        shutdown(to, SHUT_WR)
    }

    static func connect(_ target: Target) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(target.port).bigEndian)
        guard inet_pton(AF_INET, target.host, &address.sin_addr) == 1 else { close(fd); return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
