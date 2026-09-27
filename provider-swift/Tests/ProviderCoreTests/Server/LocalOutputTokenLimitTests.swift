import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

@Suite("Local upload interception preserves SDK token-limit errors")
struct LocalOutputTokenLimitTests {
    @Test(arguments: [false, true])
    func negativeLimitsRemain400BeforeAcquisition(streaming: Bool) async throws {
        let spy = AcquisitionSpy()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 32,
            acquire: { id in
                await spy.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in
                throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
            },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
        try await app.test(.router) { client in
            for value in [-1, Int.min] {
                let chat = #"{"model":"fixture","messages":[{"role":"user","content":"hi"}],"stream":\#(streaming),"max_tokens":\#(value)}"#
                for (path, body) in [
                    ("/v1/chat/completions", chat), ("/chat/completions", chat),
                    ("/v1/chat/completions/batch", "[" + chat + "]"),
                    ("/v1/completions", #"{"model":"fixture","prompt":"hi","stream":\#(streaming),"max_tokens":\#(value)}"#),
                    ("/v1/responses", #"{"model":"fixture","input":"hi","stream":\#(streaming),"max_output_tokens":\#(value)}"#),
                ] {
                    try await client.execute(uri: path, method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                        body: ByteBuffer(string: body)) { response in
                        #expect(response.status == .badRequest)
                        #expect(response.headers[.accessControlAllowOrigin] == "*")
                        let text = String(buffer: response.body)
                        let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(text.utf8))
                        #expect(error.error.type == "invalid_request_error")
                        #expect(error.error.message == "Output token limits must not be negative.")
                        #expect(!text.contains("data:"))
                    }
                }
            }
            // Input validation never bypasses the existing local auth layer.
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"model":"fixture","messages":[],"max_tokens":-1}"#)) { response in
                #expect(response.status == .unauthorized)
            }
        }
        #expect(await spy.count == 0)
    }
}

private actor AcquisitionSpy {
    var count = 0
    func mark() { count += 1 }
}
