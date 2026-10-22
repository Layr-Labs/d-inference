import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// One completion through the real local HTTP stack, the bridge and the
/// distributed engine, against a fabricated owner. The test stands in for the
/// worker pair: it emits committed tokens and acknowledges retirement.
/// No model, child process or peer runs; this is not a hardware result.
private struct DistributedCompletionFixture {
    let session = LocalHostTestSession()
    let host: DistributedLocalServer
    let port: UInt16

    init(firstTokenBudgetMilliseconds: Int64) async throws {
        session.lifetimeNanoseconds = 30_000_000_000
        host = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: "fixture-token"),
            firstTokenBudgetPolicy: try .init(
                baseMilliseconds: firstTokenBudgetMilliseconds, millisecondsPerInputToken: 0),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) },
            // A short queue, so the full-queue case stays quick.
            queue: .init(maximumWaiting: 8))
        try await host.start()
        port = try #require(await host.status.boundPort)
    }

    /// The fixture tokenizer renders every prompt as three tokens and decodes
    /// token `n` as the text `tn`.
    func request(stream: Bool, temperature: Double = 0, maxTokens: Int? = 2,
                 extra: [String: Any] = [:]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": session.model.publicModelID,
            "messages": [["role": "user", "content": "fixture"]], "temperature": temperature,
            "stream": stream, "reasoning_parser": "none"]
        if let maxTokens { body["max_tokens"] = maxTokens }
        body.merge(extra) { $1 }
        if stream { body["stream_options"] = ["include_usage": true] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Waits for the request's native start, as a worker pair would observe it.
    func startedLease(_ count: Int = 1) async throws -> DistributedTestLease {
        try #require(try await httpDeliveryEventually { session.base.reserveCount == count })
        let lease = session.base.last
        try #require(try await httpDeliveryEventually { lease.startCount == 1 })
        return lease
    }

    /// Two committed tokens reach `max_tokens`; the pair then retires cleanly.
    func completeTwoTokens(_ lease: DistributedTestLease) {
        #expect(lease.send(.token(4)))
        #expect(!lease.send(.token(5)))
        #expect(lease.cancelCount == 0 && lease.releaseCount == 0)
        lease.acknowledge()
    }

    /// Retires any request a failed test left active, then stops the listener.
    func release() async {
        if session.base.reserveCount > 0 { session.base.last.acknowledge() }
        _ = await host.stop(until: localHostDeadline())
    }
}

private func withCompletionFixture(
    firstTokenBudgetMilliseconds: Int64 = 10_000,
    _ body: (DistributedCompletionFixture) async throws -> Void
) async throws {
    let fixture = try await DistributedCompletionFixture(
        firstTokenBudgetMilliseconds: firstTokenBudgetMilliseconds)
    do { try await body(fixture) } catch {
        await fixture.release()
        throw error
    }
    await fixture.release()
}

