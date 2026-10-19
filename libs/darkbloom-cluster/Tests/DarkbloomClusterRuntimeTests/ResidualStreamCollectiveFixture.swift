import Darwin
import Foundation
@testable import DarkbloomClusterRuntime

/// Real local-socket collectives in one process. No distributed backend or
/// model is initialized. Native transfers still require the exclusive lane.
final class ResidualStreamCollectiveFixture {
    let first: Collective
    let last: Collective

    init(timeoutSeconds: Int = 5, progressTimeoutSeconds: Int = 1) throws {
        guard (1...600).contains(timeoutSeconds), (1...600).contains(progressTimeoutSeconds) else {
            throw ProbeError("Fixture setup and progress timeouts must be 1...600 seconds")
        }
        let coordinator = try Self.coordinator()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000
        let listener = ResidualStreamFixtureWork {
            try Collective(localSocketRank: 0, coordinator: coordinator,
                progressTimeoutMilliseconds: progressTimeoutSeconds * 1000, deadlineUptimeNanoseconds: deadline)
        }
        defer { listener.join() }
        last = try Collective(localSocketRank: 1, coordinator: coordinator,
            progressTimeoutMilliseconds: progressTimeoutSeconds * 1000, deadlineUptimeNanoseconds: deadline)
        first = try listener.value()
    }

    /// The receiver drains while the sender writes, so a test never relies on
    /// a kernel send-buffer size. The local-socket sender finishes native byte
    /// extraction before writing; the receiver reconstructs only after reading
    /// the complete frame. No model/native evaluation overlaps that sequence.
    /// Always join the worker, including a throwing sender, before releasing
    /// either collective. A hung native call needs the parent's process deadline.
    func exchange<T>(send: () throws -> Void, receive: @escaping (Collective) throws -> T) throws -> T {
        let peer = last
        let receiving = ResidualStreamFixtureWork { try receive(peer) }
        defer { receiving.join() }
        try send()
        return try receiving.value()
    }

    private static func coordinator() throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError("Cannot reserve fixture loopback port") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let valid = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard valid, address.sin_port != 0 else { throw ProbeError("Cannot locate fixture loopback port") }
        return "127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
    }
}

/// One explicitly transferred operation, whose result is read only after the
/// join. The unchecked conformance does not make Collective concurrently safe.
private final class ResidualStreamFixtureWork<Value>: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let body: () throws -> Value
    private var result: Result<Value, Error>?

    init(_ body: @escaping () throws -> Value) {
        self.body = body
        group.enter()
        DispatchQueue.global().async { [self] in
            let value = Result { try self.body() }
            lock.lock(); result = value; lock.unlock()
            group.leave()
        }
    }

    func join() { group.wait() }
    func value() throws -> Value {
        join()
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw ProbeError("Fixture worker exited without a result") }
        return try result.get()
    }
}
