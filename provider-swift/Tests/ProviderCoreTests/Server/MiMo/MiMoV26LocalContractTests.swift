import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import NIOFoundationCompat
import XCTest
@testable import ProviderCore

private extension MiMoConsumerServing {
    func application() -> LocalInferenceApplication {
        makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 64,
            acquire: { _ in
                acquireCount.increment()
                return .init(tokenizer: tokenizer,
                    releaseToken: .init(release: { _ in releases.increment() }, modelId: "fixture"),
                    modelType: modelType, engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in
                lookupCount.increment()
                return .init(tokenizer: tokenizer, modelType: modelType)
            },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
    }
}

final class MiMoV26LocalContractTests: XCTestCase {
    func testRealHTTPMalformedFramesNeverStreamFallbackBeforeTerminalError() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let badOutputs = [
            #"<tool_call>{"name":"echo","arguments":{"text":"PRIVATE_BAD_FRAME"}}</tool_call>"#,
            "<tool_call><function=echo><parameter=text>PRIVATE_BAD_FRAME</parameter><parameter=text>duplicate</parameter></function></tool_call>",
            // True EOS flush: unfinished native data must not emerge as residual text.
            "<tool_call><function=echo><parameter=text>PRIVATE_BAD_FRAME"
        ]
        for choice in [#""auto""#, #""none""#, #""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            for output in badOutputs {
                for width in [1, 7, output.unicodeScalars.count] {
                    let serving = MiMoConsumerServing(tokenizer: tokenizer, output: output, width: width)
                    try await serving.application().test(.router) { client in
                        for responses in [false, true] {
                            for streaming in [false, true] {
                                let data = try MiMoConsumerFixture.httpBody(#""enable_thinking":false"#,
                                    choice: choice, responses: responses, streaming: streaming)
                                try await client.execute(uri: responses ? "/v1/responses" : "/v1/chat/completions",
                                    method: .post,
                                    headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                                    body: ByteBuffer(bytes: data)) { result in
                                    let text = String(buffer: result.body)
                                    XCTAssertFalse(text.contains("PRIVATE_BAD_FRAME"), "Bad fallback must never precede the error")
                                    XCTAssertFalse(text.contains("<tool_call>"))
                                    if streaming {
                                        XCTAssertEqual(result.status, .ok)
                                        if responses {
                                            XCTAssertTrue(text.contains("response.failed"))
                                            XCTAssertFalse(text.contains("response.completed"))
                                        } else {
                                            XCTAssertTrue(try MiMoConsumerFixture.sseObjects(text).contains { $0["error"] != nil })
                                            XCTAssertFalse(text.contains("[DONE]"))
                                        }
                                    } else {
                                        XCTAssertEqual(result.status.code, choice == #""auto""# ? 500 : 422)
                                        _ = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(buffer: result.body))
                                    }
                                }
                            }
                        }
                    }
                    XCTAssertEqual(serving.backend.prompts.count, 4, "Only model output, never parsing/tokenization, is scripted")
                    await serving.bridge.shutdown()
                }
            }
        }
    }

    func testRealHTTPChatResponsesOnOffUnsetPlainAndStreamChannels() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for (control, enabled) in [("", true), (#""enable_thinking":true"#, true),
            (#""enable_thinking":false"#, false), (#""reasoning":{"effort":"none"}"#, false)] {
            let outputs = enabled ? ["Ready", "<think>Thought</think>Ready"] : ["Ready", "<think></think>Ready"]
            for output in outputs {
                let serving = MiMoConsumerServing(tokenizer: tokenizer, output: output, width: 1)
                let expectedReasoning = output.contains("Thought") ? "Thought" : ""
                try await serving.application().test(.router) { client in
                    for responses in [false, true] {
                        for streaming in [false, true] {
                            let data = try MiMoConsumerFixture.httpBody(control, responses: responses, streaming: streaming)
                            try await client.execute(uri: responses ? "/v1/responses" : "/v1/chat/completions",
                                method: .post,
                                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                                body: ByteBuffer(bytes: data)) { result in
                                XCTAssertEqual(result.status, .ok)
                                let content: String, reasoning: String
                                if streaming {
                                    let text = String(buffer: result.body)
                                    let parsed: (content: String, reasoning: String)
                                    if responses { parsed = try MiMoConsumerFixture.responseText(text) }
                                    else { parsed = try MiMoConsumerFixture.chatText(text) }
                                    content = parsed.content; reasoning = parsed.reasoning
                                    XCTAssertFalse(text.contains("response.failed"))
                                    XCTAssertFalse(try MiMoConsumerFixture.sseObjects(text).contains { $0["error"] != nil })
                                } else if responses {
                                    let response = try JSONDecoder().decode(OpenAIResponse.self, from: Data(buffer: result.body))
                                    content = response.outputText
                                    reasoning = response.output.filter { $0.type == "reasoning" }
                                        .flatMap { $0.summary ?? [] }.map(\.text).joined()
                                } else {
                                    let response = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: Data(buffer: result.body))
                                    let message = try XCTUnwrap(response.choices.first?.message)
                                    content = message.content.text; reasoning = message.reasoningContent ?? ""
                                }
                                XCTAssertEqual(content, "Ready")
                                XCTAssertEqual(reasoning, expectedReasoning)
                            }
                        }
                    }
                }
                XCTAssertEqual(serving.backend.prompts.count, 4)
                await serving.bridge.shutdown()
            }
        }
    }

    func testRealHTTPOffNeverExposesGeneratedNonemptyThought() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for control in [#""enable_thinking":false"#, #""reasoning":{"effort":"none"}"#] {
            let serving = MiMoConsumerServing(tokenizer: tokenizer, output: "<think>PRIVATE_OFF_THOUGHT</think>Ready", width: 1)
            try await serving.application().test(.router) { client in
                for responses in [false, true] {
                    for streaming in [false, true] {
                        let data = try MiMoConsumerFixture.httpBody(control, responses: responses, streaming: streaming)
                        try await client.execute(uri: responses ? "/v1/responses" : "/v1/chat/completions", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                            body: ByteBuffer(bytes: data)) { result in
                            let text = String(buffer: result.body)
                            XCTAssertFalse(text.contains("PRIVATE_OFF_THOUGHT"))
                            if streaming {
                                XCTAssertEqual(result.status, .ok)
                                if responses { XCTAssertTrue(text.contains("response.failed")) }
                                else { XCTAssertTrue(try MiMoConsumerFixture.sseObjects(text).contains { $0["error"] != nil }) }
                            } else { XCTAssertEqual(result.status.code, 500) }
                        }
                    }
                }
            }
            await serving.bridge.shutdown()
        }
    }

    func testLocalReservedSchemaMetadataNeverBecomesTrustedByCapsule() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with:
            MiMoConsumerFixture.body(#""enable_thinking":false"#, choice: #""auto""#)) as? [String: Any])
        let property: [String: Any] = ["type": "string", ToolSchemaNormalization.originalBooleanSchemaKey: true]
        let parameters: [String: Any] = ["type": "object", "properties": ["text": property]]
        let function: [String: Any] = ["name": "echo", "parameters": parameters]
        body["tools"] = [["type": "function", "function": function] as [String: Any]]
        let data = try JSONSerialization.data(withJSONObject: body)
        try await serving.application().test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(bytes: data)) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
        XCTAssertTrue(serving.backend.prompts.isEmpty)
        XCTAssertEqual(serving.releases.value, 1)
        await serving.bridge.shutdown()
    }

    func testHTTPChatStreamingPlainAndBatchCarryEachCapsule() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        let off = MiMoConsumerFixture.body(#""enable_thinking":false"#)
        let expected = try ProviderPromptContractPipeline.tokenizeProviderBody(off,
            tokenizer: tokenizer.inner, modelType: "mimo_v2")
        try await serving.application().test(.router) { client in
            for path in ["/v1/chat/completions", "/chat/completions"] {
                for stream in [false, true] {
                    try await client.execute(uri: path, method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                        body: ByteBuffer(bytes: MiMoConsumerFixture.body(#""enable_thinking":false"#, stream: stream))) { response in
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertTrue(String(buffer: response.body).contains("Ready"))
                    }
                }
            }
            let on = MiMoConsumerFixture.body(#""enable_thinking":true"#)
            let batch = "[" + String(decoding: off, as: UTF8.self) + "," + String(decoding: on, as: UTF8.self) + "]"
            try await client.execute(uri: "/v1/chat/completions/batch", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(string: batch)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try JSONDecoder().decode([OpenAIChatCompletionResponse].self, from: Data(buffer: response.body)).count, 2)
            }
        }
        XCTAssertEqual(serving.backend.prompts.count, 6)
        XCTAssertTrue(serving.backend.prompts.prefix(5).allSatisfy { $0 == expected })
        let onIDs = try ProviderPromptContractPipeline.tokenizeProviderBody(
            MiMoConsumerFixture.body(#""enable_thinking":true"#), tokenizer: tokenizer.inner, modelType: "mimo_v2")
        XCTAssertEqual(serving.backend.prompts.last, onIDs)
        await serving.bridge.shutdown()
    }

    func testHTTPResponsesStreamingPlainAndStoredRetrievalShareControls() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        try await serving.application().test(.router) { client in
            for path in ["/v1/responses", "/responses"] {
                for stream in [false, true] {
                    let body = #"{"model":"fixture","input":"hello","reasoning":{"effort":"none"},"stream":"#
                        + (stream ? "true" : "false") + "}"
                    let responseID = MiMoConsumerResponseID()
                    try await client.execute(uri: path, method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                        body: ByteBuffer(string: body)) { response in
                        XCTAssertEqual(response.status, .ok)
                        let text = String(buffer: response.body)
                        if stream {
                            XCTAssertTrue(text.contains("response.completed"))
                            for line in text.components(separatedBy: "\n") where line.hasPrefix("data: {") {
                                let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
                                if let response = object?["response"] as? [String: Any] {
                                    if let id = response["id"] as? String { responseID.set(id) }
                                }
                            }
                        } else {
                            responseID.set(try JSONDecoder().decode(OpenAIResponse.self, from: Data(buffer: response.body)).id)
                        }
                    }
                    let id = try XCTUnwrap(responseID.value)
                    try await client.execute(uri: "/v1/responses/" + id, method: .get,
                        headers: [.authorization: "Bearer synthetic-fixture-token"]) { response in
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(try JSONDecoder().decode(OpenAIResponse.self, from: Data(buffer: response.body)).id, id)
                    }
                    try await client.execute(uri: "/v1/responses/" + id + "/cancel", method: .post,
                        headers: [.authorization: "Bearer synthetic-fixture-token"]) { response in
                        XCTAssertEqual(response.status, .ok, "Existing stored-response cancel route must remain reachable")
                    }
                }
            }
        }
        let expected = try ProviderPromptContractPipeline.tokenizeProviderBody(
            MiMoConsumerFixture.body(#""reasoning":{"effort":"none"}"#),
            tokenizer: tokenizer.inner, modelType: "mimo_v2")
        XCTAssertEqual(serving.backend.prompts.count, 4)
        XCTAssertTrue(serving.backend.prompts.allSatisfy { $0 == expected })
        await serving.bridge.shutdown()
    }

    func testHTTPRawInvalidControlsRefuseBeforeHeadersWithGenericErrors() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        try await serving.application().test(.router) { client in
            for bad in [#""enable_thinking":"false""#, #""enable_thinking":0"#,
                        #""chat_template_kwargs":{"sensitive_fixture_detail":"secret"}"#,
                        #""reasoning":{"summary":"sensitive_fixture_detail"}"#] {
                let chat = String(decoding: MiMoConsumerFixture.body(bad, stream: true), as: UTF8.self)
                let response = #"{"model":"fixture","input":"hello","stream":true,"# + bad + "}"
                for (path, body) in [("/v1/chat/completions", chat),
                    ("/v1/chat/completions/batch", "[" + chat + "]"), ("/v1/responses", response)] {
                    try await client.execute(uri: path, method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                        body: ByteBuffer(string: body)) { result in
                        XCTAssertEqual(result.status, .badRequest)
                        let text = String(buffer: result.body)
                        XCTAssertFalse(text.contains("data: "))
                        XCTAssertFalse(text.contains("sensitive_fixture_detail"))
                    }
                }
            }
        }
        XCTAssertEqual(serving.acquireCount.value, 0)
        XCTAssertTrue(serving.backend.prompts.isEmpty)
        await serving.bridge.shutdown()
    }

    func testHTTPAuthAndResponsesTwoMiBCeilingRemainUnchanged() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        let huge = #"{"model":"fixture","input":"hi"}"# + String(repeating: " ", count: 2 * 1024 * 1024)
        try await serving.application().test(.router) { client in
            try await client.execute(uri: "/v1/responses", method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(string: huge)) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            for path in ["/v1/responses", "/responses"] {
                try await client.execute(uri: path, method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                    body: ByteBuffer(string: huge)) { response in
                    XCTAssertEqual(response.status, .contentTooLarge)
                    XCTAssertTrue(String(buffer: response.body).contains("2 MiB"))
                }
            }
        }
        XCTAssertEqual(serving.acquireCount.value, 0)
        await serving.bridge.shutdown()
    }

    func testTrustedFamilySelectionAndEarlyResidentRefusalDoNotAcquire() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let data = MiMoConsumerFixture.body(#""enable_thinking":1"#)
        let request = try ProviderLoop.decodeOpenAIRequest(data)
        let controls = ProviderLoop.extractChatTemplateControls(from: data)
        let native = MiMoConsumerServing(tokenizer: tokenizer)
        do { _ = try await native.engine(controls).streamChatCompletion(request: request); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error is MultiModelBatchSchedulerEngineError) }
        XCTAssertEqual(native.lookupCount.value, 1); XCTAssertEqual(native.acquireCount.value, 0)
        let unrelated = MiMoConsumerServing(tokenizer: tokenizer, modelType: "llama")
        var callerNamed = request; callerNamed.model = "XiaomiMiMo/MiMo-V2.6-Flash"
        _ = try await unrelated.service(controls).createChatCompletion(request: callerNamed)
        XCTAssertEqual(unrelated.acquireCount.value, 1, "A request name must not select native behavior")
        await native.bridge.shutdown(); await unrelated.bridge.shutdown()
    }

    func testRequestCancellationAndDeadlineReleaseExactlyOnce() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let serving = MiMoConsumerServing(tokenizer: tokenizer, holdOpen: true)
        let request = try MiMoConsumerFixture.request()
        let stream = try await serving.engine().streamChatCompletion(request: request)
        let task = Task { for try await _ in stream {} }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while serving.backend.outstanding == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(serving.backend.outstanding, 1)
        task.cancel()
        _ = try? await task.value
        while serving.releases.value == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(serving.releases.value, 1)
        XCTAssertEqual(serving.backend.cancelCount, 1)
        XCTAssertEqual(serving.backend.outstanding, 0)
        let attempts = MiMoConsumerCounter()
        let expired = MultiModelBatchSchedulerEngine(registryProvider: { [:] },
            ensureLoaded: { _ in attempts.increment() },
            firstContentDeadline: .init(relativeBudgetMilliseconds: -1))
        do { _ = try await expired.streamChatCompletion(request: request); XCTFail("Expired request accepted") }
        catch { XCTAssertEqual(error as? PreContentDeadlineFailure, .deadlineUnreachable) }
        XCTAssertEqual(attempts.value, 0)
        await serving.bridge.shutdown()
    }

    func testResponsesUnsupportedNestedControlsRemainExplicitAndOtherFamiliesUnchanged() throws {
        for fragment in [#""reasoning":{"enabled":false}"#, #""reasoning":{"parser":"none"}"#,
                         #""reasoning":{"summary":"auto"}"#] {
            let body = Data((#"{"model":"fixture","input":"hello","# + fragment + "}").utf8)
            let value = try JSONDecoder().decode(LocalResponseRequest.self, from: body)
            XCTAssertTrue(value.templateControls.rawMiMoControls.invalid)
            XCTAssertThrowsError(try value.templateControls.rawMiMoControls.validate(modelType: "mimo_v2"))
            XCTAssertNoThrow(try value.templateControls.rawMiMoControls.validate(modelType: "qwen4_exp"))
            XCTAssertEqual(value.request, try JSONDecoder().decode(OpenAIResponseRequest.self, from: body))
            XCTAssertNil(value.templateControls.enableThinking)
        }
    }
}
