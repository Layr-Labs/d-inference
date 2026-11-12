import Foundation
import MLXLMCommon
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Real loopback HTTP/tokenizer/engine with fabricated request ownership. No
/// model, child, coordinator approval, hardware or encrypted-path qualification.
@Suite(.timeLimit(.minutes(1))) struct ProtectedLocalHTTPTests: Sendable {
    @Test func exactRequestUsesEmptyStopsAndNormalQuotaDrain() async throws {
        let (backend, session, host) = try makeHost()
        do {
            try await host.start()
            let port = try #require(await host.status.boundPort)
            let request = try makeRequest(port, model: session.model.publicModelID)
            let client = Task { try await send(request) }
            let began = try await localHostEventually { backend.actualOwner.base.reserveCount == 1 }
            #expect(began)
            let observed = try #require(backend.actualOwner.observedRequest)
            #expect(observed.promptTokens.count == 32 && observed.maxTokens == 2)
            #expect(observed.stopTokens.isEmpty && observed.stopStrings.isEmpty)
            let lease = backend.actualOwner.base.last
            let started = try await localHostEventually { lease.startCount == 1 }
            #expect(started)
            lease.send(.token(4)); lease.send(.token(5)); lease.acknowledge()
            let (data, response) = try await client.value
            #expect(response.statusCode == 200)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"finish_reason\":\"length\"") && text.contains("[DONE]"))
            let released = try await localHostEventually { lease.releaseCount == 1 }
            #expect(released); backend.exhaust()
            let draining = try await localHostEventually { backend.drainCount == 1 }
            #expect(draining && backend.cancelCount == 0)
            #expect(!session.httpCanRotate)
            backend.publish()
            let done = await host.waitUntilStopped()
            #expect(done.cleanupComplete && backend.cancelCount == 0)
        } catch {
            if backend.actualOwner.base.reserveCount > 0 { backend.actualOwner.base.last.acknowledge() }
            backend.publish(); _ = await host.stop(until: localHostDeadline())
            throw error
        }
    }
    @Test func unsupportedShapeAndStopsNeverReachOriginalReservation() async throws {
        let (backend, session, host) = try makeHost()
        do {
            try await host.start()
            let port = try #require(await host.status.boundPort)
            let cases: [[String: Any]] = [["max_tokens": 3], ["max_tokens": 1], ["stop": ["end"]]]
            for fields in cases {
                let request = try makeRequest(port, model: session.model.publicModelID, fields: fields)
                let (data, response) = try await send(request)
                #expect(response.statusCode >= 400 || String(decoding: data, as: UTF8.self).contains("error"))
                #expect(backend.actualOwner.base.reserveCount == 0)
            }
            backend.publish(); _ = await host.stop(until: localHostDeadline())
        } catch {
            backend.publish(); _ = await host.stop(until: localHostDeadline())
            throw error
        }
    }

    private func makeHost() throws -> (ProtectedMemberTestBackend, DistributedProtectedMemberSession, DistributedLocalServer) {
        let backend = ProtectedMemberTestBackend(); backend.actualOwner.enforceProtectedShape = true
        let native = ClusterWorkerProfile(id: "fabricated-greedy", vocabularySize: 100,
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
        let profile = try ProtectedLocalWorkload.profile(native, requestTimeoutSeconds: 4)
        let session = try DistributedProtectedMemberSession(model: .init(publicModelID: "public/example",
            directory: URL(fileURLWithPath: "/fabricated"), modelType: "qwen3_5", eosTokenIDs: [99], vocabularySize: 100),
            identity: backend.actualOwner.base.identity, profile: profile, backend: backend,
            retainMemberLoop: UUID(), validateInputs: {})
        let host = DistributedLocalServer(session: session, config: .init(host: "127.0.0.1", port: 0, authToken: "fixture-token"),
            tokenizerLoader: { _ in TokenizerHandle(ProtectedHTTPTokenizer()) })
        return (backend, session, host)
    }
    private func makeRequest(_ port: UInt16, model: String, fields: [String: Any] = [:]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "fixture"]],
            "temperature": 0, "stream": true]
        fields.forEach { body[$0] = $1 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }
}

private struct ProtectedHTTPTokenizer: MLXLMCommon.Tokenizer {
    private let base = DistributedTestTokenizer()
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: 32) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { "</s>" }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: 32) }
}
