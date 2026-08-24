import Darwin
import Foundation

/// Requests child shutdown by closing a descriptor inherited before spawn.
///
/// The child observes EOF even when the parent closes its endpoint before the
/// child begins monitoring the descriptor.
public struct SandboxCooperativeProcessControl: Sendable {
    public let environmentVariable: String

    public init(environmentVariable: String) {
        self.environmentVariable = environmentVariable
    }
}

final class ProcessControlChannel: @unchecked Sendable {
    static let childDescriptor: Int32 = 3

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
                "failed to create cooperative process control channel"
            )
        }
        do {
            try Self.setCloseOnExec(descriptors[0])
            try Self.setCloseOnExec(descriptors[1])
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

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to secure cooperative process control channel"
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
