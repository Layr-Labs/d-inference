// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

/// Local real-artifact gate for the LFM2.5 chat template. The official
/// template and tokenizer are not redistributed here: both come from the
/// pinned snapshot named by `LFM2_TEMPLATE_MODEL_DIR`. The request bodies are
/// committed; the reference prompts/token ids are produced locally by
/// `scripts/generate-lfm2-template-reference.py` (transformers + jinja2) into
/// `LFM2_TEMPLATE_REFERENCE_DIR`.
final class LFM2TemplateParityLiveTests: XCTestCase {
    func testProviderPathMatchesTransformersReference() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LFM2_TEMPLATE_MODEL_DIR"],
              let referencePath = environment["LFM2_TEMPLATE_REFERENCE_DIR"]
        else {
            throw XCTSkip("set LFM2_TEMPLATE_MODEL_DIR and LFM2_TEMPLATE_REFERENCE_DIR for the local artifact parity gate")
        }
        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let referenceDirectory = URL(fileURLWithPath: referencePath, isDirectory: true)
        let tokenizer = try await LocalTokenizerLoader().load(from: modelDirectory)
        let bodies = try LFM2TemplateCorpus.bodies()
        XCTAssertGreaterThanOrEqual(bodies.count, 7)

        for (name, body) in bodies {
            let expectedPrompt = try String(
                contentsOf: referenceDirectory.appendingPathComponent("\(name).txt"), encoding: .utf8)
            let expectedTokens = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
                contentsOf: referenceDirectory.appendingPathComponent("\(name).ids.json"))) as? [NSNumber])
                .map(\.intValue)
            let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer, modelType: "lfm2_moe")
            XCTAssertEqual(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false), expectedPrompt, name)
            XCTAssertEqual(tokens, expectedTokens, name)
            // BOS comes from the template exactly once; the generation prefix
            // opens the reasoning span the streaming parser is seeded with.
            XCTAssertEqual(tokens.first, LFM2TemplateCorpus.bosTokenID, name)
            XCTAssertEqual(tokens.filter { $0 == LFM2TemplateCorpus.bosTokenID }.count, 1, name)
            XCTAssertEqual(Array(tokens.suffix(4)), LFM2TemplateCorpus.generationPrefixTokenIDs, name)
        }
    }

    /// The template raises on a JSON-string `arguments`; the provider must
    /// hand it a mapping. A non-object string still fails closed.
    func testStringArgumentsAreDecodedAndNonObjectsFailClosed() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["LFM2_TEMPLATE_MODEL_DIR"] else {
            throw XCTSkip("set LFM2_TEMPLATE_MODEL_DIR for the local artifact gate")
        }
        let tokenizer = try await LocalTokenizerLoader().load(
            from: URL(fileURLWithPath: modelPath, isDirectory: true))
        func body(arguments: String) -> [String: Any] {
            [
                "model": "lfm2.5-24b-a2b",
                "messages": [
                    ["role": "user", "content": "go"],
                    ["role": "assistant", "content": "", "tool_calls": [[
                        "id": "call_1", "type": "function",
                        "function": ["name": "f", "arguments": arguments],
                    ]]],
                    ["role": "tool", "tool_call_id": "call_1", "content": "ok"],
                ],
            ]
        }
        let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
            JSONSerialization.data(withJSONObject: body(arguments: #"{"a": "x", "b": 2}"#)),
            tokenizer: tokenizer, modelType: "lfm2_moe")
        XCTAssertTrue(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            .contains("<|tool_call_start|>[f(a='x', b=2)]<|tool_call_end|>"))
        XCTAssertThrowsError(try ProviderPromptContractPipeline.tokenizeProviderBody(
            JSONSerialization.data(withJSONObject: body(arguments: "[1, 2]")),
            tokenizer: tokenizer, modelType: "lfm2_moe"))
    }

    /// LFM2.5 has no thinking switch or effort control: effort hints (and no
    /// hint) render the identical reference prompt, still opening `<think>`.
    /// Disable controls are refused before render (owner decision D2; offline
    /// coverage in LFM2ReasoningDisableRejectionTests), also with the real
    /// tokenizer.
    func testEffortHintsDoNotChangeThePromptAndDisableControlsAreRefused() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LFM2_TEMPLATE_MODEL_DIR"],
              let referencePath = environment["LFM2_TEMPLATE_REFERENCE_DIR"]
        else { throw XCTSkip("set LFM2_TEMPLATE_MODEL_DIR and LFM2_TEMPLATE_REFERENCE_DIR") }
        let tokenizer = try await LocalTokenizerLoader().load(
            from: URL(fileURLWithPath: modelPath, isDirectory: true))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(
            fileURLWithPath: referencePath).appendingPathComponent("sys_user.ids.json"))) as? [NSNumber]).map(\.intValue)
        let base = try XCTUnwrap(LFM2TemplateCorpus.bodies().first { $0.0 == "sys_user" }?.1)
        let accepted: [[String: Any]] = [
            [:], ["reasoning": ["effort": "low"]], ["reasoning": ["effort": "medium"]],
            ["reasoning": ["effort": "high"]], ["reasoning_effort": "low"], ["reasoning_effort": "medium"],
            ["reasoning_effort": "high"], ["reasoning": ["enabled": true]],
        ]
        for control in accepted {
            let body = base.merging(control) { _, new in new }
            let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer, modelType: "lfm2_moe")
            XCTAssertEqual(tokens, expected, "\(control)")
        }
        let refused: [([String: Any], ThinkingDisableField)] = [
            (["enable_thinking": false], .enableThinking),
            (["chat_template_kwargs": ["enable_thinking": false]], .chatTemplateKwargsEnableThinking),
            (["reasoning": ["enabled": false]], .reasoningEnabled),
            (["reasoning": ["effort": "none"]], .reasoningEffort),
            (["reasoning_effort": "none"], .topLevelReasoningEffort),
        ]
        for (control, field) in refused {
            let body = base.merging(control) { _, new in new }
            XCTAssertThrowsError(try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer, modelType: "lfm2_moe")) {
                XCTAssertEqual($0 as? MultiModelBatchSchedulerEngineError, .reasoningCannotBeDisabled(field))
            }
        }
    }

    /// Real-tokenizer streaming: token-by-token detokenization (UTF-8
    /// holdback) feeding the LFM reasoning router never emits a replacement
    /// character or a marker, and `</think>`/tool tags are single tokens.
    func testRealTokenStreamSplitsReasoningAndCall() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["LFM2_TEMPLATE_MODEL_DIR"] else {
            throw XCTSkip("set LFM2_TEMPLATE_MODEL_DIR for the local artifact gate")
        }
        let tokenizer = try await LocalTokenizerLoader().load(
            from: URL(fileURLWithPath: modelPath, isDirectory: true))
        XCTAssertEqual(tokenizer.convertTokenToId("</think>"), 124_902)
        XCTAssertEqual(tokenizer.convertTokenToId("<|tool_call_start|>"), 124_905)
        XCTAssertEqual(tokenizer.convertTokenToId("<|tool_call_end|>"), 124_906)
        XCTAssertEqual(tokenizer.convertTokenToId("<|im_end|>"), 124_900)
        let generated = "東京は🌊です。</think>Ответ ✓<|tool_call_start|>[get_weather(location='Zürich')]<|tool_call_end|>"
        let ids = tokenizer.encode(text: generated, addSpecialTokens: false)
        XCTAssertTrue(ids.contains(124_902) && ids.contains(124_905) && ids.contains(124_906))
        let detokenizer = DetokenizerV2(tokenizer: tokenizer)
        let handler = BatchedToolStreamHandler(format: .lfm2, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false,
            nativePrefix: "<think>", absorbStrayThinkClose: true)
        var reasoning = "", content = ""
        func collect(_ events: [MLXServerGenerationEvent]) {
            for case .parsed(let piece) in events {
                reasoning += piece.reasoningContent ?? ""
                content += piece.content
            }
        }
        for id in ids {
            let chunk = detokenizer.append(id)
            XCTAssertFalse(chunk.contains("\u{FFFD}"))
            collect(try router.process(chunk))
        }
        collect(try router.process(detokenizer.flush()))
        collect(try router.finishText())
        XCTAssertEqual(reasoning, "東京は🌊です。")
        XCTAssertEqual(content, "Ответ ✓")
        let calls = handler.finish()
        XCTAssertEqual(calls.map(\.function.name), ["get_weather"])
        XCTAssertEqual(calls.first?.function.arguments["location"], .string("Zürich"))
    }

    func testTemplateRenderCheckAcceptsSnapshot() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["LFM2_TEMPLATE_MODEL_DIR"] else {
            throw XCTSkip("set LFM2_TEMPLATE_MODEL_DIR for the local artifact gate")
        }
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        XCTAssertEqual(TemplateRenderCheck.renderOK(
            at: directory, modelID: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"), true)
        // Text-only: no media fixtures, no media advertisement, so image/video
        // parts take the established mediaUnsupportedByModel rejection.
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any])
        XCTAssertEqual(config["model_type"] as? String, "lfm2_moe")
        XCTAssertFalse(ModelMediaPolicy.advertisesMedia(config, modelID: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"))
    }
}

/// Committed request bodies (no template text). Shared with the reference
/// generator so both sides render exactly the same requests.
enum LFM2TemplateCorpus {
    static let bosTokenID = 124_894
    /// `<|im_start|>assistant\n<think>` in the pinned tokenizer.
    static let generationPrefixTokenIDs = [124_899, 63_514, 207, 124_901]

    static func bodies() throws -> [(String, [String: Any])] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "lfm2-template-request-bodies", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try object.keys.sorted().map { key in
            (key, try XCTUnwrap(object[key] as? [String: Any]))
        }
    }
}
