import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// The local API refuses a body nested past `JSONNestingLimit` before any
/// parser recurses through it on the request task's stack.
@Suite("Local API JSON nesting limit")
struct LocalRequestNestingTests {
    @Test func deeplyNestedBodiesAre400BeforeAcquisition() async throws {
        let acquisitions = AcquisitionCount()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 32,
            acquire: { id in
                await acquisitions.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in
                throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
            },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
        var schema = #"{"type":"string"}"#
        for _ in 0 ..< 200 { schema = #"{"type":"array","items":"# + schema + "}" }
        let tools = #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":"#
            + schema + "}}}}]"
        let chat = #"{"model":"fixture","messages":[{"role":"user","content":"hi"}],"# + tools + "}"
        try await app.test(.router) { client in
            for (path, body) in [
                ("/v1/chat/completions", chat),
                ("/v1/chat/completions/batch", "[" + chat + "]"),
                ("/v1/responses", #"{"model":"fixture","input":"hi","# + tools + "}"),
            ] {
                try await client.execute(uri: path, method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                    body: ByteBuffer(string: body)) { response in
                    #expect(response.status == .badRequest, "\(path)")
                    let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(buffer: response.body))
                    #expect(error.error.message == "request JSON nests deeper than \(JSONNestingLimit.maximumDepth) levels")
                }
            }
        }
        #expect(await acquisitions.count == 0)
    }
}

private actor AcquisitionCount {
    var count = 0
    func mark() { count += 1 }
}
