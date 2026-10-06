import Foundation
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

final class MiMoV26StreamContractTests: XCTestCase {
    func testNativeRequiredNamedAutoNoneUseExactCodecAndValidation() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#, #""auto""#, #""none""#] {
            let request = try MiMoConsumerFixture.request(#""enable_thinking":false"#, choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2")
            let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "mimo_v2"))
            XCTAssertEqual(handler.format, .mimoV2)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: prepared.requiresToolCall,
                nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: false,
                nativeMiMoRequiresConstraint: prepared.mode.requiresInferenceConstraint)
            _ = try router.process(MiMoConsumerFixture.frame("null &amp;"))
            _ = try router.finishText()
            let calls = handler.finish()
            XCTAssertEqual(calls.count, 1)
            if prepared.mode == .none {
                XCTAssertThrowsError(try ToolConstraintValidation.validate(calls, prepared: prepared))
                XCTAssertNil(prepared.tools, "Forbidden output detection must not restore tools to the prompt")
            } else {
                XCTAssertNoThrow(try ToolConstraintValidation.validate(calls, prepared: prepared))
            }
            var wrong = request
            wrong.toolCallParser = "qwen3_5"
            XCTAssertThrowsError(try ToolStreamPreparation.makeHandler(
                request: wrong, prepared: prepared, modelType: "mimo_v2"))
        }
        XCTAssertFalse(ToolChoiceEnforcementPolicy.nativeStructuredTarget(.init(modelType: "mimo_v2")),
            "Consumer routing must not silently enable public capability advertisement")
        XCTAssertFalse(ToolChoiceEnforcementPolicy.usesNativeTextChannels(.init(modelId: "MiMo", modelType: "llama")))
        let absent = try MiMoConsumerFixture.request()
        let prepared = try ToolChoicePromptPolicy.prepare(absent, modelType: "mimo_v2")
        let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(
            request: absent, prepared: prepared, modelType: "mimo_v2"))
        _ = handler.processChunk(MiMoConsumerFixture.frame("undeclared"))
        XCTAssertThrowsError(try ToolConstraintValidation.validate(handler.finish(), prepared: prepared))
    }

    func testNativeMarkerLiteralsInsideRawArgumentsSurviveAllChunkBoundaries() throws {
        let value = "literal </tool_call><think>private?</think> </function> &amp; null \\n café e\u{301}"
        let frame = MiMoConsumerFixture.frame(value)
        let request = try MiMoConsumerFixture.request(choice: #""required""#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2")
        let scalars = Array(frame.unicodeScalars)
        // Every possible TWO-chunk split, including inside all delimiters.
        for cut in 0...scalars.count {
            let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "mimo_v2"))
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: false)
            let left = String(String.UnicodeScalarView(scalars[..<cut]))
            let right = String(String.UnicodeScalarView(scalars[cut...]))
            let events = try router.process(left) + router.process(right) + router.finishText()
            XCTAssertTrue(events.isEmpty, "Parameter bytes cannot become thought or visible prose")
            let calls = handler.finish()
            XCTAssertEqual(handler.parseFailureCount, 0)
            XCTAssertEqual(calls.count, 1)
            guard case .string(let text)? = calls.first?.function.arguments["text"] else {
                XCTFail("Raw string argument missing"); continue
            }
            XCTAssertEqual(Data(text.utf8), Data(value.utf8))
            try ToolConstraintValidation.validate(calls, prepared: prepared)
        }
    }

    func testNativeReasoningExamplesNeverBecomeToolCalls() throws {
        let request = try MiMoConsumerFixture.request(choice: #""auto""#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2")
        let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(request: request, prepared: prepared, modelType: "mimo_v2"))
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false,
            nativePrefix: "", nativeMiMoChannels: true)
        let thought = "Example: " + MiMoConsumerFixture.frame("not an invocation")
        let events = try router.process("<think>" + thought + "</think>Ready") + router.finishText()
        var reasoning = "", content = ""
        for event in events {
            guard case .parsed(let value) = event else { XCTFail("Expected native channel"); continue }
            reasoning += value.reasoningContent ?? ""; content += value.content
        }
        XCTAssertEqual(Data(reasoning.utf8), Data(thought.utf8))
        XCTAssertEqual(content, "Ready")
        XCTAssertTrue(handler.finish().isEmpty)
    }

    func testNativeOffDoesNotExposeNonemptyGeneratedThought() throws {
        var native = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
            nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: false)
        XCTAssertThrowsError(try native.process("<think>sensitive_fixture_detail</think>"))
        var empty = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
            nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: false)
        XCTAssertNoThrow(try empty.process("<think> \n</think>Ready"))
        var legacy = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
            nativePrefix: "<think></think>")
        XCTAssertNoThrow(try legacy.process("<think>legacy thought</think>"))
    }

    func testNativeMalformedAmbiguousAndTruncatedCallsFailWithoutRepair() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for choice in [#""auto""#, #""required""#, #""none""#] {
            let input = try JSONDecoder().decode(LocalChatRequest.self,
                from: MiMoConsumerFixture.body(#""enable_thinking":false"#, choice: choice))
            for output in [
                "<tool_call><function=echo><parameter=text>unterminated",
                "<tool_call>{\"name\":\"echo\",\"arguments\":{\"text\":\"JSON fallback forbidden\"}}</tool_call>",
                MiMoConsumerFixture.frame("x</parameter><parameter=text>duplicate")
            ] {
                let serving = MiMoConsumerServing(tokenizer: tokenizer, output: output)
                do {
                    _ = try await serving.service(input.templateControls).createChatCompletion(request: input.request)
                    XCTFail("Malformed native output was accepted")
                } catch {}
                XCTAssertEqual(serving.backend.prompts.count, 1)
                await serving.bridge.shutdown()
            }
        }
    }

    func testStreamingAndPlainServicesPreserveIdenticalCallsAndByteStrings() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        let value = "null &amp; </tool_call><think>literal</think> e\u{301}"
        let output = MiMoConsumerFixture.frame(value)
        let input = try JSONDecoder().decode(LocalChatRequest.self,
            from: MiMoConsumerFixture.body(#""enable_thinking":false"#, choice: #""required""#))
        let serving = MiMoConsumerServing(tokenizer: tokenizer, output: output)
        let service = serving.service(input.templateControls)
        let plain = try await service.createChatCompletion(request: input.request)
        let plainCall = try XCTUnwrap(plain.choices.first?.message.toolCalls?.first)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plainCall.function.arguments.utf8)) as? [String: String])
        XCTAssertEqual(Data(try XCTUnwrap(raw["text"]).utf8), Data(value.utf8))
        let stream = try await service.streamChatCompletionFrames(request: input.request)
        let frames = try await MiMoConsumerFixture.frames(stream)
        var arguments = ""
        for line in frames.components(separatedBy: "\n") where line.hasPrefix("data: {") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
            let choices = object["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            let calls = delta?["tool_calls"] as? [[String: Any]]
            for call in calls ?? [] {
                arguments += (call["function"] as? [String: Any])?["arguments"] as? String ?? ""
            }
        }
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String])
        XCTAssertEqual(Data(try XCTUnwrap(decoded["text"]).utf8), Data(value.utf8))
        XCTAssertEqual(serving.backend.prompts.count, 2)
        XCTAssertEqual(serving.backend.prompts.first, serving.backend.prompts.last)
        await serving.bridge.shutdown()
    }

    func testCompleteMalformedNativeFrameThrowsBeforeAnyFallbackAtEverySplit() throws {
        let malformed = #"<tool_call>{"name":"echo","arguments":{"text":"PRIVATE_BAD_FRAME"}}</tool_call>"#
        let scalars = Array(malformed.unicodeScalars)
        for choice in [#""auto""#, #""none""#, #""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            let request = try MiMoConsumerFixture.request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2")
            for cut in 0...scalars.count {
                let handler = try XCTUnwrap(ToolStreamPreparation.makeHandler(
                    request: request, prepared: prepared, modelType: "mimo_v2"))
                var router = NativeToolStreamRouter(handler: handler, requiresToolCall: prepared.requiresToolCall,
                    nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: false,
                    nativeMiMoRequiresConstraint: prepared.mode.requiresInferenceConstraint)
                var published: [MLXServerGenerationEvent] = []
                var refused = false
                do {
                    published += try router.process(String(String.UnicodeScalarView(scalars[..<cut])))
                    published += try router.process(String(String.UnicodeScalarView(scalars[cut...])))
                    XCTFail("Complete malformed frame was deferred until EOS")
                } catch { refused = true }
                XCTAssertTrue(refused)
                XCTAssertTrue(published.isEmpty, "No raw XML/JSON fallback may escape before the error")
                XCTAssertGreaterThan(handler.parseFailureCount, 0)
                XCTAssertThrowsError(try router.finishText(), "Final flush cannot resurrect failed fallback")
            }
        }
    }

    func testActualServicesAutoNamedRequiredAndNonePreserveOrWithholdCalls() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for choice in [#""auto""#, #""none""#, #""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            let input = try JSONDecoder().decode(LocalChatRequest.self,
                from: MiMoConsumerFixture.body(#""enable_thinking":false"#, choice: choice))
            let serving = MiMoConsumerServing(tokenizer: tokenizer, output: MiMoConsumerFixture.frame("MODE_CALL_TEXT"), width: 1)
            let service = serving.service(input.templateControls)
            if choice == #""none""# {
                do { _ = try await service.createChatCompletion(request: input.request); XCTFail("none accepted a call") }
                catch {
                    if let native = error as? MultiModelBatchSchedulerEngineError,
                        case .toolChoiceViolation = native {}
                    else { XCTFail("Expected native tool-choice violation") }
                }
            } else {
                let plain = try await service.createChatCompletion(request: input.request)
                let call = try XCTUnwrap(plain.choices.first?.message.toolCalls?.first)
                XCTAssertEqual(call.function.name, "echo")
                let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: String])
                XCTAssertEqual(args["text"], "MODE_CALL_TEXT")
            }
            let stream = try await service.streamChatCompletionFrames(request: input.request, frameGenerationErrors: true)
            let frames = try await MiMoConsumerFixture.frames(stream)
            let objects = try MiMoConsumerFixture.sseObjects(frames)
            if choice == #""none""# {
                XCTAssertTrue(objects.contains { $0["error"] != nil })
                XCTAssertFalse(frames.contains("MODE_CALL_TEXT"))
            } else {
                XCTAssertFalse(objects.contains { $0["error"] != nil })
                var arguments = ""
                for object in objects {
                    let choices = object["choices"] as? [[String: Any]] ?? []
                    let delta = choices.first?["delta"] as? [String: Any] ?? [:]
                    for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                        arguments += (call["function"] as? [String: Any])?["arguments"] as? String ?? ""
                    }
                }
                let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String])
                XCTAssertEqual(args["text"], "MODE_CALL_TEXT")
            }
            XCTAssertEqual(serving.backend.prompts.count, 2)
            await serving.bridge.shutdown()
        }
    }

    func testOtherFamilyMalformedFrameKeepsItsExistingVisibleFallback() throws {
        let malformed = #"<tool_call>{"not_a_call":"LEGACY_FALLBACK"}</tool_call>"#
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: "<think></think>")
        let events = try router.process(malformed) + router.finishText()
        XCTAssertGreaterThan(handler.parseFailureCount, 0)
        let visible = events.compactMap { event -> String? in
            if case .parsed(let value) = event { return value.content }
            if case .content(let value) = event { return value }
            return nil
        }.joined()
        XCTAssertTrue(visible.contains("LEGACY_FALLBACK"), "Only trusted native MiMo becomes fail-closed here")
    }

    func testNativeThinkingMarkersAcrossEverySplitDoNotRequireAPromptSeed() throws {
        for enabled in [true, false] {
            let output = enabled ? "<think>Thought</think>Ready" : "<think></think>Ready"
            let scalars = Array(output.unicodeScalars)
            for cut in 0...scalars.count {
                var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
                    nativePrefix: "", nativeMiMoChannels: true, nativeMiMoThinkingEnabled: enabled)
                let events = try router.process(String(String.UnicodeScalarView(scalars[..<cut])))
                    + router.process(String(String.UnicodeScalarView(scalars[cut...]))) + router.finishText()
                var content = "", reasoning = ""
                for event in events {
                    guard case .parsed(let value) = event else { XCTFail("Expected native channels"); continue }
                    content += value.content; reasoning += value.reasoningContent ?? ""
                }
                XCTAssertEqual(content, "Ready")
                XCTAssertEqual(reasoning, enabled ? "Thought" : "")
            }
        }
    }
}
