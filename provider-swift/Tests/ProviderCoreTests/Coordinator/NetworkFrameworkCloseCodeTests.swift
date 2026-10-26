/// Contract rows for Network.framework, a third party: what the WebSocket
/// receive callback reports when the coordinator side closes the socket with a
/// code. `CoordinatorClient` reads the code in that callback to choose its
/// reconnect wait (`CoordinatorReconnectPolicy`), so it can act only on a code
/// that Network.framework reports. `MockCoordinator` writes the close frame; the
/// client side is a plain `NWConnection` with the WebSocket protocol.

import Foundation
import Network
import Testing

@testable import ProviderCore

@Suite("Network.framework WebSocket close codes", .serialized)
struct NetworkFrameworkCloseCodeTests {

    @Test("the receive callback reports the code of the coordinator's close frame",
          .timeLimit(.minutes(1)),
          arguments: [UInt16(1001), 1012, 1013, 4012])
    func receiveCallbackReportsCloseCode(code: UInt16) async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
        var mockEvents = mock.events.makeAsyncIterator()

        let url = try #require(URL(string: baseURL.mockProviderWebSocketURL()))
        let connection = NWConnection(to: .url(url), using: webSocketParameters())
        defer { connection.cancel() }
        try await startAndWaitUntilReady(connection)
        // The stand-in holds the socket once its WebSocket handler runs.
        while let event = await mockEvents.next() {
            if case .wsConnected = event { break }
        }

        let received = Task { await receiveUntilCloseOrError(connection) }
        await mock.dropActiveWebSocket(closeCode: code, reason: "conductor failover")
        let end = await received.value
        #expect(end.closeCode == code, "Network.framework reported \(end)")
    }
}

/// TCP plus the WebSocket protocol with automatic ping replies, as
/// `CoordinatorClient` uses them for a `ws://` URL.
private func webSocketParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    return parameters
}

/// Starts `connection` and returns when the WebSocket handshake is complete.
private func startAndWaitUntilReady(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                cont.resume()
            case .failed(let error), .waiting(let error):
                connection.stateUpdateHandler = nil
                cont.resume(throwing: error)
            case .cancelled:
                connection.stateUpdateHandler = nil
                cont.resume(throwing: CancellationError())
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "dev.darkbloom.tests.close-code"))
    }
}

/// What the receive callback reported for the first message that was not a
/// ping or a pong, or for the receive that ended with an error.
private struct ReceivedEnd: Sendable, CustomStringConvertible {
    var error: String?
    var opcode: NWProtocolWebSocket.Opcode?
    var closeCodeCase: String?
    var closeCode: UInt16?
    var isComplete: Bool
    var content: String?

    var description: String {
        let opcodeText = opcode.map { "\($0)" } ?? "none"
        let contentText = content.map { "\"\($0)\"" } ?? "none"
        return "error=\(error ?? "none"), opcode=\(opcodeText), "
            + "closeCode=\(closeCodeCase ?? "none"), isComplete=\(isComplete), content=\(contentText)"
    }
}

private func receiveUntilCloseOrError(_ connection: NWConnection) async -> ReceivedEnd {
    while true {
        let end: ReceivedEnd = await withCheckedContinuation { cont in
            connection.receiveMessage { data, context, isComplete, error in
                let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                let close = metadata?.opcode == .close ? metadata : nil
                cont.resume(returning: ReceivedEnd(
                    error: error.map { "\($0)" },
                    opcode: metadata?.opcode,
                    closeCodeCase: close.map { "\($0.closeCode)" },
                    closeCode: close?.closeCode.wireValue,
                    isComplete: isComplete,
                    content: data.map { String(decoding: $0, as: UTF8.self) }))
            }
        }
        if end.error == nil, end.opcode == .ping || end.opcode == .pong { continue }
        return end
    }
}
