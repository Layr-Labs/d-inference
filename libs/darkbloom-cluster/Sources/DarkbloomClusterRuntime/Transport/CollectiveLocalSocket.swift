import Darwin
import Foundation
import MLX

/// Correctness-only point-to-point channel between two ranks on ONE Mac: a TCP
/// connection on 127.0.0.1. It exists so the whole two-rank runtime (load
/// agreement, generation driver, hand-off, retirement) can be run and compared
/// against a single-process reference without a second Mac or an RDMA link.
///
/// It is not a transport for serving and never an RDMA result: both ranks
/// share one GPU, and no timing taken over it says anything about a pair. It
/// carries the same typed transfers as the native path with the same shape and
/// byte checks, and it keeps the native path's failure timing: a peer that
/// stops answering, or goes away, ends a transfer at the progress limit, not
/// sooner, so a failure path qualified here is not faster than on the link.
/// Reductions are not implemented; the layer pipeline does not use any.
final class CollectiveLocalSocket {
    static let environmentName = "DARKBLOOM_CLUSTER_TRANSPORT"
    static let progressEnvironmentName = "JACCL_PROGRESS_TIMEOUT_MS"
    static let defaultProgressMilliseconds = 60_000
    private static let frameHeaderBytes = 8

    let rank: Int
    private let descriptor: Int32
    private let progressNanoseconds: UInt64
    private let lock = NSLock()
    private var closed = false

    /// Rank 0 listens on the coordinator endpoint and rank 1 connects to it,
    /// the roles JACCL's own bootstrap gives them. Only 127.0.0.1 is accepted.
    init(rank: Int, coordinator: String, progressTimeoutMilliseconds: Int, deadlineUptimeNanoseconds: UInt64) throws {
        let endpoint = coordinator.split(separator: ":", omittingEmptySubsequences: false)
        guard (0...1).contains(rank), endpoint.count == 2, endpoint[0] == "127.0.0.1",
              let port = UInt16(endpoint[1]), port > 0, String(port) == endpoint[1],
              (1000...600_000).contains(progressTimeoutMilliseconds) else {
            throw ProbeError("local-socket-test requires rank 0|1, a 127.0.0.1:port coordinator and a bounded progress limit")
        }
        self.rank = rank
        progressNanoseconds = UInt64(progressTimeoutMilliseconds) * 1_000_000
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        func configure(_ socket: Int32) throws {
            var one: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw ProbeError("local-socket-test could not configure its socket")
            }
        }
        func remaining() throws -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNanoseconds else { throw ProbeError("local-socket-test peer did not arrive before the deadline") }
            return Int32(min((deadlineUptimeNanoseconds - now) / 1_000_000, 200))
        }
        if rank == 0 {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { throw ProbeError("local-socket-test could not create a socket") }
            defer { Darwin.close(listener) }
            var one: Int32 = 1
            _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(listener, 1) == 0 else { throw ProbeError("local-socket-test could not listen on its loopback port") }
            var accepted: Int32 = -1
            while accepted < 0 {
                var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&waiting, 1, try remaining())
                if ready > 0 { accepted = accept(listener, nil, nil) }
                if accepted < 0, ready < 0, errno != EINTR { throw ProbeError("local-socket-test accept failed") }
            }
            try configure(accepted)
            descriptor = accepted
        } else {
            var connected: Int32 = -1
            while connected < 0 {
                let candidate = socket(AF_INET, SOCK_STREAM, 0)
                guard candidate >= 0 else { throw ProbeError("local-socket-test could not create a socket") }
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if result == 0 { connected = candidate; break }
                Darwin.close(candidate)
                // Rank 0 is not listening yet: wait and try again, up to the deadline.
                usleep(useconds_t(try remaining()) * 1000)
            }
            try configure(connected)
            descriptor = connected
        }
    }

    static func progressMilliseconds(environment: [String: String]) throws -> Int {
        guard let text = environment[progressEnvironmentName] else { return defaultProgressMilliseconds }
        guard let value = Int(text), String(value) == text, (1000...600_000).contains(value) else {
            throw ProbeError("local-socket-test progress limit must be 1000...600000 ms")
        }
        return value
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(descriptor) }
    }

    /// One typed transfer: an eight-byte length and the array's logical bytes.
    func send(_ input: MLXArray, maximumBytes: Int, check: () throws -> Void) throws -> MLXArray {
        let geometry = try CollectivePointToPointShape(shape: input.shape, dtype: input.dtype, maximumBytes: maximumBytes)
        try geometry.validateMetadata(input)
        try check()
        let bytes = try MLX.withError { error in
            let value = input.asData().data
            try error.check()
            return value
        }
        guard bytes.count == geometry.byteCount else { throw ProbeError("local-socket-test send changed its byte count") }
        var header = UInt64(bytes.count).bigEndian
        try write(Data(bytes: &header, count: Self.frameHeaderBytes))
        try write(bytes)
        try check()
        return input
    }

    /// The receiver states the shape and dtype; a frame of any other size is a fault.
    func receive(shape: [Int], dtype: DType, maximumBytes: Int, check: () throws -> Void) throws -> MLXArray {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype, maximumBytes: maximumBytes)
        try check()
        let header = try read(Self.frameHeaderBytes)
        let length = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length == UInt64(geometry.byteCount) else {
            throw ProbeError("local-socket-test received a frame of another size than the expected transfer")
        }
        let bytes = try read(geometry.byteCount)
        try check()
        return try CollectivePointToPoint.materializeCompletedBytes(bytes, shape: shape, dtype: dtype,
            maximumBytes: maximumBytes, check: check)
    }

    private func fail(_ operation: String) -> ProbeError {
        close()
        return ProbeError("[local-socket-test] \(operation): no completion for \(progressNanoseconds / 1_000_000) ms. The group is closed")
    }

    /// Like the native progress guard: every byte of progress restarts the
    /// limit; a silent or departed peer ends the transfer when it runs out.
    private func wait(_ events: Int32, since: UInt64, operation: String) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now - since < progressNanoseconds else { throw fail(operation) }
            var waiting = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let slice = Int32(min((progressNanoseconds - (now - since)) / 1_000_000 + 1, 100))
            let ready = poll(&waiting, 1, slice)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw fail(operation) }
        }
    }

    private func departed(since: UInt64, operation: String) -> ProbeError {
        // The link would not report a peer that went away; it would stop
        // completing transfers. Wait out the limit so the timing is the same.
        let elapsed = DispatchTime.now().uptimeNanoseconds - since
        if elapsed < progressNanoseconds { usleep(useconds_t(min((progressNanoseconds - elapsed) / 1000, 600_000_000))) }
        return fail(operation)
    }

    private func write(_ data: Data) throws {
        var offset = 0
        var progress = DispatchTime.now().uptimeNanoseconds
        while offset < data.count {
            try wait(POLLOUT, since: progress, operation: "send")
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count > 0 { offset += count; progress = DispatchTime.now().uptimeNanoseconds; continue }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            throw departed(since: progress, operation: "send")
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        var progress = DispatchTime.now().uptimeNanoseconds
        while offset < count {
            try wait(POLLIN, since: progress, operation: "recv")
            let received = data.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received > 0 { offset += received; progress = DispatchTime.now().uptimeNanoseconds; continue }
            if received < 0, errno == EINTR || errno == EAGAIN { continue }
            throw departed(since: progress, operation: "recv")
        }
        return data
    }
}
