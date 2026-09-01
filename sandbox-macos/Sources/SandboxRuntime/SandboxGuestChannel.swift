import Darwin
import Foundation

/// Receives a connected guest descriptor from a spawned child over a
/// descriptor inherited before spawn.
///
/// Only the process holding the `VZVirtioSocketDevice` can establish a guest
/// vsock connection, so the child establishes it and passes the resulting
/// descriptor back through `SCM_RIGHTS`. This is the receiving half of that
/// handoff. It is deliberately separate from
/// `SandboxCooperativeProcessControl`, whose channel carries no data at all:
/// there, any byte is a fault, and EOF is the only message.
public struct SandboxGuestChannelControl: Sendable {
    public let descriptorEnvironmentVariable: String
    public let portEnvironmentVariable: String

    /// Guest vsock port the child should connect to.
    public let port: UInt32

    public init(
        descriptorEnvironmentVariable: String,
        portEnvironmentVariable: String,
        port: UInt32
    ) {
        self.descriptorEnvironmentVariable = descriptorEnvironmentVariable
        self.portEnvironmentVariable = portEnvironmentVariable
        self.port = port
    }
}

final class GuestChannelReceiver: @unchecked Sendable {
    /// Fixed descriptor number the child sees. `ProcessControlChannel` owns 3;
    /// only 0, 1, 2 and explicitly dup2'd numbers survive
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`.
    static let childDescriptor: Int32 = 4

    private let lock = NSLock()
    private var parentDescriptor: Int32
    private var childSourceDescriptor: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(
            AF_UNIX,
            SOCK_STREAM,
            0,
            &descriptors
        ) == 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to create guest channel"
            )
        }
        do {
            try Self.setCloseOnExec(descriptors[0])
            try Self.setCloseOnExec(descriptors[1])
            // The parent polls; it must never block the caller waiting for a
            // guest that may never come up.
            try Self.setNonBlocking(descriptors[0])
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
        parentDescriptor = descriptors[0]
        childSourceDescriptor = descriptors[1]
    }

    deinit {
        closeParentEndpoint()
        closeChildSourceEndpoint()
    }

    var inheritedSourceDescriptor: Int32 {
        lock.withLock { childSourceDescriptor }
    }

    /// Returns a descriptor sent by the child, or `nil` when none has arrived
    /// yet. Ownership of a returned descriptor transfers to the caller.
    ///
    /// Throws only when the channel itself has failed; a child that has not
    /// connected yet is not an error.
    func receiveDescriptor() throws -> Int32? {
        let headerSpace = Self.headerSpace
        var control = [UInt8](
            repeating: 0,
            count: headerSpace + Self.aligned(MemoryLayout<Int32>.size)
        )
        var payload: UInt8 = 0

        let (received, failure): (Int, Int32) = lock.withLock {
            guard parentDescriptor >= 0 else {
                return (-1, EBADF)
            }
            let socket = parentDescriptor
            return control.withUnsafeMutableBytes { controlBuffer -> (Int, Int32) in
                guard let controlBase = controlBuffer.baseAddress else {
                    return (-1, EINVAL)
                }
                return withUnsafeMutablePointer(
                    to: &payload
                ) { payloadPointer -> (Int, Int32) in
                    var vector = iovec(
                        iov_base: UnsafeMutableRawPointer(payloadPointer),
                        iov_len: 1
                    )
                    return withUnsafeMutablePointer(
                        to: &vector
                    ) { vectorPointer -> (Int, Int32) in
                        var message = msghdr()
                        message.msg_iov = vectorPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBase
                        message.msg_controllen = socklen_t(
                            controlBuffer.count
                        )
                        while true {
                            let result = recvmsg(socket, &message, 0)
                            if result < 0 {
                                if errno == EINTR {
                                    continue
                                }
                                return (result, errno)
                            }
                            return (result, 0)
                        }
                    }
                }
            }
        }

        if received < 0 {
            if failure == EAGAIN || failure == EWOULDBLOCK {
                return nil
            }
            throw SandboxRuntimeError.unsupported(
                "guest channel receive failed (errno \(failure))"
            )
        }
        guard received == 1 else {
            // EOF: the child exited without handing anything over.
            return nil
        }

        return control.withUnsafeBytes { controlBuffer -> Int32? in
            guard let controlBase = controlBuffer.baseAddress else {
                return nil
            }
            let header = controlBase.assumingMemoryBound(to: cmsghdr.self)
            guard header.pointee.cmsg_level == SOL_SOCKET,
                  header.pointee.cmsg_type == SCM_RIGHTS,
                  header.pointee.cmsg_len
                      >= socklen_t(headerSpace + MemoryLayout<Int32>.size)
            else {
                return nil
            }
            let descriptor = controlBase
                .advanced(by: headerSpace)
                .assumingMemoryBound(to: Int32.self)
                .pointee
            return descriptor >= 0 ? descriptor : nil
        }
    }

    func closeParentEndpoint() {
        let descriptor = lock.withLock {
            let descriptor = parentDescriptor
            parentDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    func closeChildSourceEndpoint() {
        let descriptor = lock.withLock {
            let descriptor = childSourceDescriptor
            childSourceDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    // MARK: - Control-message geometry

    /// `__DARWIN_ALIGN32`. The `CMSG_*` macros are not visible to Swift, so the
    /// layout is reproduced here and asserted by a round-trip test.
    fileprivate static func aligned(_ size: Int) -> Int {
        (size + 3) & ~3
    }

    fileprivate static var headerSpace: Int {
        aligned(MemoryLayout<cmsghdr>.size)
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to secure guest channel"
            )
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to configure guest channel"
            )
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
