import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Real local HTTP stack with a fabricated owner; no model/child/peer execution.
@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPTerminalIntegrationTests {
    @Test func roleOnlyDeadlineErrorSurvivesSessionInvalidationUntilActualRequestACK() async throws {
        let session = LocalHostTestSession()
        let host = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: "fixture-token"),
            firstTokenBudgetPolicy: .init(baseMilliseconds: 500, millisecondsPerInputToken: 100),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
        try await host.start()
        let port = try #require(await host.status.boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": session.model.publicModelID,
            "messages": [["role": "user", "content": "fixture"]], "temperature": 0,
            "max_tokens": 5, "stream": true])
        let completed = HTTPDeliveryCapture()
        let client = Task {
            defer { completed.finish() }
            return try await URLSession.shared.data(for: request)
        }
        #expect(try await httpDeliveryEventually { session.base.reserveCount == 1 })
        let lease = session.base.last
        #expect(try await httpDeliveryEventually { lease.cancelCount == 1 })
        #expect(lease.releaseCount == 0 && completed.finishCount == 0)
        session.invalidatePairBeforeStatusCallback()
        #expect(try await localHostEventually { await host.status.phase == .stopping })
        #expect(host.responses.hasActiveResponse && lease.releaseCount == 0)
        // The response remains pending, but native request ownership is still
        // held. Only the explicit fake ACK below permits the real engine to end.
        lease.acknowledge()
        let (data, reply) = try await client.value
        let http = try #require(reply as? HTTPURLResponse)
        let text = String(decoding: data, as: UTF8.self)
        #expect(http.statusCode == 200 && text.contains("\"role\":\"assistant\""))
        #expect(text.contains("\"error\"") && text.contains("attempt_usage"))
        #expect(text.contains("prefill_stall") || text.contains("deadline_unreachable"))
        #expect(text.hasSuffix("data: [DONE]\n\n") && lease.releaseCount == 1)
        #expect(try await localHostEventually { await host.status.cleanupComplete })
    }
}
