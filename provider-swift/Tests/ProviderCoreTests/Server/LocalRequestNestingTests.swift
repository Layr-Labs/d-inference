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
        let tools = InboundJSONDepthTests.toolsField(nesting: 200)
        let chat = #"{"model":"fixture","messages":[{"role":"user","content":"hi"}],"# + tools + "}"
        try await app.test(.router) { client in
            let deepArguments = #"{"model":"fixture","# + InboundJSONDepthTests.messagesField(argumentNesting: 200) + "}"
            let responsesArguments = #"{"model":"fixture","input":[{"type":"function_call","call_id":"c1","name":"f","arguments":""#
                + String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
                + #""},{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#
            let utf16 = try #require(chat.data(using: .utf16LittleEndian))
            for (path, body, message) in [
                ("/v1/chat/completions", ByteBuffer(string: chat), JSONNestingLimit.refusalMessage),
                ("/v1/chat/completions/batch", ByteBuffer(string: "[" + chat + "]"), JSONNestingLimit.refusalMessage),
                ("/v1/responses", ByteBuffer(string: #"{"model":"fixture","input":"hi","# + tools + "}"),
                 JSONNestingLimit.refusalMessage),
                ("/v1/chat/completions", ByteBuffer(data: utf16), JSONNestingLimit.refusalMessage),
                ("/apply-template", ByteBuffer(string: chat), JSONNestingLimit.refusalMessage),
                ("/tokenize", ByteBuffer(string: chat), JSONNestingLimit.refusalMessage),
                ("/v1/chat/completions", ByteBuffer(string: deepArguments), JSONNestingLimit.argumentsRefusalMessage),
                ("/v1/chat/completions/batch", ByteBuffer(string: "[" + deepArguments + "]"),
                 JSONNestingLimit.argumentsRefusalMessage),
                ("/v1/responses", ByteBuffer(string: responsesArguments), JSONNestingLimit.argumentsRefusalMessage),
            ] {
                try await client.execute(uri: path, method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                    body: body) { response in
                    #expect(response.status == .badRequest, "\(path)")
                    let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(buffer: response.body))
                    #expect(error.error.message == message, "\(path)")
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
