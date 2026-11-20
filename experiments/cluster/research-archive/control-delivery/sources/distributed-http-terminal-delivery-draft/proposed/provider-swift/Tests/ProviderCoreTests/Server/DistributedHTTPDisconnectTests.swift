import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPDisconnectTests {
    private func start() async throws -> (DistributedLocalServer, LocalHostTestSession, UInt16) {
        let session = LocalHostTestSession(); session.lifetimeNanoseconds = 15_000_000_000
        let host = DistributedLocalServer(session: session, config: .init(host: "127.0.0.1", port: 0),
            firstTokenBudgetPolicy: .init(baseMilliseconds: 10_000, millisecondsPerInputToken: 0),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
        try await host.start()
        return (host, session, try #require(await host.status.boundPort))
    }

    private func request(model: String) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["model": model,
            "messages": [["role": "user", "content": "fixture"]], "temperature": 0,
            "max_tokens": 1, "stream": true])
        var bytes = Data(("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        bytes.append(body); return bytes
    }

    @Test func actualFullSocketCloseCancelsBeforeFirstTokenDeadline() async throws {
        let (host, session, port) = try await start()
        let socket = try await HTTPRawSocket.open(port: port, request: request(model: session.model.publicModelID))
        defer { socket.close() }
        _ = try await socket.read(until: "\"role\":\"assistant\"")
        #expect(session.base.reserveCount == 1)
        let lease = session.base.last, began = ContinuousClock.now
        socket.close() // real FIN/full client close; no Task.cancel/parent stop
        #expect(try await httpDeliveryEventually { lease.cancelCount == 1 })
        #expect(began.duration(to: ContinuousClock.now) < .seconds(2)) // configured first-token budget is ten seconds
        #expect(lease.releaseCount == 0)
        lease.acknowledge()
        #expect(try await httpDeliveryEventually { lease.releaseCount == 1 })
        _ = await host.stop(until: localHostDeadline())
    }

    @Test func actualWriteHalfCloseMayContinueReadingProbesAndContent() async throws {
        let (host, session, port) = try await start()
        let socket = try await HTTPRawSocket.open(port: port, request: request(model: session.model.publicModelID))
        defer { socket.close() }
        try socket.halfCloseWrite() // valid HTTP half-close, not a cancellation signal
        let initial = try await socket.read(until: ": keep-alive")
        #expect(initial.contains("\"role\":\"assistant\""))
        #expect(session.base.reserveCount == 1 && session.base.last.cancelCount == 0)
        let lease = session.base.last
        #expect(!lease.send(.token(4))) // normal one-token length finish
        #expect(lease.releaseCount == 0)
        lease.acknowledge()
        let final = try await socket.read(until: "data: [DONE]")
        #expect(final.contains("t4") && !final.contains("\"error\""))
        #expect(lease.releaseCount == 1 && lease.cancelCount == 0)
        _ = await host.stop(until: localHostDeadline())
    }

    @Test func framePumpBacklogIsOneAndCancellationUnblocksTheProducer() async throws {
        let (frames, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
        defer { pump.cancel() }
        continuation.yield("one"); continuation.yield("two"); continuation.finish()
        #expect(try await httpDeliveryEventually { pump.pendingFrames == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(pump.pendingFrames == 1)
        guard case .frame("one") = pump.take() else { Issue.record("Wrong pending frame"); return }
        #expect(try await httpDeliveryEventually { pump.pendingFrames == 1 })
        let producer = pump.cancel()
        await producer?.value
        #expect(pump.pendingFrames == 0 && pump.take() == nil)
    }
}
