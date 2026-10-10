import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Real loopback HTTP stack with a fabricated owner: a client that hangs up
/// ends its request with the owner's clean stop and the host serves the next
/// one; a lost rank reaches the client as an error frame before the stream
/// ends, while the request's resources stay owned until retirement.
@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPCleanStopTests {
    private func start(cleanStop: Bool) async throws -> (DistributedLocalServer, LocalHostTestSession, UInt16) {
        let session = LocalHostTestSession(); session.lifetimeNanoseconds = 15_000_000_000
        session.base.leasesAcceptCleanStop = cleanStop
        let host = DistributedLocalServer(session: session, config: .init(host: "127.0.0.1", port: 0),
            firstTokenBudgetPolicy: try .init(baseMilliseconds: 10_000, millisecondsPerInputToken: 0),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
        try await host.start()
        return (host, session, try #require(await host.status.boundPort))
    }

    private func request(model: String, maxTokens: Int) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["model": model,
            "messages": [["role": "user", "content": "fixture"]], "temperature": 0,
            "max_tokens": maxTokens, "stream": true])
        var bytes = Data(("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        bytes.append(body); return bytes
    }

    @Test func clientHangUpMidStreamIsACleanStopAndTheNextRequestIsServed() async throws {
        let (host, session, port) = try await start(cleanStop: true)
        let socket = try await HTTPRawSocket.open(port: port, request: request(model: session.model.publicModelID, maxTokens: 8))
        defer { socket.close() }
        _ = try await socket.read(until: "\"role\":\"assistant\"")
        let lease = session.base.last
        #expect(lease.send(.token(4)))
        _ = try await socket.read(until: "t4")
        socket.close() // the client goes away mid-stream
        #expect(try await httpDeliveryEventually { lease.cleanStopCount == 1 })
        #expect(lease.cancelCount == 0)
        #expect(!lease.send(.token(5))) // the token that answers the stop
        lease.acknowledge()
        #expect(try await httpDeliveryEventually { lease.releaseCount == 1 })
        #expect(lease.cancelCount == 0)
        #expect(await host.status.phase == .serving)
        let next = try await HTTPRawSocket.open(port: port, request: request(model: session.model.publicModelID, maxTokens: 1))
        defer { next.close() }
        _ = try await next.read(until: "\"role\":\"assistant\"")
        #expect(try await httpDeliveryEventually { session.base.reserveCount == 2 })
        #expect(!session.base.last.send(.token(6)))
        session.base.last.acknowledge()
        let served = try await next.read(until: "data: [DONE]")
        #expect(served.contains("t6") && !served.contains("\"error\""))
        _ = await host.stop(until: localHostDeadline())
    }

    @Test func aLostRankReachesTheClientAsAnErrorFrameBeforeTheStreamEnds() async throws {
        let (host, session, port) = try await start(cleanStop: true)
        let socket = try await HTTPRawSocket.open(port: port, request: request(model: session.model.publicModelID, maxTokens: 8))
        defer { socket.close() }
        _ = try await socket.read(until: "\"role\":\"assistant\"")
        let lease = session.base.last
        #expect(lease.send(.token(4)))
        _ = try await socket.read(until: "t4")
        session.base.losePeer()
        // No acknowledgement yet: the surviving rank may need its whole
        // progress limit to retire. The client is told now.
        let tail = try await socket.read(until: "data: [DONE]")
        #expect(tail.contains("\"error\"") && tail.contains("inference_error"))
        #expect(tail.contains("attempt_usage"))
        #expect(lease.cancelCount == 1 && lease.releaseCount == 0)
        lease.acknowledge()
        #expect(try await httpDeliveryEventually { lease.releaseCount == 1 })
        _ = await host.stop(until: localHostDeadline())
    }
}
