import Darwin
import Foundation

/// One IPv4 address in host byte order. `description` is redacted so an
/// address never lands in a log line or report by accident; commands that
/// need the text use `dottedDecimal` explicitly.
public struct ClusterLinkIPv4Address: Sendable, Hashable, CustomStringConvertible {
    public let value: UInt32

    public init(value: UInt32) { self.value = value }

    /// Strict dotted decimal: four canonical octets, nothing else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            let digits = part.utf8
            guard (1...3).contains(digits.count),
                  digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  digits.count == 1 || digits.first != UInt8(ascii: "0"),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            result = result << 8 | octet
        }
        value = result
    }

    public static let loopback = ClusterLinkIPv4Address(value: 0x7F00_0001)

    public var dottedDecimal: String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
    public var description: String { "ipv4(redacted)" }
    public var isLoopback: Bool { value >> 24 == 127 }
    public var isLinkLocal: Bool { value >> 16 == 0xA9FE }
    /// Link setup v2's private cluster subnet `10.219.0.0/16` (per-edge /30
    /// subnets of N-Mac addressing live inside it too).
    public var isClusterSubnet: Bool { value >> 16 == 0x0ADB }
    public var isUnspecified: Bool { value == 0 }

    func socketAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: value.bigEndian)
        return address
    }
}

/// Failures of the socket layer. Payload-free apart from an errno.
enum LinkSocketError: Error, Equatable {
    case system(Int32)
    case timedOut
    case closed
}

