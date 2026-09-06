import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

@Suite("Chat readiness, advertised model selection and cancellation")
@MainActor
struct ChatReadinessTests {
    private nonisolated static let info = LocalEndpointInfo(
        host: "127.0.0.1", port: 8000, apiKey: "test-only-key", version: "0.8.5",
        pid: 4001, processIdentity: ProcessIdentity(pid: 4001, startTimeMicros: 100_000),
        updatedAt: "2026-09-05T12:00:00Z"
    )

    private func store(
        client: LocalEndpointClient,
        preferred: String? = nil
    ) -> ChatStore {
        ChatStore(live: LiveChatConfiguration(
            discoveryReader: { Self.info },
            modelProvider: { preferred },
            processIdentityReader: { _ in Self.info.processIdentity },
            clientFactory: { _ in client }
        ))
    }

    private nonisolated static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    @Test("The readiness probe sends no chat and the selected advertised model is sent verbatim")
    func advertisedSelection() async throws {
        let recorder = ChatRequestLog()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: Self.info.apiKey,
            dataTransport: { request in
                await recorder.record(request)
                return (Data(#"{"data":[{"id":"catalog/a"},{"id":"catalog/b"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { request in
                await recorder.record(request)
                return (AsyncThrowingStream { $0.yield("data: [DONE]"); $0.finish() }, Self.response(request))
            }
        )
        let store = store(client: client, preferred: "not-in-this-catalog")
        store.draft = "Preserve my draft"
        await store.refreshConnection()
        #expect(store.connection == .available)
        #expect(store.availableModelIDs == ["catalog/a", "catalog/b"])
        #expect(store.selectedModelID == "catalog/a")
        #expect(store.activeModelID == nil) // advertised does not mean it has run
        #expect(store.messages.isEmpty)
        #expect(store.draft == "Preserve my draft")
        #expect(await recorder.requests.count == 1)
        store.selectedModelID = "catalog/b"
        let prompt = try #require(store.beginResponse(to: "test choice"))
        await store.respondLive(to: prompt)
        let requests = await recorder.requests
        #expect(requests.map { $0.url?.path } == ["/v1/models", "/v1/models", "/v1/chat/completions"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key" })
        let body = try #require(requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "catalog/b")
        #expect(store.activeModelID == "catalog/b")
    }

    @Test("An already-cancelled readiness task cannot probe or overwrite a ready connection")
    func cancelledProbeCannotReplaceReadyConnection() async {
        let recorder = ChatRequestLog()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                await recorder.record(request)
                return (Data(#"{"data":[{"id":"catalog/a"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { _ in throw LocalEndpointError.unreachable("unexpected chat") }
        )
        let store = store(client: client)
        await store.refreshConnection()
        let cancelled = Task { await store.refreshConnection() }
        cancelled.cancel() // No main-actor yield before cancellation.
        await cancelled.value
        #expect(store.connection == .available)
        #expect(await recorder.requests.count == 1)
    }

    @Test("Send and retry revalidate trust even when the UI cached a ready connection")
    func cachedReadinessDoesNotAuthorizeSendOrRetry() async throws {
        let recorder = ChatRequestLog()
        let identity = ChatMutableIdentity(Self.info.processIdentity)
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: Self.info.apiKey,
            dataTransport: { request in
                await recorder.record(request)
                return (Data(#"{"data":[{"id":"catalog/a"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { request in
                await recorder.record(request)
                Issue.record("A stale endpoint must never receive the prompt")
                throw LocalEndpointError.unreachable("unexpected chat")
            }
        )
        let store = ChatStore(live: LiveChatConfiguration(
            discoveryReader: { Self.info }, modelProvider: { nil },
            processIdentityReader: { _ in identity.read() }, clientFactory: { _ in client }
        ))
        await store.refreshConnection()
        #expect(store.canSend)
        identity.set(ProcessIdentity(pid: Self.info.pid, startTimeMicros: 200_000))
        // canSend is presentation state, deliberately not a security decision.
        #expect(store.canSend)
        let prompt = try #require(store.beginResponse(to: "private prompt"))
        let userID = try #require(store.messages.first?.id)
        await store.respondLive(to: prompt)
        #expect(store.failure == .untrustedDiscovery)
        #expect(!store.canSend)
        let retry = try #require(store.retryLastFailedResponse())
        await store.respondLive(to: retry)
        #expect(store.failure == .untrustedDiscovery)
        #expect(store.messages.map(\.id) == [userID])
        #expect(await recorder.requests.count == 1) // Only the earlier trusted catalog GET.
    }

    @Test("Send and retry capture the selected model before asynchronous response work begins")
    func attemptsCaptureSelectedModel() async throws {
        let recorder = ChatRequestLog()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                (Data(#"{"data":[{"id":"catalog/a"},{"id":"catalog/b"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { request in
                await recorder.record(request)
                if await recorder.requests.count == 1 {
                    throw LocalEndpointError.httpError(statusCode: 503, detail: nil)
                }
                return (AsyncThrowingStream { $0.yield("data: [DONE]"); $0.finish() }, Self.response(request))
            }
        )
        let store = store(client: client)
        await store.refreshConnection()
        let prompt = try #require(store.beginResponse(to: "same user turn")) // Captures A.
        let userID = try #require(store.messages.first?.id)
        store.selectedModelID = "catalog/b"
        await store.respondLive(to: prompt)
        #expect(store.activeModelID == "catalog/a")
        let retry = try #require(store.retryLastFailedResponse()) // Captures B.
        store.selectedModelID = "catalog/a"
        await store.respondLive(to: retry)
        let requests = await recorder.requests
        let payloads = try requests.map { request in
            let body = try #require(request.httpBody)
            let decoded = try JSONSerialization.jsonObject(with: body)
            return try #require(decoded as? [String: Any])
        }
        #expect(payloads.compactMap { $0["model"] as? String } == ["catalog/a", "catalog/b"])
        for payload in payloads {
            let messages = try #require(payload["messages"] as? [[String: String]])
            #expect(messages.map { $0["content"] } == ["same user turn"])
        }
        #expect(store.messages.first?.id == userID)
        #expect(store.activeModelID == "catalog/b")
        #expect(store.failure == nil)
    }

    @Test("A stopped retry cannot complete or fail a newer turn using a different model")
    func staleRetryCannotMutateNewModelTurn() async throws {
        let recorder = ChatRequestLog()
        let retryGate = ChatOperationGate()
        let newTurnGate = ChatOperationGate()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                (Data(#"{"data":[{"id":"catalog/a"},{"id":"catalog/b"},{"id":"catalog/c"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { request in
                await recorder.record(request)
                let number = await recorder.requests.count
                if number == 1 { throw LocalEndpointError.httpError(statusCode: 503, detail: nil) }
                if number == 2 {
                    await retryGate.suspend()
                    throw LocalEndpointError.httpError(statusCode: 401, detail: nil)
                }
                await newTurnGate.suspend()
                return (AsyncThrowingStream {
                    $0.yield(#"data: {"choices":[{"delta":{"content":"new model output"}}]}"#)
                    $0.yield("data: [DONE]")
                    $0.finish()
                }, Self.response(request))
            }
        )
        let store = store(client: client)
        store.selectedModelID = "catalog/a"
        let first = try #require(store.beginResponse(to: "first turn"))
        let firstUserID = try #require(store.messages.first?.id)
        await store.respondLive(to: first)
        store.selectedModelID = "catalog/b"
        let retry = try #require(store.retryLastFailedResponse())
        #expect(store.messages.map(\.id) == [firstUserID])
        let oldTask = Task { await store.respondLive(to: retry) }
        await retryGate.waitUntilEntered()
        store.stopResponse() // Keep old transport alive to exercise attempt fencing.
        store.selectedModelID = "catalog/c"
        let newPrompt = try #require(store.beginResponse(to: "new turn"))
        let newTask = Task { await store.respondLive(to: newPrompt) }
        await newTurnGate.waitUntilEntered()
        await retryGate.release()
        await oldTask.value
        #expect(store.isResponding)
        #expect(store.failure == nil)
        #expect(store.activeModelID == "catalog/c")
        await newTurnGate.release()
        await newTask.value
        #expect(store.messages.map(\.text) == ["first turn", "new turn", "new model output"])
        #expect(store.messages.last?.modelID == "catalog/c")
        #expect(store.failure == nil)
        #expect(!store.isResponding)
    }

    @Test("No catalog models blocks sending and preserves drafts")
    func noModels() async {
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in (Data(#"{"data":[]}"#.utf8), Self.response(request)) },
            lineTransport: { _ in throw LocalEndpointError.unreachable("unexpected chat") }
        )
        let store = store(client: client)
        store.draft = "Keep this"
        await store.refreshConnection()
        #expect(store.connection == .unavailable(.noModels))
        #expect(!store.canSend)
        #expect(store.failure == nil) // no failed user turn to retry
        #expect(store.draft == "Keep this")
    }

    @Test("Readiness rejects a stale process before creating an authenticated client")
    func staleProbeIsRejected() async {
        let store = ChatStore(live: LiveChatConfiguration(
            discoveryReader: { Self.info }, modelProvider: { nil },
            processIdentityReader: { _ in ProcessIdentity(pid: 4001, startTimeMicros: 200_000) },
            clientFactory: { _ in
                Issue.record("A stale discovery record must not construct a client")
                return LocalEndpointClient(info: Self.info)
            }
        ))
        await store.refreshConnection()
        #expect(store.connection == .unavailable(.untrustedDiscovery))
        #expect(!store.canSend)
    }

    @Test("Stop during model lookup prevents the old plaintext POST and cannot finish a newer turn", arguments: [false, true])
    func stopDuringLookup(explicitSelection: Bool) async throws {
        let gate = ChatOperationGate()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                await gate.suspend()
                return (Data(#"{"data":[{"id":"catalog/a"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { _ in
                Issue.record("Stopped lookup must not send plaintext")
                throw LocalEndpointError.unreachable("unexpected chat")
            }
        )
        let store = store(client: client)
        if explicitSelection { store.selectedModelID = "catalog/a" }
        let prompt = try #require(store.beginResponse(to: "old"))
        let oldTask = Task { await store.respondLive(to: prompt) }
        await gate.waitUntilEntered()
        store.stopResponse() // Deliberately do not cancel: test a transport that ignores cancellation.
        store.reset()
        _ = try #require(store.beginResponse(to: "new"))
        await gate.release()
        await oldTask.value
        #expect(store.messages.map(\.text) == ["new"])
        #expect(store.isResponding)
        #expect(store.failure == nil)
        #expect(store.history.first?.messages.map(\.text) == ["old"])
        store.stopResponse()
    }

    @Test("A task cancelled before it starts cannot claim or clear the next attempt")
    func cancelledTaskCannotClaimNewAttempt() async throws {
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { _ in
                Issue.record("A cancelled task must not probe")
                throw LocalEndpointError.unreachable("unexpected probe")
            },
            lineTransport: { _ in
                Issue.record("A cancelled task must not send")
                throw LocalEndpointError.unreachable("unexpected chat")
            }
        )
        let store = store(client: client, preferred: "catalog/a")
        _ = try #require(store.beginResponse(to: "old"))
        let task = Task { await store.respondLive(to: "old") }
        task.cancel() // Main actor has not yielded; this task has not started.
        store.stopResponse()
        _ = try #require(store.beginResponse(to: "new"))
        await task.value
        #expect(store.isResponding)
        #expect(store.failure == nil)
        #expect(store.messages.map(\.text) == ["old", "new"])
        store.stopResponse()
    }

    @Test("A late streaming transport error cannot fail a newer attempt")
    func lateStreamError() async throws {
        let gate = ChatOperationGate()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                (Data(#"{"data":[{"id":"catalog/a"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { _ in
                await gate.suspend()
                throw LocalEndpointError.httpError(statusCode: 503, detail: nil)
            }
        )
        let store = store(client: client, preferred: "catalog/a")
        let prompt = try #require(store.beginResponse(to: "old"))
        let oldTask = Task { await store.respondLive(to: prompt) }
        await gate.waitUntilEntered()
        store.stopResponse()
        _ = try #require(store.beginResponse(to: "new"))
        await gate.release()
        await oldTask.value
        #expect(store.isResponding)
        #expect(store.failure == nil)
        #expect(store.messages.map(\.text) == ["old", "new"])
        store.stopResponse()
    }

    @Test("A late connection probe cannot replace an in-flight turn's state")
    func lateProbe() async throws {
        let gate = ChatOperationGate()
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                await gate.suspend()
                return (Data(#"{"data":[]}"#.utf8), Self.response(request))
            },
            lineTransport: { _ in throw LocalEndpointError.unreachable("unexpected chat") }
        )
        let store = store(client: client)
        let probe = Task { await store.refreshConnection() }
        await gate.waitUntilEntered()
        #expect(store.connection == .checking)
        _ = try #require(store.beginResponse(to: "a newer operation"))
        await gate.release()
        await probe.value
        #expect(store.isResponding)
        #expect(store.connection == .unchecked)
        #expect(store.failure == nil)
        store.stopResponse()
    }

    @Test("A readiness check and history restore preserve the failed turn's retry identity")
    func readinessPreservesRetry() async throws {
        let client = LocalEndpointClient(
            baseURL: URL(string: Self.info.baseURL)!, apiKey: nil,
            dataTransport: { request in
                (Data(#"{"data":[{"id":"catalog/a"}]}"#.utf8), Self.response(request))
            },
            lineTransport: { _ in throw LocalEndpointError.httpError(statusCode: 503, detail: nil) }
        )
        let store = store(client: client, preferred: "catalog/a")
        let conversationID = store.conversationID
        let prompt = try #require(store.beginResponse(to: "Retry me"))
        await store.respondLive(to: prompt)
        let userID = try #require(store.messages.first?.id)
        await store.refreshConnection()
        #expect(store.canRetry)
        store.reset()
        store.restoreConversation(conversationID)
        #expect(store.canRetry)
        #expect(store.retryLastFailedResponse() == "Retry me")
        #expect(store.messages.map(\.id) == [userID])
        store.stopResponse()
    }
}

private actor ChatRequestLog {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

/// Deterministic async barrier: no wall-clock polling or network dependencies.
private actor ChatOperationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var operation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        if released { return }
        await withCheckedContinuation { operation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        operation?.resume()
        operation = nil
    }
}

private final class ChatMutableIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ProcessIdentity?

    init(_ identity: ProcessIdentity?) { self.identity = identity }
    func read() -> ProcessIdentity? { lock.withLock { identity } }
    func set(_ value: ProcessIdentity?) { lock.withLock { identity = value } }
}
