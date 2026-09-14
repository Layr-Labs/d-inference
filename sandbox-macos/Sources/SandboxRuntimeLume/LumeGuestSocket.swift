import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// Blocking operations are bounded by one monotonic deadline and run on the
/// client's detached task. Polling checks cancellation every 100 milliseconds.
final class LumeGuestSocket {
    private let descriptor: Int32
    private var ownsDescriptor = false
    private let deadline: UInt64
    private let cancellation: LumeGuestCancellation

    init(url: URL, timeoutSeconds: UInt32, cancellation: LumeGuestCancellation) throws {
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: url.deletingLastPathComponent(), createIfMissing: false)
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600 else { throw GuestProtocolError.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GuestProtocolError.unavailable }
        var success = false
        defer { if !success { close(fd) } }
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw GuestProtocolError.unavailable
        }
        self.descriptor = fd
        self.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000
        self.cancellation = cancellation
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(url.path.utf8) + [0])
        }
        try cancellation.check()
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            guard errno == EINPROGRESS else { throw GuestProtocolError.unavailable }
            try wait(for: Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw GuestProtocolError.unavailable
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw GuestProtocolError.unauthenticated
        }
        ownsDescriptor = true
        success = true
    }

    deinit { if ownsDescriptor { close(descriptor) } }

    func send<T: Encodable>(_ value: T) throws {
        let frame = try GuestFrameCodec.encode(value)
        var offset = 0
        while offset < frame.count {
            try wait(for: Int16(POLLOUT))
            let count = frame.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count > 0 { offset += count }
            else if count == 0 || (errno != EINTR && errno != EAGAIN) { throw GuestProtocolError.disconnected }
        }
    }

    func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let header = try read(count: 4)
        let size = try GuestFrameCodec.frameSize(header: header)
        return try GuestFrameCodec.decode(read(count: size), as: type)
    }

    private func read(count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN))
            let size = result.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if size > 0 { offset += size }
            else if size == 0 || (errno != EINTR && errno != EAGAIN) { throw GuestProtocolError.disconnected }
        }
        return result
    }

    private func wait(for interest: Int16) throws {
        while true {
            try cancellation.check()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw GuestProtocolError.unavailable }
            var descriptor = pollfd(fd: self.descriptor, events: interest, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw GuestProtocolError.disconnected }
            if result == 0 { continue }
            if descriptor.revents & interest != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw GuestProtocolError.disconnected }
        }
    }
}
