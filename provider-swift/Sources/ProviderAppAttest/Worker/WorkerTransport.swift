import Darwin
import Foundation

struct WorkerDeadline: Sendable {
    let end: ContinuousClock.Instant
    init(seconds: Double) { end = ContinuousClock.now.advanced(by: .seconds(seconds)) }
    var remaining: Double {
        let parts = (end - ContinuousClock.now).components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
    func check() throws {
        guard remaining > 0 else { throw AppAttestWorkerError.deadlineExceeded }
    }
}

/// Owns one descriptor until all concurrent I/O references have gone away.
/// Cancellation uses shutdown, not close, so an fd cannot be reused under poll.
final class WorkerDescriptor: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    init(_ fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
    func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw AppAttestWorkerError.systemFailure }
    }

    func wait(_ events: Int16, deadline: WorkerDeadline) throws {
        while true {
            try deadline.check()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(200, ceil(deadline.remaining * 1000))))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 {
                if errno == EINTR { continue }
                throw AppAttestWorkerError.systemFailure
            }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { return }
            throw AppAttestWorkerError.connectionClosed
        }
    }

    func readExactly(_ count: Int, deadline: WorkerDeadline) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(Int16(POLLIN), deadline: deadline)
            let readCount = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount == 0 { throw AppAttestWorkerError.connectionClosed }
            if readCount < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AppAttestWorkerError.systemFailure
            }
            offset += readCount
        }
        return data
    }

    func write(_ data: Data, deadline: WorkerDeadline) throws {
        // Native qualification observations and ordinary replies may originate
        // on different threads. Serialize whole frames, not individual writes.
        try writeLock.withLock {
            var offset = 0
            while offset < data.count {
                try wait(Int16(POLLOUT), deadline: deadline)
                let written = data.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if written <= 0 {
                    if written < 0, errno == EINTR || errno == EAGAIN { continue }
                    throw AppAttestWorkerError.connectionClosed
                }
                offset += written
            }
        }
    }
}

enum WorkerFraming {
    static let maximumBytes = 64 * 1024
    static func encode<T: Encodable>(_ value: T, limit: Int = maximumBytes) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= limit else { throw AppAttestWorkerError.frameTooLarge }
        var size = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame
    }
    static func read<T: Decodable>(_ type: T.Type, from channel: WorkerDescriptor,
                                   deadline: WorkerDeadline, limit: Int = maximumBytes) throws -> T {
        let header = try channel.readExactly(4, deadline: deadline)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= limit else { throw AppAttestWorkerError.frameTooLarge }
        let body = try channel.readExactly(Int(size), deadline: deadline)
        do { return try JSONDecoder().decode(type, from: body) }
        catch { throw AppAttestWorkerError.invalidMessage }
    }
    static func send<T: Encodable>(_ value: T, to channel: WorkerDescriptor,
                                   deadline: WorkerDeadline, limit: Int = maximumBytes) throws {
        try channel.write(encode(value, limit: limit), deadline: deadline)
    }
}

final class WorkerListener: @unchecked Sendable {
    let channel: WorkerDescriptor
    let directory: String
    let path: String

    init() throws {
        var template = Array("/tmp/darkbloom-attest-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw AppAttestWorkerError.systemFailure }
        directory = String(cString: created)
        path = directory + "/peer"
        do {
            channel = try Self.socket()
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(channel.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(channel.fd, 1) == 0 else { throw AppAttestWorkerError.systemFailure }
        } catch {
            unlink(path); rmdir(directory)
            throw error
        }
    }
    deinit { unlink(path); rmdir(directory) }

    func accept(deadline: WorkerDeadline) throws -> WorkerDescriptor {
        try channel.wait(Int16(POLLIN), deadline: deadline)
        let fd = Darwin.accept(channel.fd, nil, nil)
        guard fd >= 0 else { throw AppAttestWorkerError.systemFailure }
        let result = WorkerDescriptor(fd)
        try WorkerDescriptor.configure(fd)
        return result
    }

    static func connect(path: String, deadline: WorkerDeadline) throws -> WorkerDescriptor {
        let channel = try socket()
        var address = try address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(channel.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw AppAttestWorkerError.connectionClosed }
            try channel.wait(Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(channel.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw AppAttestWorkerError.connectionClosed
            }
        }
        return channel
    }

    private static func socket() throws -> WorkerDescriptor {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppAttestWorkerError.systemFailure }
        let channel = WorkerDescriptor(fd)
        try WorkerDescriptor.configure(fd)
        return channel
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AppAttestWorkerError.invalidMessage
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyMemory(from: source) }
        }
        return address
    }
}
