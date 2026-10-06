import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

final class MiMoV26ConsumerParityTests: XCTestCase {
    func testRecordedTypelessAndBooleanSchemaIngressDivergence() async throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_CONSUMER_DIVERGENCE_TESTS")
        struct Vectors: Decodable {
            struct Row: Decodable { let id: String; let request_json: String }
            let cases: [Row]
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_CONSUMER_DIVERGENCE_VECTORS"])
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(vectors.cases.count, 2)
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for row in vectors.cases {
            let body = Data(row.request_json.utf8)
            XCTAssertLessThan(body.count, ToolSchemaNormalization.maxNormalizationBytes)
            let remote = try ProviderLoop.decodeOpenAIRequest(body)
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            XCTAssertEqual(controls.rawMiMoControls, local.templateControls.rawMiMoControls)
            XCTAssertEqual(try MiMoV26TemplateFix.additionalContext(request: remote, controls: controls)?["enable_thinking"] as? Bool, false)
            let remoteIDs = try ProviderPromptContractPipeline.tokenizeProviderBody(
                body, tokenizer: tokenizer.inner, modelType: "mimo_v2")
            let localIDs = try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "mimo_v2", allowInternalSchemaMetadata: false),
                request: local.request, tokenizer: tokenizer.inner, modelType: "mimo_v2",
                templateControls: local.templateControls)
            XCTAssertNotEqual(remoteIDs, localIDs, "Known unresolved normalization divergence, NOT parity")
            let record: [String: Any] = ["id": row.id, "status": "observed-known-divergence",
                "provider_tokens": remoteIDs, "local_tokens": localIDs,
                "provider_rendered_decode": tokenizer.inner.decode(tokenIds: remoteIDs, skipSpecialTokens: false),
                "local_rendered_decode": tokenizer.inner.decode(tokenIds: localIDs, skipSpecialTokens: false),
                "native_enable_thinking": false]
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("MIMO_CONSUMER_DIVERGENCE " + String(decoding: bytes, as: UTF8.self))
        }
    }

    func testRawControlCapsuleRejectsTypesUnknownKeysAndGranularEffort() throws {
        let bad = [
            #""enable_thinking":"false""#, #""enable_thinking":0"#, #""enable_thinking":1"#,
            #""enable_thinking":null"#, #""reasoning_effort":"high""#, #""reasoning_effort":7"#,
            #""chat_template_kwargs":{"unknown":"sensitive_fixture_detail"}"#,
            #""chat_template_kwargs":false"#, #""chat_template_kwargs":{"enable_thinking":0}"#,
            #""preserve_thinking":false"#, #""reasoning":{"summary":"sensitive_fixture_detail"}"#,
            #""reasoning":{"enabled":false,"unknown":0}"#
        ]
        for fragment in bad {
            let data = MiMoConsumerFixture.body(fragment)
            let controls = ProviderLoop.extractChatTemplateControls(from: data)
            XCTAssertTrue(controls.rawMiMoControls.invalid, fragment)
            XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(data))
            XCTAssertThrowsError(try controls.rawMiMoControls.validate(modelType: "mimo_v2")) {
                XCTAssertFalse(String(describing: $0).contains("sensitive_fixture_detail"))
            }
            XCTAssertNoThrow(try controls.rawMiMoControls.validate(modelType: "llama"))
            XCTAssertNoThrow(try controls.rawMiMoControls.validate(modelType: nil))
            XCTAssertEqual(controls.withPromptDate(.capture()).rawMiMoControls, controls.rawMiMoControls)
        }
    }

    func testCapsuleBoundedPrivacyAndOtherFamilyPrecedence() throws {
        let short = MiMoConsumerFixture.body(#""chat_template_kwargs":{"private":"x"}"#)
        let long = MiMoConsumerFixture.body(#""chat_template_kwargs":{"private":""#
            + String(repeating: "sensitive_fixture_detail", count: 1024) + #""}"#)
        let a = ProviderLoop.extractChatTemplateControls(from: short).rawMiMoControls
        let b = ProviderLoop.extractChatTemplateControls(from: long).rawMiMoControls
        XCTAssertEqual(a, b)
        XCTAssertLessThan(MemoryLayout<MiMoV26RawControlEvidence>.size, 32)
        let data = MiMoConsumerFixture.body(#""enable_thinking":"false","chat_template_kwargs":{"enable_thinking":true},"reasoning":{"enabled":false},"reasoning_effort":"high""#)
        let request = try ProviderLoop.decodeOpenAIRequest(data)
        let controls = ProviderLoop.extractChatTemplateControls(from: data)
        XCTAssertEqual(controls.enableThinking, true)
        XCTAssertEqual(controls.reasoningEffort, "high")
        XCTAssertEqual(MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, controls: controls, modelType: "llama")?["enable_thinking"] as? Bool, false)
        XCTAssertNotEqual(controls, ChatTemplateControls(reasoningEffort: "high", enableThinking: true),
            "Refusal evidence remains part of equality")
    }

    func testEncryptedDecodeAndLocalDecodeKeepEquivalentMiMoEvidence() throws {
        for fragment in ["", #""enable_thinking":false"#, #""enable_thinking":"false""#,
                         #""reasoning":{"summary":"discarded_by_upstream"}"#] {
            let body = MiMoConsumerFixture.body(fragment)
            let remoteRequest = try ProviderLoop.decodeOpenAIRequest(body)
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            XCTAssertEqual(remoteRequest, local.request)
            XCTAssertEqual(ProviderLoop.extractChatTemplateControls(from: body).rawMiMoControls,
                local.templateControls.rawMiMoControls)
        }
    }

    func testActualTokenizerReasoningOnOffUnsetAndRecountParity() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for fragment in ["", #""enable_thinking":true"#, #""enable_thinking":false"#,
                         #""reasoning":{"effort":"none"}"#, #""reasoning":{"enabled":false}"#] {
            let body = MiMoConsumerFixture.body(fragment)
            let item = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let expected = try ProviderPromptContractPipeline.tokenizeProviderBody(
                body, tokenizer: tokenizer.inner, modelType: "mimo_v2")
            let serving = MiMoConsumerServing(tokenizer: tokenizer,
                output: fragment.isEmpty || fragment.contains("true") ? "<think>Thought</think>Ready" : "Ready")
            let response = try await serving.service(item.templateControls).createChatCompletion(request: item.request)
            let message = try XCTUnwrap(response.choices.first?.message)
            XCTAssertEqual(message.content.text, "Ready")
            XCTAssertEqual(message.reasoningContent ?? "", fragment.isEmpty || fragment.contains("true") ? "Thought" : "")
            XCTAssertEqual(serving.backend.prompts, [expected])
            XCTAssertEqual(ProviderLoop.promptTokenFloor(request: item.request, tokenizer: tokenizer,
                modelType: "mimo_v2", templateControls: item.templateControls), expected.count)
            await serving.bridge.shutdown()
        }
    }

    func testActualTokenizerOrderedParallelHistoryNullEscapingUnicode() async throws {
        let (tokenizer, corpus) = try await MiMoConsumerFixture.load()
        for row in corpus.cases {
            let body = Data(row.request_json.utf8)
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let expected = try ProviderPromptContractPipeline.tokenizeProviderBody(body,
                tokenizer: tokenizer.inner, modelType: "mimo_v2")
            XCTAssertEqual(expected, row.token_ids, row.id)
            let actual = try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "mimo_v2"),
                request: local.request, tokenizer: tokenizer.inner, modelType: "mimo_v2",
                templateControls: local.templateControls)
            XCTAssertEqual(actual, expected, row.id)
            XCTAssertEqual(ProviderLoop.promptTokenFloor(request: local.request, tokenizer: tokenizer,
                modelType: "mimo_v2", templateControls: local.templateControls), expected.count, row.id)
        }
    }

    func testTypedResponsesAndApplyTemplateUseSameNativePreparation() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let body = Data(#"{"model":"fixture","input":"hello","reasoning":{"effort":"none"}}"#.utf8)
        let item = try JSONDecoder().decode(LocalResponseRequest.self, from: body)
        let chat = item.request.chatCompletionRequest
        let serving = MiMoConsumerServing(tokenizer: tokenizer)
        _ = try await serving.service(item.templateControls).createResponse(request: item.request)
        let expected = try ProviderPromptContractPipeline.tokenizeProviderBody(
            MiMoConsumerFixture.body(#""reasoning":{"effort":"none"}"#),
            tokenizer: tokenizer.inner, modelType: "mimo_v2")
        XCTAssertEqual(serving.backend.prompts, [expected])
        let utility = try await serving.engine().applyTemplate(.init(model: "fixture", messages: chat.messages))
        let nativeDefault = try ProviderPromptContractPipeline.tokenizeProviderBody(
            MiMoConsumerFixture.body(), tokenizer: tokenizer.inner, modelType: "mimo_v2")
        XCTAssertEqual(utility.tokens, nativeDefault)
        await serving.bridge.shutdown()
    }

    func testFactoryEmptyBodyCanonicalizationMatchesBothPinnedLiteralTemplates() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let calls: [[String: any Sendable]] = [["id": "c", "type": "function",
            "function": ["name": "echo", "arguments": ["text": "hello"]] as [String: any Sendable]]]
        for source in try MiMoConsumerFixture.literalSources() {
            let processor = try MiMoConsumerFixture.nativeProcessor(tokenizer: tokenizer, source: source)
            for role in ["system", "user", "assistant", "tool"] {
                var base: Message = ["role": role, "content": ""]
                if role == "assistant" {
                    base["tool_calls"] = calls
                    base["reasoning_content"] = "prior thought"
                }
                let tail: [Message] = role == "assistant"
                    ? [["role": "tool", "tool_call_id": "c", "content": "ok"], ["role": "user", "content": "continue"]] : []
                func render(_ messages: [Message]) throws -> String {
                    try Template(source, with: .init(lstripBlocks: true, trimBlocks: true)).render([
                        "messages": try Jinja.Value(any: messages), "add_generation_prompt": .boolean(true)])
                }
                let emptyRender = try render([base] + tail)
                var absent = base; absent.removeValue(forKey: "content")
                var nativeNull = base; nativeNull["content"] = Jinja.Value.null
                XCTAssertEqual(Data(try render([absent] + tail).utf8), Data(emptyRender.utf8))
                XCTAssertEqual(Data(try render([nativeNull] + tail).utf8), Data(emptyRender.utf8))
                let expected = tokenizer.inner.encode(text: emptyRender, addSpecialTokens: false)
                var foundationNull = base; foundationNull["content"] = NSNull()
                var commonNull = base; commonNull["content"] = MLXLMCommon.JSONValue.null
                for message in [absent, foundationNull, commonNull, base] {
                    let actual = try processor.renderTokens(input: UserInput(messages: [message] + tail))
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }

    func testEffectiveNativeThinkingPreservesDefaultAndValidatedAliasPrecedence() throws {
        let request = try MiMoConsumerFixture.request()
        XCTAssertTrue(try MiMoV26TemplateFix.effectiveThinkingEnabled(request: request, controls: .init()))
        XCTAssertNil(try MiMoV26TemplateFix.additionalContext(request: request, controls: .init()),
            "No synthetic enable_thinking=true key may alter the normalized default context")
        for (fragment, expected) in [
            (#""enable_thinking":true"#, true), (#""enable_thinking":false"#, false),
            (#""reasoning":{"enabled":false}"#, false), (#""reasoning":{"effort":"none"}"#, false),
            (#""reasoning_effort":"off""#, false), (#""reasoning_effort":"0""#, false),
            (#""chat_template_kwargs":{"enable_thinking":false}"#, false),
            (#""enable_thinking":true,"reasoning":{"effort":"none"}"#, true),
            (#""enable_thinking":false,"reasoning":{"enabled":true}"#, true)
        ] {
            let data = MiMoConsumerFixture.body(fragment)
            XCTAssertEqual(try MiMoV26TemplateFix.effectiveThinkingEnabled(
                request: ProviderLoop.decodeOpenAIRequest(data),
                controls: ProviderLoop.extractChatTemplateControls(from: data)), expected)
        }
        for bad in [#""enable_thinking":"false""#, #""enable_thinking":0"#,
                    #""reasoning_effort":"high""#, #""preserve_thinking":false"#] {
            let body = MiMoConsumerFixture.body(bad)
            XCTAssertThrowsError(try MiMoV26TemplateFix.effectiveThinkingEnabled(
                request: ProviderLoop.decodeOpenAIRequest(body),
                controls: ProviderLoop.extractChatTemplateControls(from: body)))
        }
    }

    func testRealSchedulerPlainAndStreamAllowOptionalThoughtOnlyWhenEnabled() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for (control, enabled) in [("", true), (#""enable_thinking":true"#, true),
            (#""enable_thinking":false"#, false), (#""reasoning":{"effort":"none"}"#, false)] {
            let outputs = enabled ? ["Ready", "<think>Thought</think>Ready"] : ["Ready", "<think></think>Ready"]
            for output in outputs {
                let item = try JSONDecoder().decode(LocalChatRequest.self, from: MiMoConsumerFixture.body(control))
                let serving = MiMoConsumerServing(tokenizer: tokenizer, output: output, width: 1)
                let service = serving.service(item.templateControls)
                let plain = try await service.createChatCompletion(request: item.request)
                let message = try XCTUnwrap(plain.choices.first?.message)
                let stream = try await service.streamChatCompletionFrames(request: item.request)
                let chunks = try await MiMoConsumerFixture.frames(stream)
                let streamed = try MiMoConsumerFixture.chatText(chunks)
                let expectedReasoning = output.contains("Thought") ? "Thought" : ""
                XCTAssertEqual(message.content.text, "Ready")
                XCTAssertEqual(message.reasoningContent ?? "", expectedReasoning)
                XCTAssertEqual(streamed.content, message.content.text)
                XCTAssertEqual(streamed.reasoning, message.reasoningContent ?? "")
                XCTAssertEqual(serving.backend.prompts.count, 2)
                XCTAssertEqual(serving.backend.prompts.first, serving.backend.prompts.last)
                await serving.bridge.shutdown()
            }
        }
    }
}
