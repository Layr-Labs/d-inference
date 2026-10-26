/// Close-code rows: how the provider reads the code of a coordinator close
/// frame from what Network.framework, a third party, reports.
/// `CoordinatorClient` reads the code in its receive callback to choose its
/// reconnect wait (`CoordinatorReconnectPolicy`). Network.framework names only
/// the codes that it knows; it reports others, such as 1012, as
/// `noStatusReceived` and delivers the frame's payload as the message content.
/// The contract row drives a plain `NWConnection` with the WebSocket protocol;
/// `MockCoordinator` writes the close frame.

import Foundation
import Network
import Testing

@testable import ProviderCore

@Suite("Network.framework WebSocket close codes", .serialized)
struct NetworkFrameworkCloseCodeTests {

    @Test("each Network.framework close-code case gives the code number on the wire")
    func closeCodeWireValue() {
        #expect(NWProtocolWebSocket.CloseCode.protocolCode(.goingAway).wireValue == 1001)
        #expect(NWProtocolWebSocket.CloseCode.applicationCode(3001).wireValue == 3001)
        #expect(NWProtocolWebSocket.CloseCode.privateCode(4001).wireValue == 4001)
    }

    @Test("a close code that Network.framework does not name comes from the frame's payload")
    func sentCloseCodeReadsThePayloadForAnUnnamedCode() {
        let unnamed = NWProtocolWebSocket.Metadata(opcode: .close)
        unnamed.closeCode = .protocolCode(.noStatusReceived)
        let payload = Data([0x03, 0xF4]) + Data("conductor failover".utf8)
        #expect(unnamed.sentCloseCode(content: payload) == 1012)
        // The content can be a slice that does not start at index 0.
        #expect(unnamed.sentCloseCode(content: Data([0xFF, 0x03, 0xF5]).dropFirst()) == 1013)
        // Without two payload bytes the frame carries no code.
        #expect(unnamed.sentCloseCode(content: nil) == 1005)
        #expect(unnamed.sentCloseCode(content: Data([0x03])) == 1005)

        // A code that Network.framework names is used as it reports it.
        let named = NWProtocolWebSocket.Metadata(opcode: .close)
        named.closeCode = .protocolCode(.goingAway)
        #expect(named.sentCloseCode(content: payload) == 1001)
    }

    /// The codes that the coordinator side sends: 1000, 1008 and 1013 from the
    /// coordinator's session code, 1012 from the edge on a Conductor change, and
    /// 1001 from `MockCoordinator`'s ordinary drops.
    @Test("the provider reads the code of the coordinator's close frame from Network.framework",
          .timeLimit(.minutes(1)),
          arguments: [UInt16(1000), 1001, 1008, 1012, 1013])
    func providerReadsCloseCodeFromNetworkFramework(code: UInt16) async throws {
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
        #expect(end.sentCloseCode == code, "Network.framework reported \(end)")
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
    var sentCloseCode: UInt16?
    var isComplete: Bool
    var contentPrefix: String?

    var description: String {
        let opcodeText = opcode.map { "\($0)" } ?? "none"
        return "error=\(error ?? "none"), opcode=\(opcodeText), "
            + "closeCode=\(closeCodeCase ?? "none"), isComplete=\(isComplete), "
            + "content starts with \(contentPrefix ?? "no content")"
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
                    sentCloseCode: close?.sentCloseCode(content: data),
                    isComplete: isComplete,
                    contentPrefix: data.map { $0.prefix(4).map { String(format: "%02x", $0) }.joined() }))
            }
        }
        if end.error == nil, end.opcode == .ping || end.opcode == .pong { continue }
        return end
    }
}
