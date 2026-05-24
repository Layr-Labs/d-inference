import Hummingbird
import HummingbirdTesting
import Testing
@testable import ProviderCore

@Test func standaloneServerHealthEndpointUsesHummingbirdRouter() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/json")
            #expect(response.headers[.accessControlAllowOrigin] == "*")
            #expect(String(buffer: response.body).contains(#""status":"ok""#))
            #expect(String(buffer: response.body).contains(#""version":"#))
        }
    }
}

@Test func standaloneServerModelsEndpointReturnsOpenAIListShape() async throws {
    let model = ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
    let app = standaloneTestServer(models: [model]).makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/v1/models", method: .get) { response in
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(body.contains(#""object":"list""#))
            #expect(body.contains(#""id":"mlx-community\/Qwen2.5-7B-4bit""#))
            #expect(body.contains(#""owned_by":"local""#))
        }
    }
}

@Test func standaloneServerRejectsUnsupportedChatContentType() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "text/plain"],
            body: ByteBuffer(string: "not json")
        ) { response in
            #expect(response.status == .unsupportedMediaType)
            #expect(String(buffer: response.body).contains("Content-Type must be application"))
        }
    }
}

@Test func standaloneServerRejectsMalformedChatJSON() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":"mlx-test","messages":"bad"}"#)
        ) { response in
            #expect(response.status == .badRequest)
            #expect(String(buffer: response.body).contains("Invalid request body"))
        }
    }
}

@Test func standaloneServerReportsModelNotAvailableForNonStreamingChat() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":"mlx-test","messages":[{"role":"user","content":"hello"}],"stream":false}"#)
        ) { response in
            #expect(response.status == .notFound)
            #expect(String(buffer: response.body).contains("not found locally"))
        }
    }
}

@Test func standaloneServerClassifiesSchedulerAdmissionErrors() {
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request exceeds active token budget") == .serviceUnavailable)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request queue full") == .tooManyRequests)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: invalid token count") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: duplicate request ID") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request exceeds batch token budget") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "unexpected backend failure") == .internalServerError)
}

@Test func standaloneServerFormatsTerminalStreamingErrorEvent() {
    let event = StandaloneServer.sseErrorEvent(message: "token_budget_exhausted: request queue full")

    #expect(event.contains("event: error"))
    #expect(event.contains("token_budget_exhausted"))
    #expect(!event.contains("[DONE]"))
    #expect(!event.contains("finish_reason"))
}

private func standaloneTestServer(models: [ModelInfo] = []) -> StandaloneServer {
    StandaloneServer(
        models: models
    )
}
