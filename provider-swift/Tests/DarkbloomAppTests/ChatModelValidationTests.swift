import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Chat validates the current endpoint on every attempt")
@MainActor
struct ChatModelValidationTests {
    private nonisolated static let info = LocalEndpointInfo(
        host: "127.0.0.1", port: 8000, apiKey: "test-only-key", version: "0.8.5",
        pid: 4001, processIdentity: ProcessIdentity(pid: 4001, startTimeMicros: 100_000),
        updatedAt: "2026-09-05T12:00:00Z"
    )

    private func store(_ endpoint: ChatCatalogScenario) -> ChatStore {
        ChatStore(live: LiveChatConfiguration(
            discoveryReader: { Self.info }, modelProvider: { nil },
            processIdentityReader: { _ in Self.info.processIdentity },
            clientFactory: { info in chatValidationClient(info, endpoint: endpoint) }
        ))
    }

    @Test("Every send and retry reads the catalog; a missing selection never POSTs or retargets")
    func retryValidatesCurrentCatalog() async throws {
        let endpoint = ChatCatalogScenario(models: ["catalog/a"], replies: [.httpError(503)])
        let store = store(endpoint)
        await store.refreshConnection()
        let prompt = try #require(store.beginResponse(to: "Only one user turn"))
        let userID = try #require(store.messages.first?.id)
        await store.respondLive(to: prompt)
        #expect(store.canRetry)

        await endpoint.setModels(["catalog/b"])
        let missingRetry = try #require(store.retryLastFailedResponse())
        await store.respondLive(to: missingRetry)
        #expect(store.failure == .selectedModelUnavailable)
        #expect(store.selectedModelID == "catalog/a")
        #expect(store.messages.map(\.id) == [userID])
        #expect(await endpoint.requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])

        store.selectedModelID = "catalog/b" // Only an explicit selection retargets the retry.
        let changedRetry = try #require(store.retryLastFailedResponse())
        await store.respondLive(to: changedRetry)
        #expect(store.failure == nil)
        #expect(store.activeModelID == "catalog/b")
        let requests = await endpoint.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET", "GET", "POST"])
        #expect(requests.filter { $0.httpMethod == "GET" }.allSatisfy { $0.url?.path == "/v1/models" })
        let bodies = try requests.filter { $0.httpMethod == "POST" }.map { request in
            let data = try #require(request.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(bodies.compactMap { $0["model"] as? String } == ["catalog/a", "catalog/b"])
        for body in bodies {
            #expect(body["messages"] as? [[String: String]] == [["role": "user", "content": prompt]])
        }
    }

    @Test("A now-empty catalog blocks POST even after readiness with a selected model")
    func emptyCatalogOverridesCachedReadiness() async throws {
        let endpoint = ChatCatalogScenario(models: ["catalog/a"])
        let store = store(endpoint)
        await store.refreshConnection()
        await endpoint.setModels([])
        let prompt = try #require(store.beginResponse(to: "Do not send"))
        await store.respondLive(to: prompt)
        #expect(store.failure == .noModels)
        #expect(store.canRetry)
        #expect(await endpoint.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("Refresh and history restore preserve a missing explicit model and the draft")
    func historyDoesNotRetargetSelection() async throws {
        let endpoint = ChatCatalogScenario(models: ["catalog/a"])
        let store = store(endpoint)
        await store.refreshConnection()
        let savedID = store.conversationID
        store.draft = "Unsent work"
        store.reset()
        await endpoint.setModels(["catalog/b"])
        await store.refreshConnection()
        #expect(store.availableModelIDs == ["catalog/b"])
        #expect(store.selectedModelID == "catalog/a")
        #expect(!store.canSend)
        #expect(store.modelSelectionFailure == .selectedModelUnavailable)
        store.selectedModelID = "catalog/b"
        #expect(store.canSend)

        store.restoreConversation(savedID)
        #expect(store.draft == "Unsent work")
        #expect(store.selectedModelID == "catalog/a")
        #expect(!store.canSend)
        let prompt = try #require(store.beginResponse(to: store.draft))
        await store.respondLive(to: prompt)
        #expect(store.failure == .selectedModelUnavailable)
        #expect(await endpoint.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("A newly discovered process must advertise the selected model before receiving plaintext")
    func discoveryReplacementDoesNotReuseOldCatalog() async throws {
        let replacement = LocalEndpointInfo(
            host: "127.0.0.1", port: 8001, apiKey: "replacement-key", version: "0.8.5",
            pid: 4002, processIdentity: ProcessIdentity(pid: 4002, startTimeMicros: 200_000),
            updatedAt: "2026-09-05T12:01:00Z"
        )
        let discovery = ChatValidationDiscovery(Self.info)
        let first = ChatCatalogScenario(models: ["catalog/a"])
        let second = ChatCatalogScenario(models: ["catalog/b"])
        let store = ChatStore(live: LiveChatConfiguration(
            discoveryReader: { discovery.read() }, modelProvider: { nil },
            processIdentityReader: { pid in
                pid == Self.info.pid ? Self.info.processIdentity : replacement.processIdentity
            },
            clientFactory: { info in
                chatValidationClient(info, endpoint: info.pid == Self.info.pid ? first : second)
            }
        ))
        await store.refreshConnection()
        discovery.replace(with: replacement)
        let prompt = try #require(store.beginResponse(to: "Private message"))
        await store.respondLive(to: prompt)
        #expect(store.failure == .selectedModelUnavailable)
        #expect(store.selectedModelID == "catalog/a")
        let requests = await second.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == replacement.baseURL + "/models")
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.httpBody == nil)
    }

    @Test("Premature EOF keeps partial output and retry replaces it with a terminal reply", arguments: [false, true])
    func prematureEOFIsRetryable(hasPartial: Bool) async throws {
        let partial = #"data: {"choices":[{"delta":{"content":"partial"}}]}"#
        let endpoint = ChatCatalogScenario(models: ["catalog/a"], replies: [
            .lines(hasPartial ? [partial] : []),
            .lines([
                #"data: {"choices":[{"delta":{"content":"complete"}}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            ]),
        ])
        let store = store(endpoint)
        await store.refreshConnection()
        let prompt = try #require(store.beginResponse(to: "Keep my turn"))
        let userID = try #require(store.messages.first?.id)
        store.draft = "Next unsent question"
        await store.respondLive(to: prompt)
        #expect(store.failure == .from(.prematureEndOfStream))
        #expect(store.canRetry)
        #expect(!store.isResponding)
        #expect(store.messages.map(\.text) == (hasPartial ? [prompt, "partial"] : [prompt]))
        if hasPartial { #expect(store.messages.last?.interruption == .failed) }
        #expect(store.draft == "Next unsent question")

        let retry = try #require(store.retryLastFailedResponse())
        await store.respondLive(to: retry)
        #expect(store.failure == nil)
        #expect(store.messages.map(\.text) == [prompt, "complete"])
        #expect(store.messages.first?.id == userID)
        #expect(store.messages.last?.interruption == nil)
        #expect(store.draft == "Next unsent question")
        #expect(await endpoint.requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET", "POST"])
    }
}

private func chatValidationClient(_ info: LocalEndpointInfo, endpoint: ChatCatalogScenario) -> LocalEndpointClient {
    LocalEndpointClient(
        baseURL: URL(string: info.baseURL)!, apiKey: info.apiKey,
        dataTransport: { try await endpoint.catalog($0) },
        lineTransport: { try await endpoint.stream($0) }
    )
}

/// Serialized scripted transport: no networking, polling, or clock-based races.
private actor ChatCatalogScenario {
    enum Reply: Sendable {
        case httpError(Int)
        case lines([String])
    }

    private var models: [String]
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(models: [String], replies: [Reply] = []) {
        self.models = models
        self.replies = replies
    }

    func setModels(_ models: [String]) { self.models = models }

    func catalog(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let data = try JSONSerialization.data(withJSONObject: ["data": models.map { ["id": $0] }])
        return (data, response(request))
    }

    func stream(_ request: URLRequest) throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? .lines(["data: [DONE]"]) : replies.removeFirst()
        switch reply {
        case .httpError(let status): throw LocalEndpointError.httpError(statusCode: status, detail: nil)
        case .lines(let lines):
            return (AsyncThrowingStream {
                for line in lines { $0.yield(line) }
                $0.finish()
            }, response(request))
        }
    }

    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private final class ChatValidationDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var info: LocalEndpointInfo
    init(_ info: LocalEndpointInfo) { self.info = info }
    func read() -> LocalEndpointInfo { lock.withLock { info } }
    func replace(with info: LocalEndpointInfo) { lock.withLock { self.info = info } }
}
