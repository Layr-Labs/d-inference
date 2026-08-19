import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Local endpoint client speaks SSE and tolerates wire variance")
struct LocalEndpointClientTests {
    // MARK: Stubs

    /// Captures the requests the client issues. `@unchecked Sendable` because
    /// the client's transport closures are `@Sendable`; tests append from the
    /// (single, sequential) client call flow and read after awaited work, so
    /// no true races exist.
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private let recorder = Recorder()

    private static func httpResponse(_ status: Int, url: URL = URL(string: "http://127.0.0.1:8000/v1")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func makeClient(
        apiKey: String?,
        status: Int = 200,
        lines: [String] = [],
        data: Data = Data(),
        dataError: (any Error)? = nil,
        lineError: (any Error)? = nil
    ) -> LocalEndpointClient {
        let recorder = self.recorder
        return LocalEndpointClient(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            apiKey: apiKey,
            dataTransport: { request in
                recorder.requests.append(request)
                if let dataError { throw dataError }
                return (data, Self.httpResponse(status))
            },
            lineTransport: { request in
                recorder.requests.append(request)
                if let lineError { throw lineError }
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                }
                return (stream, Self.httpResponse(status))
            }
        )
    }

    private func collect(_ stream: AsyncThrowingStream<LocalEndpointClient.ChatDelta, Error>) async throws -> [LocalEndpointClient.ChatDelta] {
        var deltas: [LocalEndpointClient.ChatDelta] = []
        for try await delta in stream {
            deltas.append(delta)
        }
        return deltas
    }

    // MARK: SSE parsing

    @Test("SSE deltas stream until the [DONE] sentinel")
    func streamsDeltasUntilDone() async throws {
        let client = makeClient(apiKey: "dk-test", lines: [
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])

        let deltas = try await collect(client.streamChat(model: "gpt-oss-20b", messages: []))
        #expect(deltas == [
            .init(content: "Hello"),
            .init(content: " world"),
            .init(content: "", finishReason: "stop"),
        ])
    }

    @Test("Malformed lines, comments, and role-only chunks are skipped without failing the stream")
    func malformedLinesAreTolerated() async throws {
        let client = makeClient(apiKey: nil, lines: [
            "",
            ": keep-alive comment",
            "event: message",
            "data: [object Object] not json",
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"ok"}}]}"#,
            "data: [DONE]",
        ])

        let deltas = try await collect(client.streamChat(model: "m", messages: []))
        #expect(deltas == [.init(content: "ok")])
    }

    @Test("A stream that ends without [DONE] still finishes cleanly")
    func streamWithoutDoneFinishes() async throws {
        let client = makeClient(apiKey: nil, lines: [
            #"data: {"choices":[{"delta":{"content":"tail"}}]}"#,
        ])
        let deltas = try await collect(client.streamChat(model: "m", messages: []))
        #expect(deltas == [.init(content: "tail")])
    }

    // MARK: Auth header

    @Test("Authorization header is sent when a key exists and omitted when it is empty")
    func authHeaderPresence() async throws {
        let keyed = makeClient(apiKey: "dk-secret", lines: ["data: [DONE]"])
        _ = try await collect(keyed.streamChat(model: "m", messages: []))
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer dk-secret")

        let empty = makeClient(apiKey: "", lines: ["data: [DONE]"])
        _ = try await collect(empty.streamChat(model: "m", messages: []))
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)

        let absent = makeClient(apiKey: nil, lines: ["data: [DONE]"])
        _ = try await collect(absent.streamChat(model: "m", messages: []))
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: Request shape

    @Test("Streaming requests carry the model, messages, and the stream flag")
    func requestShapeCarriesChatFields() async throws {
        let client = makeClient(apiKey: nil, lines: ["data: [DONE]"])
        _ = try await collect(client.streamChat(
            model: "gpt-oss-20b",
            messages: [
                .init(role: "user", content: "first"),
                .init(role: "assistant", content: "second"),
            ]
        ))

        let request = try #require(recorder.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["model"] as? String == "gpt-oss-20b")
        #expect(decoded?["stream"] as? Bool == true)
        let messages = decoded?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?.first?["role"] == "user")
        #expect(messages?.last?["content"] == "second")
    }

    // MARK: Error mapping

    @Test("Non-2xx stream responses surface as typed HTTP errors")
    func httpErrorMapping() async {
        let client = makeClient(apiKey: nil, status: 500, lines: ["data: [DONE]"])
        await #expect(throws: LocalEndpointError.self) {
            _ = try await collect(client.streamChat(model: "m", messages: []))
        }
    }

    @Test("Transport failures surface as unreachable")
    func transportFailureMapping() async {
        let client = makeClient(
            apiKey: nil,
            lineError: URLError(.cannotConnectToHost)
        )
        do {
            _ = try await collect(client.streamChat(model: "m", messages: []))
            Issue.record("Expected streamChat to throw")
        } catch let error as LocalEndpointError {
            guard case .unreachable = error else {
                Issue.record("Expected .unreachable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Model catalog

    @Test("listModels decodes the OpenAI catalog shape")
    func listModelsDecodesIDs() async throws {
        let client = makeClient(
            apiKey: "dk-secret",
            data: #"{"object":"list","data":[{"id":"gpt-oss-20b","object":"model"},{"id":"gemma-4","object":"model"}]}"#.data(using: .utf8)!
        )
        let ids = try await client.listModels()
        #expect(ids == ["gpt-oss-20b", "gemma-4"])
        #expect(recorder.requests.last?.httpMethod == "GET")
        #expect(recorder.requests.last?.url?.path == "/v1/models")
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer dk-secret")
    }

    @Test("listModels tolerates unexpected 2xx shapes as an empty catalog")
    func listModelsToleratesShapeVariance() async throws {
        let client = makeClient(apiKey: nil, data: "<html>not the catalog</html>".data(using: .utf8)!)
        #expect(try await client.listModels() == [])

        let partial = makeClient(apiKey: nil, data: #"{"data":[{"no_id":1},{"id":"kept"}]}"#.data(using: .utf8)!)
        #expect(try await partial.listModels() == ["kept"])
    }

    @Test("listModels surfaces non-2xx statuses for the caller to classify")
    func listModelsSurfacesHTTPStatus() async {
        let client = makeClient(apiKey: nil, status: 404)
        do {
            _ = try await client.listModels()
            Issue.record("Expected listModels to throw")
        } catch let error as LocalEndpointError {
            guard case .httpError(let status, _) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(status == 404)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