/// The `data:` payloads of an SSE body, skipping `:` keep-alive comments.
private func serverSentPayloads(_ body: String) -> [String] {
    body.components(separatedBy: "\n\n").compactMap { frame in
        frame.hasPrefix("data: ") ? String(frame.dropFirst(6)) : nil
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func tokenCounts(_ object: [String: Any]) -> [Int?] {
    let usage = object["usage"] as? [String: Any]
    return ["prompt_tokens", "completion_tokens", "total_tokens"].map { usage?[$0] as? Int }
}

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPCompletionTests {
    @Test func streamedCompletionDeliversRoleContentFinishWithUsageAndDone() async throws {
        try await withCompletionFixture { fixture in
            let request = try fixture.request(stream: true)
            let client = Task { try await URLSession.shared.data(for: request) }
            let lease = try await fixture.startedLease()
            fixture.completeTwoTokens(lease)

            let (data, reply) = try await client.value
            let http = try #require(reply as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true)
            let body = String(decoding: data, as: UTF8.self)
            #expect(body.hasSuffix("data: [DONE]\n\n") && !body.contains("\"error\""))

            let payloads = serverSentPayloads(body)
            #expect(payloads.last == "[DONE]")
            let chunks = try payloads.dropLast().map { try jsonObject(Data($0.utf8)) }
            let choices = try chunks.map { try #require(($0["choices"] as? [[String: Any]])?.first) }
            let deltas = choices.map { $0["delta"] as? [String: Any] ?? [:] }
            #expect(deltas.first?["role"] as? String == "assistant")
            #expect(deltas.compactMap { $0["content"] as? String }.joined() == "t4t5")
            // Exactly one finish frame, last before DONE, carrying the native usage.
            #expect(choices.compactMap { $0["finish_reason"] as? String } == ["length"])
            #expect(choices.last?["finish_reason"] as? String == "length")
            #expect(tokenCounts(try #require(chunks.last)) == [3, 2, 5])
            #expect(lease.releaseCount == 1 && lease.cancelCount == 0)
        }
    }

    @Test func nonStreamedCompletionReturnsContentAndUsage() async throws {
        try await withCompletionFixture { fixture in
            let request = try fixture.request(stream: false)
            let client = Task { try await URLSession.shared.data(for: request) }
            let lease = try await fixture.startedLease()
            fixture.completeTwoTokens(lease)

            let (data, reply) = try await client.value
            #expect((reply as? HTTPURLResponse)?.statusCode == 200)
            let object = try jsonObject(data)
            let choice = try #require((object["choices"] as? [[String: Any]])?.first)
            #expect((choice["message"] as? [String: Any])?["content"] as? String == "t4t5")
            #expect(choice["finish_reason"] as? String == "length")
            #expect(tokenCounts(object) == [3, 2, 5])
            #expect(lease.releaseCount == 1 && lease.cancelCount == 0)
        }
    }

    /// A request the pair can never serve as asked (here `max_tokens` over
    /// the model's output limit) is refused with 400 and the reason, streamed
    /// or not, before any event-stream header. A refusal has no native
    /// terminal, so a stream must answer it as the non-streamed request does.
    @Test func refusedStreamAdmissionAnswersBeforeEventStreamHeaders() async throws {
        try await withCompletionFixture { fixture in
            for stream in [false, true] {
                let (data, reply) = try await URLSession.shared.data(
                    for: try fixture.request(stream: stream, maxTokens: 129))
                let http = try #require(reply as? HTTPURLResponse)
                #expect(http.statusCode == 400, "stream=\(stream) answered \(http.statusCode)")
                #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
                let error = try #require(try jsonObject(data)["error"] as? [String: Any])
                #expect(error["code"] as? String == "output_too_long")
                #expect((error["message"] as? String)?.contains("output limit of 128 tokens") == true)
                #expect(!String(decoding: data, as: UTF8.self).contains("data:"))
            }
            #expect(fixture.session.base.reserveCount == 0)
            // The refusal released its acquisition and response hold: the next request is served.
            let request = try fixture.request(stream: true)
            let client = Task { try await URLSession.shared.data(for: request) }
            fixture.completeTwoTokens(try await fixture.startedLease())
            let served = String(decoding: try await client.value.0, as: UTF8.self)
            #expect(served.contains("t4") && served.hasSuffix("data: [DONE]\n\n"))
        }
    }

    /// A non-streamed request has no HTTP content timer, so only the engine
    /// can enforce the first-token budget selected at the HTTP origin.
    @Test func nonStreamedRequestIsCancelledAtItsFirstTokenBudget() async throws {
        try await withCompletionFixture(firstTokenBudgetMilliseconds: 800) { fixture in
            let request = try fixture.request(stream: false)
            let sent = ContinuousClock.now
            let client = Task { try await URLSession.shared.data(for: request) }
            let lease = try await fixture.startedLease()
            // No token is committed. The pair is cancelled at the budget, and
            // nothing is released until it acknowledges retirement.
            #expect(try await httpDeliveryEventually { lease.cancelCount == 1 },
                    "no cancellation within two seconds of an 800 ms first-token budget")
            #expect(sent.duration(to: ContinuousClock.now) >= .milliseconds(800))
            #expect(lease.releaseCount == 0)
            lease.acknowledge()

            let (data, reply) = try await client.value
            #expect((reply as? HTTPURLResponse)?.statusCode == 500) // prefill_stall
            #expect(try jsonObject(data)["error"] != nil)
            // The release follows the acknowledged retirement on the engine's
            // queue; the HTTP error can reach the client first.
            #expect(try await httpDeliveryEventually { lease.releaseCount == 1 })
        }
    }

    /// Sampling is served on the pair, not refused: the owner receives the
    /// request's temperature and seed (the decoding rank's sampler keys on them).
    @Test func sampledRequestIsServedWithItsSeed() async throws {
        try await withCompletionFixture { fixture in
            let request = try fixture.request(stream: true, temperature: 0.7, extra: ["seed": 42, "top_p": 0.9])
            let client = Task { try await URLSession.shared.data(for: request) }
            fixture.completeTwoTokens(try await fixture.startedLease())
            let (data, reply) = try await client.value
            #expect((reply as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
            let reserved = try #require(fixture.session.base.reservedRequests.last)
            #expect(reserved.sampling.temperature == 0.7 && reserved.sampling.seed == 42)
            #expect(abs(reserved.sampling.topP - 0.9) < 1e-6)
        }
    }

    /// An omitted `max_tokens` takes the product's default (here cut to the
    /// fixture profile's output limit), never a refusal.
    @Test func omittedMaxTokensIsTheDefaultNotARefusal() async throws {
        try await withCompletionFixture { fixture in
            let client = Task { try await URLSession.shared.data(for: try fixture.request(stream: false, maxTokens: nil)) }
            let lease = try await fixture.startedLease()
            #expect(fixture.session.base.reservedRequests.last?.maxTokens == 128)
            lease.send(.token(4)); lease.send(.token(99)); lease.acknowledge()
            #expect((try await client.value.1 as? HTTPURLResponse)?.statusCode == 200)
        }
    }

    /// More than one request at a time: later requests wait in arrival order
    /// and each starts when the one before it has retired; a full queue is 429.
    @Test func concurrentRequestsQueueInArrivalOrderAndAFullQueueIs429() async throws {
        try await withCompletionFixture(firstTokenBudgetMilliseconds: 800) { fixture in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 32
            let client = URLSession(configuration: configuration)
            defer { client.invalidateAndCancel() }
            let first = Task { try await client.data(for: try fixture.request(stream: true, maxTokens: 2)) }
            let firstLease = try await fixture.startedLease(1)
            // Queued requests are told apart by their max_tokens (3, 4, ...).
            var queued: [Task<(Data, URLResponse), Error>] = []
            for index in 0..<fixture.host.queue.maximumWaiting {
                let stream = index % 2 == 0
                let request = try fixture.request(stream: stream, maxTokens: 3 + index)
                queued.append(Task { try await client.data(for: request) })
                #expect(try await localHostEventually { await fixture.host.waiting.count == index + 1 })
            }
            #expect(fixture.session.base.reserveCount == 1)
            // One more than the queue holds: 429, the queue's own reason.
            let (fullData, fullReply) = try await client.data(for: try fixture.request(stream: true, maxTokens: 50))
            #expect((fullReply as? HTTPURLResponse)?.statusCode == 429)
            #expect(String(decoding: fullData, as: UTF8.self).contains("\"error\""))
            // The running request meets its own first-token budget; the queued
            // ones then wait longer than that budget (800 ms): time spent in the
            // queue is not the pair's first-token budget.
            #expect(firstLease.send(.token(4)))
            try await Task.sleep(for: .milliseconds(1_000))
            #expect(!firstLease.send(.token(5)))
            firstLease.acknowledge()
            #expect((try await first.value.1 as? HTTPURLResponse)?.statusCode == 200)
            for (index, task) in queued.enumerated() {
                let lease = try await fixture.startedLease(index + 2)
                #expect(fixture.session.base.reservedRequests.last?.maxTokens == 3 + index)
                for token in 0..<(3 + index - 1) { #expect(lease.send(.token(10 + token))) }
                #expect(!lease.send(.token(9)))
                lease.acknowledge()
                let (data, reply) = try await task.value
                #expect((reply as? HTTPURLResponse)?.statusCode == 200, "queued request \(index)")
                #expect(!String(decoding: data, as: UTF8.self).contains("\"error\""))
            }
            #expect(await fixture.host.waiting.isEmpty)
        }
    }

    /// A client whose connection closes while it is queued leaves the queue.
    /// (A write half-close is valid HTTP and is not a departure: such a client
    /// is noticed by the writer's probe once its turn comes.)
    @Test func aQueuedClientThatLeavesFreesItsPlace() async throws {
        try await withCompletionFixture { fixture in
            let first = Task { try await URLSession.shared.data(for: try fixture.request(stream: true)) }
            let lease = try await fixture.startedLease(1)
            for stream in [false, true] {
                let body = try #require(try fixture.request(stream: stream).httpBody)
                var bytes = Data(("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer fixture-token\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
                bytes.append(body)
                let leaving = try await HTTPRawSocket.open(port: fixture.port, request: bytes)
                #expect(try await localHostEventually { await fixture.host.waiting.count == 1 })
                leaving.reset() // the client aborts: the connection is gone
                #expect(try await localHostEventually { await fixture.host.waiting.isEmpty }, "stream \(stream)")
            }
            fixture.completeTwoTokens(lease)
            _ = try await first.value
            #expect(fixture.session.base.reserveCount == 1)
        }
    }
}
