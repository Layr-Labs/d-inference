import Darwin
import Foundation

/// A fresh owner-only pathname. No arbitrary descriptor inheritance is needed.
public final class ClusterBootstrapListener: @unchecked Sendable {
    public let socketPath: String
    private let directory: String
    private let socket: BootstrapSocket
    private let lock = NSLock()
    private var attempted = false

    public init(deadlineUptimeNanoseconds: UInt64) throws {
        var template = Array("/private/tmp/darkbloom-bootstrap-XXXXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw ClusterBootstrapError.system(errno) }
        let directory = String(cString: created), path = directory + "/channel"
        do {
            guard chmod(directory, 0o700) == 0 else { throw ClusterBootstrapError.system(errno) }
            var address = try bootstrapAddress(path)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ClusterBootstrapError.system(errno) }
            let socket = try BootstrapSocket(taking: fd, deadline: deadlineUptimeNanoseconds)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0 else {
                throw ClusterBootstrapError.system(errno)
            }
            self.directory = directory; socketPath = path; self.socket = socket
        } catch { unlink(path); rmdir(directory); throw error }
    }

    deinit { socket.cancel(); unlink(socketPath); rmdir(directory) }
    public func cancel() { socket.cancel() }

    public func accept(processID: Int32, identity: ClusterBootstrapIdentity,
                       deadlineUptimeNanoseconds: UInt64,
                       mode: ClusterBootstrapMode = .mesh2) throws -> ClusterBootstrapConnection {
        do {
            try lock.withLock {
                guard !attempted, processID > 1, deadlineUptimeNanoseconds <= socket.deadline else {
                    throw ClusterBootstrapError.invalid("Invalid or reused bootstrap listener")
                }
                attempted = true
            }
            while true {
                try socket.wait(Int16(POLLIN), until: deadlineUptimeNanoseconds)
                let fd = Darwin.accept(socket.descriptor, nil, nil)
                if fd < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }; throw ClusterBootstrapError.system(errno)
                }
                let accepted = try BootstrapSocket(taking: fd, deadline: deadlineUptimeNanoseconds)
                try accepted.requirePeer(processID: processID)
                socket.cancel()
                return .init(socket: accepted, identity: identity, worker: false, mode: mode)
            }
        } catch { socket.cancel(); throw error }
    }
}
