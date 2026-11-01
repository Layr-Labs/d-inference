import Darwin
import Foundation

/// One TCP connection between the two ranks of a tensor-parallel run on ONE
/// Mac, over 127.0.0.1 only. It carries the `socket` backend's reductions:
/// correctness only (eager, serial), never a pair timing or a hardware pass.
///
/// Rank 0 listens on the first endpoint of the host file, rank 1 connects to
/// it. Both send a fixed-width, versioned hello first, so a peer of another
/// build or rank layout is refused before any reduction. Every read and write
/// has a deadline, so a dead peer ends the run instead of hanging it.
final class QwenTensorParallelLocalSocket {
    static let hello: [UInt8] = Array("darkbloom-tp-socket-v1".utf8)

    let rank: Int
    private var descriptor: Int32 = -1

    init(rank: Int, port: UInt16, deadlineSeconds: Int = 300) throws {
        guard rank == 0 || rank == 1 else { throw ProbeError("Local socket: rank must be 0 or 1") }
        self.rank = rank
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
        if rank == 0 {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { throw ProbeError("Local socket: socket() failed (\(errno))") }
            defer { close(listener) }
            var yes: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                throw ProbeError("Local socket: cannot listen on 127.0.0.1:\(port) (\(errno))")
            }
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&waiting, 1, milliseconds) == 1 else { throw ProbeError("Local socket: rank 1 did not connect in time") }
            descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { throw ProbeError("Local socket: accept() failed (\(errno))") }
        } else {
            while true {
                let candidate = socket(AF_INET, SOCK_STREAM, 0)
                guard candidate >= 0 else { throw ProbeError("Local socket: socket() failed (\(errno))") }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if connected == 0 { descriptor = candidate; break }
                close(candidate)
                guard Date() < deadline else { throw ProbeError("Local socket: rank 0 did not listen on 127.0.0.1:\(port) in time") }
                usleep(100_000)
            }
        }
        var yes: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: deadlineSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peerHello = try exchange(Data(Self.hello + [UInt8(rank)]))
        guard peerHello == Data(Self.hello + [UInt8(1 - rank)]) else {
            close(descriptor)
            throw ProbeError("Local socket: the peer is not a matching tensor-parallel rank")
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw ProbeError("Local socket: write failed (\(errno))") }
                offset += written
            }
        }
    }

    func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                let got = Darwin.read(descriptor, buffer.baseAddress! + offset, count - offset)
                guard got > 0 else { throw ProbeError(got == 0 ? "Local socket: the peer closed" : "Local socket: read failed (\(errno))") }
                offset += got
            }
        }
        return data
    }

    /// One framed message: an 8-byte length, then the bytes.
    func send(_ data: Data) throws {
        var length = UInt64(data.count).littleEndian
        try write(Data(bytes: &length, count: 8))
        try write(data)
    }

    /// The matching framed message; a frame of another length is refused
    /// (two ranks that disagree on a buffer's size end cleanly, never misread).
    func receive(count: Int) throws -> Data {
        let header = try read(count: 8)
        let length = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length == UInt64(count) else {
            throw ProbeError("Local socket: the peer sent \(length) bytes where this rank expects \(count)")
        }
        return try read(count: count)
    }

    /// Both ranks pass buffers of the same length; each gets the other's.
    /// Rank 0 sends first and rank 1 receives first, so buffers larger than the
    /// kernel's socket buffers cannot deadlock.
    func exchange(_ mine: Data) throws -> Data {
        if rank == 0 {
            try send(mine)
            return try receive(count: mine.count)
        }
        let theirs = try receive(count: mine.count)
        try send(mine)
        return theirs
    }
}
