import Darwin
import Dispatch
import Foundation
import SandboxGuestProtocol

public enum GuestSocketServer {
    public static func serve(configuration: GuestConfiguration) async throws {
        let executor = try GuestTenantExecutor(configuration: configuration)
        let workspace = try await GuestWorkspaceBootstrap.prepare(
            path: configuration.workspacePath, tenantUID: configuration.tenantUID,
            tenantGID: configuration.tenantGID, quiesce: { try await executor.prepare() })
        let handler = GuestRequestHandler(executor: executor, workspace: workspace)
        let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listener >= 0 else { throw GuestProtocolError.unavailable }
        defer { close(listener) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_cid = VMADDR_CID_ANY
        address.svm_port = GuestProtocolLimits.port
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard status == 0, listen(listener, 1) == 0 else { throw GuestProtocolError.unavailable }
        let queue = DispatchQueue(label: "io.darkbloom.sandbox.guest.accept")
        while !Task.isCancelled {
            let client: Int32 = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: accept(listener, nil, nil)) }
            }
            if client < 0 && errno == EINTR { continue }
            guard client >= 0 else { throw GuestProtocolError.disconnected }
            var peer = sockaddr_vm()
            var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let peerStatus = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(client, $0, &length) }
            }
            guard peerStatus == 0, peer.svm_family == AF_VSOCK, peer.svm_cid == 2 else {
                close(client); continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            try await handler.beginSession()
            let connection = GuestConnection(descriptor: client)
            do {
                try await connection.serve(instanceID: configuration.instanceID,
                    credential: configuration.credential, handler: handler)
            } catch {
                // Connection errors contain no tenant input or credentials.
            }
            _ = shutdown(client, SHUT_RDWR)
            await handler.disconnect()
            await connection.waitForResponses()
            close(client)
        }
    }
}

/// Testable with an ordinary socketpair; production calls only after AF_VSOCK
/// peer validation. One reader serializes sequence checks; bounded independent
/// response tasks let cancel reach a running execution.
public final class GuestConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "io.darkbloom.sandbox.guest.read")
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let responses = DispatchGroup()
    private var pending = 0

    public init(descriptor: Int32) { self.descriptor = descriptor }

    public func serve(instanceID: UUID, credential: Data, handler: GuestRequestHandler) async throws {
        let hello = try GuestHello(instanceID: instanceID)
        var authenticator = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: instanceID, credential: credential)
        try write(GuestFrameCodec.encode(hello))
        while !Task.isCancelled {
            let payload = try await readFrame()
            let frame = try GuestFrameCodec.decode(payload, as: GuestAuthenticatedFrame.self)
            let request = try authenticator.accept(frame)
            let admitted = lock.withLock {
                guard pending < 32 else { return false }
                pending += 1; return true
            }
            guard admitted else { throw GuestProtocolError.busy }
            responses.enter()
            let signing = authenticator
            Task {
                defer {
                    lock.withLock { pending -= 1 }
                    responses.leave()
                }
                let response = await handler.handle(request)
                do {
                    let signed = try signing.seal(response, sequence: frame.sequence, direction: .response)
                    try write(GuestFrameCodec.encode(signed))
                } catch { _ = shutdown(descriptor, SHUT_RDWR) }
            }
        }
    }

    public func waitForResponses() async {
        await withCheckedContinuation { continuation in
            responses.notify(queue: .global()) { continuation.resume() }
        }
    }

    private func write(_ data: Data) throws {
        try writeLock.withLock { try GuestDescriptor.write(descriptor, data: data) }
    }

    private func readFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [descriptor] in
                do {
                    let header = try GuestDescriptor.read(descriptor, count: 4)
                    let size = try GuestFrameCodec.frameSize(header: header)
                    continuation.resume(returning: try GuestDescriptor.read(descriptor, count: size))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