/// Monotonic nanoseconds (uptime, not wall clock).
@inline(__always) func linkNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Nonblocking IPv4 TCP socket bound to one interface (IP_BOUND_IF), so its
/// traffic can only enter and leave through that interface whatever the
/// routing table says (169.254/16 routes are ambiguous on a Mac with Wi-Fi).
///
/// Ownership: `shutdown()` may be called from any thread to wake blocked IO;
/// `close()` only by the single owner once no other thread can use the
/// descriptor (the caller serializes it with its writers), so a closed
/// descriptor number can never be reused under a running read or write.
final class LinkSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var isShut = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    var fd: Int32 { lock.withLock { descriptor } }

    static func configureStream(_ fd: Int32) throws {
        try setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        try setOption(fd, IPPROTO_TCP, TCP_NODELAY, 1)
        try setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
        try setOption(fd, IPPROTO_TCP, TCP_KEEPALIVE, 5)
        try setOption(fd, IPPROTO_TCP, TCP_KEEPINTVL, 2)
        try setOption(fd, IPPROTO_TCP, TCP_KEEPCNT, 3)
        try setNonblocking(fd)
    }

    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws {
        var value = value
        guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw LinkSocketError.system(errno)
        }
    }

    static func setNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw LinkSocketError.system(errno) }
    }

    private static func newSocket(interfaceIndex: UInt32) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw LinkSocketError.system(errno) }
        do {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            if interfaceIndex != 0 {
                try setOption(fd, IPPROTO_IP, IP_BOUND_IF, Int32(bitPattern: interfaceIndex))
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    /// A listening socket on exactly one local address and interface.
    static func listen(address: ClusterLinkIPv4Address, port: UInt16, interfaceIndex: UInt32,
                       backlog: Int32) throws -> (LinkSocket, UInt16) {
        let fd = try newSocket(interfaceIndex: interfaceIndex)
        do {
            try setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            var local = address.socketAddress(port: port)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw LinkSocketError.system(errno) }
            guard Darwin.listen(fd, backlog) == 0 else { throw LinkSocketError.system(errno) }
            try setNonblocking(fd)
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw LinkSocketError.system(errno) }
            return (LinkSocket(descriptor: fd), UInt16(bigEndian: actual.sin_port))
        } catch { Darwin.close(fd); throw error }
    }

    /// Accepts one pending connection, or nil when none is waiting.
    func accept() throws -> (LinkSocket, ClusterLinkIPv4Address)? {
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(self.fd, $0, &length) }
        }
        if fd < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED { return nil }
            throw LinkSocketError.system(errno)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        do { try Self.configureStream(fd) } catch { Darwin.close(fd); throw error }
        guard peer.sin_family == sa_family_t(AF_INET) else { Darwin.close(fd); return nil }
        return (LinkSocket(descriptor: fd), ClusterLinkIPv4Address(value: UInt32(bigEndian: peer.sin_addr.s_addr)))
    }

    /// Dials `peer:port` from `local` through one interface, within `timeout`.
    static func connect(local: ClusterLinkIPv4Address, peer: ClusterLinkIPv4Address, port: UInt16,
                        interfaceIndex: UInt32, timeoutNanoseconds: UInt64) throws -> LinkSocket {
        let fd = try newSocket(interfaceIndex: interfaceIndex)
        do {
            var source = local.socketAddress(port: 0)
            let bound = withUnsafePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw LinkSocketError.system(errno) }
            try configureStream(fd)
            var target = peer.socketAddress(port: port)
            let started = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if started != 0 {
                guard errno == EINPROGRESS || errno == EINTR else { throw LinkSocketError.system(errno) }
                let deadline = linkNow() &+ timeoutNanoseconds
                try waitFor(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else {
                    throw LinkSocketError.system(errno)
                }
                guard failure == 0 else { throw LinkSocketError.system(failure) }
            }
            return LinkSocket(descriptor: fd)
        } catch { Darwin.close(fd); throw error }
    }

    /// Waits until `fd` is ready for `events` or the deadline passes.
    static func waitFor(fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = linkNow()
            guard now < deadline else { throw LinkSocketError.timedOut }
            let milliseconds = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&entry, 1, milliseconds)
            if ready > 0 {
                if entry.revents & Int16(POLLNVAL) != 0 { throw LinkSocketError.closed }
                return // readable/writable, or an error/hangup the next IO call reports
            }
            if ready < 0, errno != EINTR { throw LinkSocketError.system(errno) }
        }
    }

    /// Writes every byte before the deadline or fails; never returns partially.
    func writeAll(_ data: Data, deadline: UInt64) throws {
        let fd = self.fd
        guard fd >= 0 else { throw LinkSocketError.closed }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(fd, pointer, remaining, 0)
                if written > 0 {
                    pointer = pointer.advanced(by: written); remaining -= written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try Self.waitFor(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                if written < 0, errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN { throw LinkSocketError.closed }
                throw LinkSocketError.system(written < 0 ? errno : EIO)
            }
        }
    }

    /// Bytes the kernel would still accept into the send buffer right now.
    func sendSpace() -> Int {
        let fd = self.fd
        guard fd >= 0 else { return 0 }
        var size: Int32 = 0, queued: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, &length) == 0 else { return 0 }
        length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NWRITE, &queued, &length) == 0 else { return 0 }
        return max(0, Int(size) - Int(queued))
    }

    /// Reads up to `count` bytes into `pointer`, waiting until the deadline for
    /// the first byte. Returns 0 only at end of stream.
    func readSome(into pointer: UnsafeMutableRawPointer, count: Int, deadline: UInt64) throws -> Int {
        let fd = self.fd
        guard fd >= 0 else { throw LinkSocketError.closed }
        while true {
            let received = Darwin.recv(fd, pointer, count, 0)
            if received >= 0 { return received }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try Self.waitFor(fd: fd, events: Int16(POLLIN), deadline: deadline)
                continue
            }
            if errno == ECONNRESET || errno == ENOTCONN || errno == EPIPE { throw LinkSocketError.closed }
            throw LinkSocketError.system(errno)
        }
    }

    /// Wakes any thread blocked on this socket; IO afterwards fails promptly.
    func shutdown() {
        lock.withLock {
            guard descriptor >= 0, !isShut else { return }
            isShut = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    /// Owner only, after every reader and writer has stopped using the socket.
    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            if !isShut { _ = Darwin.shutdown(descriptor, SHUT_RDWR); isShut = true }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

/// Buffered exact reads over a `LinkSocket`, so small frames cost one recv.
final class LinkReader {
    private let socket: LinkSocket
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0

    init(socket: LinkSocket, capacity: Int = 256 * 1024) {
        self.socket = socket
        buffer = [UInt8](repeating: 0, count: capacity)
    }

    var hasBufferedBytes: Bool { end > start }

    /// Exactly `count` bytes before the deadline, or a failure.
    func readExact(_ count: Int, deadline: UInt64) throws -> Data {
        var result = Data(count: count)
        var filled = 0
        let buffered = min(count, end - start)
        if buffered > 0 {
            result.withUnsafeMutableBytes { target in
                buffer.withUnsafeBytes { source in
                    target.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: buffered)
                }
            }
            start += buffered; filled = buffered
        }
        if start == end { start = 0; end = 0 }
        while filled < count {
            let missing = count - filled
            if missing >= buffer.count / 2 {
                // Large payload: read straight into the result, no copy.
                let received = try result.withUnsafeMutableBytes { target in
                    try socket.readSome(into: target.baseAddress!.advanced(by: filled), count: missing, deadline: deadline)
                }
                guard received > 0 else { throw LinkSocketError.closed }
                filled += received
                continue
            }
            let received = try buffer.withUnsafeMutableBytes { target in
                try socket.readSome(into: target.baseAddress!.advanced(by: end), count: target.count - end, deadline: deadline)
            }
            guard received > 0 else { throw LinkSocketError.closed }
            end += received
            let take = min(missing, end - start)
            result.withUnsafeMutableBytes { target in
                buffer.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: filled).copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: take)
                }
            }
            start += take; filled += take
            if start == end { start = 0; end = 0 }
        }
        return result
    }
}
