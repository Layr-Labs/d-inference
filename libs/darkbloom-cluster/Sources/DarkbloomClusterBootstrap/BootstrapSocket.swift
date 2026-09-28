import Darwin
import Foundation

/// shutdown can interrupt IO; the descriptor is closed only at final release so
/// a concurrent operation cannot accidentally access a recycled descriptor.
final class BootstrapSocket: @unchecked Sendable {
    let descriptor: Int32
    let deadline: UInt64
    private let lock = NSLock()
    private var cancelled = false

    init(taking descriptor: Int32, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now, deadline - now <= 300_000_000_000 else {
            Darwin.close(descriptor); throw ClusterBootstrapError.deadline
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno; Darwin.close(descriptor); throw ClusterBootstrapError.system(code)
        }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            let code = errno; Darwin.close(descriptor); throw ClusterBootstrapError.system(code)
        }
        self.descriptor = descriptor; self.deadline = deadline
    }

    deinit { Darwin.close(descriptor) }

    func cancel() {
        lock.withLock {
            if !cancelled { cancelled = true; _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func check() throws {
        guard !lock.withLock({ cancelled }) else { throw ClusterBootstrapError.closed }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClusterBootstrapError.deadline }
    }

    func wait(_ events: Int16, until: UInt64? = nil) throws {
        let limit = min(deadline, until ?? deadline)
        while true {
            try check()
            guard DispatchTime.now().uptimeNanoseconds < limit else { throw ClusterBootstrapError.deadline }
            var p = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&p, 1, 25)
            try check()
            guard DispatchTime.now().uptimeNanoseconds < limit else { throw ClusterBootstrapError.deadline }
            if result < 0 {
                if errno == EINTR { continue }; throw ClusterBootstrapError.system(errno)
            }
            if result > 0 {
                guard p.revents & Int16(POLLNVAL) == 0 else { throw ClusterBootstrapError.closed }
                return // read/write observes EOF and socket errors itself.
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        guard (1...131_072).contains(count) else { throw ClusterBootstrapError.invalid("Read bound") }
        var result = Data(count: count), offset = 0
        while offset < count {
            try wait(Int16(POLLIN))
            let n = result.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n > 0 { offset += n }
            else if n == 0 { throw ClusterBootstrapError.closed }
            else if errno != EINTR && errno != EAGAIN { throw ClusterBootstrapError.system(errno) }
        }
        try check(); return result
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 131_072 else { throw ClusterBootstrapError.invalid("Write bound") }
        var offset = 0
        while offset < data.count {
            try wait(Int16(POLLOUT))
            let n = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n > 0 { offset += n }
            else if n == 0 { throw ClusterBootstrapError.closed }
            else if errno != EINTR && errno != EAGAIN { throw ClusterBootstrapError.system(errno) }
        }
        try check()
    }

    func requirePeer(processID: Int32) throws {
        guard processID > 1 else { throw ClusterBootstrapError.peer }
        var observed: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &observed, &length) == 0,
              length == MemoryLayout<Int32>.size, observed == processID,
              getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else { throw ClusterBootstrapError.peer }
        try check()
    }
}

func bootstrapAddress(_ path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < 104 else {
        throw ClusterBootstrapError.invalid("Invalid local socket path")
    }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.copyBytes(from: bytes); target[bytes.count] = 0
    }
    return address
}
