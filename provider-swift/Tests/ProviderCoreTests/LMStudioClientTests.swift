import Foundation
import Testing
@testable import ProviderCore

private final class LMStudioURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = request.url?.path == "/v1/chat/completions"
            ? Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
            : Self.responseData
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": request.url?.path == "/v1/chat/completions"
                ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LM Studio client", .serialized)
struct LMStudioClientTests {
    @Test func discoveryOnlyAdvertisesLoadedTextModels() async throws {
        LMStudioURLProtocol.lock.withLock {
            LMStudioURLProtocol.responseData = Data(#"""
            {
              "models": [
                {
                  "type": "llm",
                  "key": "laguna-s-2.1-nvfp4-mlx",
                  "size_bytes": 71905944629,
                  "quantization": {"name": "4bit"},
                  "capabilities": {"vision": false},
                  "loaded_instances": [{"id": "laguna-instance", "config": {"context_length": 131072, "parallel": 2}}]
                },
                {
                  "type": "llm",
                  "key": "downloaded-but-not-loaded",
                  "size_bytes": 10,
                  "loaded_instances": []
                },
                {
                  "type": "embedding",
                  "key": "embedding-model",
                  "size_bytes": 10,
                  "loaded_instances": [{"id": "embedding-instance"}]
                }
              ]
            }
            """#.utf8)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LMStudioURLProtocol.self]
        let client = LMStudioClient(
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            session: URLSession(configuration: config)
        )

        let models = try await client.loadedModels()
        let model = try #require(models.first)
        #expect(models.count == 1)
        #expect(model.darkbloomID == "lmstudio/laguna-s-2.1-nvfp4-mlx")
        #expect(model.instanceID == "laguna-instance")
        #expect(model.contextLength == 131_072)
        #expect(model.maxConcurrency == 2)
        #expect(model.modelInfo.sizeBytes == 71_905_944_629)
    }

    @Test func requestRewritePreservesBodyAndForcesStreamingUsage() throws {
        let body = Data(#"{"model":"lmstudio/laguna","messages":[{"role":"user","content":"hello"}],"temperature":0.2,"stream":false}"#.utf8)
        let rewritten = try LMStudioClient.streamingRequestBody(body, instanceID: "loaded-instance")
        let object = try #require(
            try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )

        #expect(object["model"] as? String == "loaded-instance")
        #expect(object["stream"] as? Bool == true)
        #expect(object["temperature"] as? Double == 0.2)
        let options = try #require(object["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }

    @Test func streamingPreservesSSEEventBoundaries() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LMStudioURLProtocol.self]
        let client = LMStudioClient(
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            session: URLSession(configuration: config)
        )
        let body = Data(#"{"model":"lmstudio/laguna","messages":[]}"#.utf8)
        var events: [String] = []

        try await client.streamChatCompletion(body: body, instanceID: "loaded-instance") {
            events.append($0)
        }

        try #require(events.count == 2)
        #expect(events[0].hasPrefix("data: {\"choices\""))
        #expect(events[1] == "data: [DONE]\n\n")
    }
}
