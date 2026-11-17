import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A batch's items run one after another, and every response waits for the last: the item count is refused before
/// any item reaches a model.
@Suite("Local chat batch size")
struct LocalChatBatchLimitTests {
    @Test func aBatchOverSixtyFourRequestsIs400BeforeAnyAcquisition() async throws {
        let spy = BatchAcquisitionSpy()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 32,
            acquire: { id in
                await spy.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
        let item = #"{"model":"fixture","messages":[{"role":"user","content":"hi"}]}"#
        func batch(_ count: Int) -> ByteBuffer {
            ByteBuffer(string: "[" + Array(repeating: item, count: count).joined(separator: ",") + "]")
        }
        let overLimit = batch(65), atLimit = batch(64)
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post, headers: headers,
                                     body: overLimit) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.accessControlAllowOrigin] == "*")
                let text = String(buffer: response.body)
                let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(text.utf8))
                #expect(error.error.type == "invalid_request_error")
                #expect(error.error.code == "batch_too_large")
                #expect(error.error.message == "batch exceeds the 64-request local endpoint limit")
            }
            #expect(await spy.count == 0)
            // At the limit the batch is served as before: its first item reaches acquisition, whose refusal answers it.
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post, headers: headers,
                                     body: atLimit) { response in
                #expect(response.status == .notFound)
            }
            #expect(await spy.count == 1)
        }
    }
}

extension LocalChatBatchLimitTests {
    /// The item count is read before any item is decoded: 65 values that are not chat requests are refused for their
    /// count, not their shape, while 64 of them still reach the decoder. Commas and brackets inside strings are not
    /// items: 64 requests whose text holds them are served.
    @Test func aBatchIsCountedBeforeItsItemsAreDecoded() async throws {
        let spy = BatchAcquisitionSpy()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 32,
            acquire: { id in
                await spy.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
        let punctuated = #"{"model":"fixture","messages":[{"role":"user","content":"a, b, [c], {d}, \"e,\" ]"}]}"#
        let overLimit = ByteBuffer(string: "[" + Array(repeating: "1", count: 65).joined(separator: ",") + "]")
        let atLimit = ByteBuffer(string: "[" + Array(repeating: "1", count: 64).joined(separator: ",") + "]")
        let punctuatedBatch = ByteBuffer(
            string: "[" + Array(repeating: punctuated, count: 64).joined(separator: ",") + "]")
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post, headers: headers,
                                     body: overLimit) { response in
                #expect(response.status == .badRequest)
                let text = String(buffer: response.body)
                let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(text.utf8))
                #expect(error.error.code == "batch_too_large")
            }
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post, headers: headers,
                                     body: atLimit) { response in
                #expect(response.status == .badRequest)
                let text = String(buffer: response.body)
                let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(text.utf8))
                #expect(error.error.code != "batch_too_large")
            }
            #expect(await spy.count == 0)
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post, headers: headers,
                                     body: punctuatedBatch) { response in
                #expect(response.status == .notFound)
            }
            #expect(await spy.count == 1)
        }
    }
}

private actor BatchAcquisitionSpy {
    var count = 0
    func mark() { count += 1 }
}
