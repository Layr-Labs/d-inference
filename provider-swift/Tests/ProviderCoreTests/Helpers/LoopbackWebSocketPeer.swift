import Foundation
import Network

/// A loopback WebSocket server that completes the upgrade and then behaves as
/// `behavior` says. It records when it accepts each connection.
final class LoopbackWebSocketPeer: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Never reads, never answers a ping and never sends: a link whose
        /// far end vanished without a TCP reset or a close frame.
        case silent
        /// Reads and drops every message, and answers pings.
        case answersPings
        /// Never reads and never answers a ping, but sends `frame` as a text
        /// message every `interval`: a busy stream whose pongs are late.
        case streams(frame: Data, interval: DispatchTimeInterval)
    }

    private let listener: NWListener
    private let behavior: Behavior
    private let queue = DispatchQueue(label: "loopback-websocket-peer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var acceptTimes: [ContinuousClock.Instant] = []
    private var timers: [DispatchSourceTimer] = []

    init(behavior: Behavior) throws {
        self.behavior = behavior
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        if case .answersPings = behavior { options.autoReplyPing = true } else { options.autoReplyPing = false }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
    }

    /// When each connection was accepted, in order.
    var accepted: [ContinuousClock.Instant] { lock.withLock { acceptTimes } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.withLock {
                self.connections.append(connection)
                self.acceptTimes.append(.now)
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self else { return }
                self.serve(connection)
            }
            connection.start(queue: self.queue)
        }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let (connections, timers) = lock.withLock { (self.connections, self.timers) }
        for timer in timers { timer.cancel() }
        for connection in connections { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        switch behavior {
        case .silent:
            break
        case .answersPings:
            readAndDrop(connection)
        case .streams(let frame, let interval):
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler {
                let text = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "stream", metadata: [text])
                connection.send(content: frame, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
            }
            lock.withLock { timers.append(timer) }
            timer.resume()
        }
    }

    private func readAndDrop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            guard error == nil, let self else { return }
            self.readAndDrop(connection)
        }
    }
}
