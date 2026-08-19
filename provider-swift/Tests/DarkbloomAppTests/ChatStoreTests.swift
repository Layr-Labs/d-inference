import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

@Suite("Live chat store streams the local endpoint into the transcript")
@MainActor
struct ChatStoreTests {
    // MARK: Stubs

    private nonisolated func testInfo(apiKey: String = "dk-test") -> LocalEndpointInfo {
        LocalEndpointInfo(
            host: "127.0.0.1",
            port: 8000,
            apiKey: apiKey,
            version: "0.8.5",
            pid: 4001,
            updatedAt: "2026-06-17T19:30:00Z"
        )
    }

    private func makeClient(lines: [String], lineDelay: Duration = .zero) -> LocalEndpointClient {
        LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { _ in
                let data = #"{"data":[{"id":"endpoint-model"}]}"#.data(using: .utf8)!
                return (data, HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/v1/models")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            lineTransport: { _ in
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    let task = Task {
                        for line in lines {
                            if lineDelay > .zero {
                                try? await Task.sleep(for: lineDelay)
                                guard !Task.isCancelled else {
                                    continuation.finish(throwing: URLError(.cancelled))
                                    return
                                }
                            }
                            continuation.yield(line)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                return (stream, HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
    }

    private func makeLiveStore(
        client: LocalEndpointClient?,
        modelProvider: @escaping @Sendable () -> String? = { "gpt-oss-20b" }
    ) -> PreviewChatStore {
        PreviewChatStore(live: LiveChatConfiguration(
            discoveryReader: { client.map { _ in self.testInfo() } },
            modelProvider: modelProvider,
            clientFactory: { _ in client! }
        ))
    }

    // MARK: Streaming

    @Test("Streamed deltas append into a single assistant message")
    func streamingAppendsTokens() async throws {
        let store = makeLiveStore(client: makeClient(lines: [
            #"data: {"choices":[{"delta":{"content":"The quick"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" brown fox"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ]))

        let prompt = try #require(store.beginResponse(to: "Say something"))
        await store.respondLive(to: prompt)

        #expect(!store.isResponding)
        #expect(store.failure == nil)
        #expect(store.messages.count == 2)
        #expect(store.messages.last?.role == .assistant)
        #expect(store.messages.last?.text == "The quick brown fox")
        #expect(store.messages.last?.isPreview == false)
        #expect(store.activeModelID == "gpt-oss-20b")
    }

    @Test("Follow-up sends include the prior conversation")
    func conversationIsKeptInMemory() async throws {
        let recorder = ChatRequestRecorder()
        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { _ in (Data(), HTTPURLResponse()) },
            lineTransport: { request in
                recorder.bodies.append(request.httpBody)
                let stream = AsyncThrowingStream<String, Error> { $0.yield("data: [DONE]"); $0.finish() }
                return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let store = makeLiveStore(client: client)

        _ = store.beginResponse(to: "first")
        await store.respondLive(to: "first")
        _ = store.beginResponse(to: "second")
        await store.respondLive(to: "second")

        #expect(recorder.bodies.count == 2)
        let lastBody = try #require(recorder.bodies.compactMap { $0 }.last)
        let decoded = try JSONSerialization.jsonObject(with: lastBody) as? [String: Any]
        let wireMessages = decoded?["messages"] as? [[String: String]]
        // The first send's empty assistant placeholder was dropped, so the
        // wire carries exactly the two user turns.
        #expect(wireMessages?.count == 2)
        #expect(wireMessages?.first?["role"] == "user")
        #expect(wireMessages?.first?["content"] == "first")
        #expect(wireMessages?.last?["content"] == "second")
    }

    // MARK: Failure states

    @Test("A missing discovery record fails with an actionable offline state")
    func missingDiscoveryFailsActionably() async throws {
        let store = makeLiveStore(client: nil)
        let prompt = try #require(store.beginResponse(to: "Hello?"))
        await store.respondLive(to: prompt)

        #expect(!store.isResponding)
        #expect(store.failure == .noDiscovery)
        #expect(store.failure?.detail.contains("Overview") == true)
        #expect(store.messages.count == 1)  // only the user message
    }

    @Test("Transport failure keeps the partial reply and surfaces the error")
    func midStreamFailureKeepsPartial() async throws {
        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { _ in (Data(), HTTPURLResponse()) },
            lineTransport: { _ in
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    continuation.yield(#"data: {"choices":[{"delta":{"content":"half"}}]}"#)
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                }
                return (stream, HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/v1")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let store = makeLiveStore(client: client)
        let prompt = try #require(store.beginResponse(to: "Stream please"))
        await store.respondLive(to: prompt)

        #expect(store.messages.last?.text == "half")
        #expect(store.failure?.title == "The local endpoint did not respond")
        #expect(store.failure?.detail.contains("Start the provider from the Overview") == true)
        #expect(!store.isResponding)
    }

    @Test("An HTTP status failure drops the empty assistant placeholder")
    func httpErrorDropsEmptyPlaceholder() async throws {
        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { _ in (Data(), HTTPURLResponse()) },
            lineTransport: { _ in
                (AsyncThrowingStream { $0.finish() }, HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/v1")!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
        )
        let store = makeLiveStore(client: client)
        let prompt = try #require(store.beginResponse(to: "hi"))
        await store.respondLive(to: prompt)

        #expect(store.messages.count == 1)
        #expect(store.failure == .from(.httpError(statusCode: 503, detail: nil)))
        #expect(!store.isResponding)
    }

    // MARK: Model selection

    @Test("Without a provider model the store falls back to the endpoint's first model")
    func modelFallbackUsesEndpointCatalog() async throws {
        let recorder = ChatRequestRecorder()
        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { request in
                recorder.requests.append(request)
                let data = #"{"data":[{"id":"fallback-model"}]}"#.data(using: .utf8)!
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            lineTransport: { request in
                recorder.requests.append(request)
                let stream = AsyncThrowingStream<String, Error> {
                    $0.yield(#"data: {"choices":[{"delta":{"content":"ok"}}]}"#)
                    $0.yield("data: [DONE]")
                    $0.finish()
                }
                return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let store = makeLiveStore(client: client, modelProvider: { nil })
        let prompt = try #require(store.beginResponse(to: "pick a model"))
        await store.respondLive(to: prompt)

        #expect(store.activeModelID == "fallback-model")
        #expect(store.failure == nil)
        #expect(store.messages.last?.text == "ok")
        let streamRequest = recorder.requests.last { $0.httpMethod == "POST" }
        #expect(streamRequest != nil)
    }

    @Test("No provider model and an empty endpoint catalog fails cleanly")
    func emptyCatalogFailsCleanly() async throws {
        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { request in
                (#"{"data":[]}"#.data(using: .utf8)!, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            lineTransport: { _ in (AsyncThrowingStream { $0.finish() }, HTTPURLResponse()) }
        )
        let store = makeLiveStore(client: client, modelProvider: { nil })
        let prompt = try #require(store.beginResponse(to: "hi"))
        await store.respondLive(to: prompt)

        #expect(store.failure == .noModels)
        #expect(!store.isResponding)
        #expect(store.messages.count == 1)
    }

    // MARK: Stop + reset

    @Test("Stopping mid-stream keeps the partial reply without a failure")
    func stopKeepsPartialWithoutFailure() async throws {
        // Gate the second delta behind the test's stop: under parallel-suite
        // executor load, a wallclock 30 ms spacing occasionally collapses
        // behind main-actor backlog and the "post-stop" token lands BEFORE
        // the poll loop even sees the first one. The gate makes the stop
        // state itself deterministic.
        actor DeltaGate {
            private var continuation: CheckedContinuation<Void, Never>?
            private var isOpen = false

            func wait() async {
                if isOpen { return }
                await withCheckedContinuation { continuation = $0 }
            }

            func open() {
                isOpen = true
                continuation?.resume()
            }
        }
        let gate = DeltaGate()

        let client = LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: "dk-test",
            dataTransport: { request in
                (#"{"data":[]}"#.data(using: .utf8)!, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            lineTransport: { _ in
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    let task = Task {
                        continuation.yield(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
                        await gate.wait()
                        guard !Task.isCancelled else {
                            continuation.finish(throwing: URLError(.cancelled))
                            return
                        }
                        continuation.yield(#"data: {"choices":[{"delta":{"content":" rest"}}]}"#)
                        continuation.yield("data: [DONE]")
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                return (stream, HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let store = makeLiveStore(client: client, modelProvider: { "gpt-oss-20b" })
        let prompt = try #require(store.beginResponse(to: "stream"))
        let task = Task { @MainActor in await store.respondLive(to: prompt) }

        // "partial" is the only text reachable before the gate opens.
        while store.messages.last?.text != "partial" {
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        store.stopResponse()
        await gate.open()
        _ = await task.value

        #expect(!store.isResponding)
        #expect(store.failure == nil)
        #expect(store.messages.last?.text == "partial")
    }

    @Test("Stopping before the first token leaves no empty assistant bubble")
    func stopBeforeFirstTokenRemovesPlaceholder() async throws {
        let store = makeLiveStore(client: makeClient(lines: ["data: [DONE]"], lineDelay: .milliseconds(60)))
        let prompt = try #require(store.beginResponse(to: "stream"))
        let task = Task { @MainActor in await store.respondLive(to: prompt) }
        try? await Task.sleep(for: .milliseconds(10))

        task.cancel()
        store.stopResponse()
        _ = await task.value

        #expect(store.messages.count == 1)
        #expect(store.messages.last?.role == .user)
        #expect(store.failure == nil)
    }

    @Test("Reset clears the conversation, failure, and responding state")
    func resetClearsEverything() async throws {
        let store = makeLiveStore(client: nil)
        let prompt = try #require(store.beginResponse(to: "hi"))
        await store.respondLive(to: prompt)
        #expect(store.failure != nil)

        store.reset()
        #expect(store.messages.isEmpty)
        #expect(store.failure == nil)
        #expect(!store.isResponding)
        #expect(!store.hasConversation)
    }

    // MARK: Helpers

    final class ChatRequestRecorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var bodies: [Data?] = []
    }
}
