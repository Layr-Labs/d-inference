import Foundation
import SandboxGuestProtocol

/// Connects only to the broker's private VM socket. Every request receives a
/// fresh guest challenge and verifies both the reply sequence and request ID.
public struct LumeGuestClient: Sendable {
    public let socketURL: URL
    public let instanceID: UUID
    private let credential: Data

    public init(socketURL: URL, instanceID: UUID, credential: Data) throws {
        guard socketURL.isFileURL, socketURL.path.hasPrefix("/"),
              socketURL.path.utf8.count < 104, credential.count == 32 else {
            throw GuestProtocolError.invalidConfiguration
        }
        self.socketURL = socketURL
        self.instanceID = instanceID
        self.credential = credential
    }

    public func request(_ request: GuestRequest, timeoutSeconds: UInt32 = 30) async throws -> GuestResponse {
        guard (1...960).contains(timeoutSeconds) else { throw GuestProtocolError.invalidConfiguration }
        let cancellation = LumeGuestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                let socket = try LumeGuestSocket(url: socketURL, timeoutSeconds: timeoutSeconds,
                                                 cancellation: cancellation)
                let hello = try socket.receive(GuestHello.self)
                let authentication = try GuestSessionAuthenticator(
                    hello: hello, expectedInstanceID: instanceID, credential: credential)
                try socket.send(authentication.seal(request, sequence: 1, direction: .request))
                let frame = try socket.receive(GuestAuthenticatedFrame.self)
                guard frame.sequence == 1 else { throw GuestProtocolError.invalidSequence }
                let reply = try authentication.open(frame, as: GuestResponse.self, direction: .response)
                guard reply.id == request.id else { throw GuestProtocolError.invalidMessage }
                return reply
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Cancellation is observed by the I/O thread through bounded poll intervals;
/// it never closes a descriptor another thread could still be using.
final class LumeGuestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
