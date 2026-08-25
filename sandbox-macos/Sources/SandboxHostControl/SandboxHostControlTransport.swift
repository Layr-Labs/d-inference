import Foundation
import SandboxCore

public enum SandboxHostControlTransportError: Error, Sendable {
    case disconnected
    case nonTextFrame
    case invalidTextFrame
    case sessionMismatch
    case sequenceReplay
}

public protocol SandboxHostControlTransport: Sendable {
    func connect(request: URLRequest) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func ping() async throws
    func close() async
}

public actor URLSessionSandboxHostControlTransport:
    SandboxHostControlTransport
{
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(request: URLRequest) async throws {
        guard task == nil else {
            throw SandboxHostControlTransportError.disconnected
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = SandboxControlCodec.maximumFrameBytes
        self.task = task
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task else {
            throw SandboxHostControlTransportError.disconnected
        }
        try await task.send(.string(text))
    }

    public func receiveText() async throws -> String {
        guard let task else {
            throw SandboxHostControlTransportError.disconnected
        }
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data:
            throw SandboxHostControlTransportError.nonTextFrame
        @unknown default:
            throw SandboxHostControlTransportError.invalidTextFrame
        }
    }

    public func ping() async throws {
        guard let task else {
            throw SandboxHostControlTransportError.disconnected
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func close() async {
        let closing = task
        task = nil
        closing?.cancel(with: .normalClosure, reason: nil)
    }
}
