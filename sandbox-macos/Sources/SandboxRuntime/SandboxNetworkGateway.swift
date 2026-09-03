import Darwin
import Foundation

/// Names the descriptor a spawned VM reads its network attachment from.
///
/// Same shape as `SandboxGuestChannelControl`, and for the same reason: the
/// number has to reach the child through the environment because
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything the parent does not
/// explicitly `dup2`.
public struct SandboxNetworkGatewayControl: Sendable {
    public let descriptorEnvironmentVariable: String

    public init(descriptorEnvironmentVariable: String) {
        self.descriptorEnvironmentVariable = descriptorEnvironmentVariable
    }
}

/// The host end of a guest's link-layer connection.
///
/// `VZFileHandleNetworkDeviceAttachment` requires "a connected datagram
/// socket" and exchanges data "at the level of the data link layer", so this
/// pair carries whole Ethernet frames: one datagram is exactly one frame, with
/// no length prefix and no reassembly. A stream socket would appear to work and
/// then deliver spliced frames, which is why the guest end is checked for
/// `SOCK_DGRAM` before it is ever attached.
public final class NetworkGatewayEndpoint: @unchecked Sendable {
    /// Fixed descriptor the child sees. 3 is the cooperative control channel
    /// and 4 is the guest vsock channel, so the gateway takes 5.
    public static let childDescriptor: Int32 = 5

    /// Apple's header requires `SO_RCVBUF` to be at least twice `SO_SNDBUF`
    /// and recommends four times. The parent end is sized to match the guest
    /// end so neither direction is the bottleneck.
    static let sendBufferBytes: Int32 = 1 * 1024 * 1024
    static let receiveBufferBytes: Int32 = 4 * sendBufferBytes

    /// An Ethernet frame at the default 1500-byte MTU plus its header; sized
    /// for the maximum the attachment allows so an oversized frame is seen and
    /// dropped rather than silently truncated into a valid-looking one.
    public static let maximumFrameBytes = 65_535

    private let lock = NSLock()
    private var hostDescriptor: Int32
    private var childSourceDescriptor: Int32

    public init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to create the guest network endpoint"
            )
        }
        do {
            for descriptor in descriptors {
                try Self.setCloseOnExec(descriptor)
                try Self.setBuffer(SO_SNDBUF, Self.sendBufferBytes, descriptor)
                try Self.setBuffer(SO_RCVBUF, Self.receiveBufferBytes, descriptor)
            }
            // The gateway polls. A blocking read would stall the daemon on a
            // guest that never sends, and a blocking write would stall it on a
            // guest that has stopped reading.
            try Self.setNonBlocking(descriptors[0])
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
        hostDescriptor = descriptors[0]
        childSourceDescriptor = descriptors[1]
    }

    deinit {
        closeHostEndpoint()
        closeChildSourceEndpoint()
    }

    public var inheritedSourceDescriptor: Int32 {
        lock.withLock { childSourceDescriptor }
    }

    /// The descriptor the gateway reads and writes frames on.
    public var frameDescriptor: Int32 {
        lock.withLock { hostDescriptor }
    }

    public func closeHostEndpoint() {
        lock.withLock {
            if hostDescriptor >= 0 {
                close(hostDescriptor)
                hostDescriptor = -1
            }
        }
    }

    public func closeChildSourceEndpoint() {
        lock.withLock {
            if childSourceDescriptor >= 0 {
                close(childSourceDescriptor)
                childSourceDescriptor = -1
            }
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to secure the guest network endpoint"
            )
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to make the guest network endpoint non-blocking"
            )
        }
    }

    private static func setBuffer(
        _ option: Int32,
        _ bytes: Int32,
        _ descriptor: Int32
    ) throws {
        var value = bytes
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to size the guest network endpoint buffers"
            )
        }
    }
}
