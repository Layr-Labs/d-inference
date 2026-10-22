import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import XCTest
@_spi(Benchmarking) @testable import ProviderCore

/// New minimal reproducers, not the unavailable historical divergence corpus.
/// Uses the existing immutable MiMo tokenizer and a scripted generation boundary;
/// no model weights or GPU forward are needed by these regressions.
final class MiMoV26SchemaParityTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Row: Decodable { let id: String; let request_json: String }
        let cases: [Row]
    }
    private func vectors() throws -> Vectors {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let bytes = try Data(contentsOf: root.appendingPathComponent(
            "fixtures/prompt-contract/mimo-v26-schema-parity-v1.json"))
        XCTAssertEqual(MiMoConsumerFixture.sha(bytes),
            "cc28dcb11b8ac98bf202733b10be998d9b96ca5d52dec88c356157b500fc0d93")
        let vectors = try JSONDecoder().decode(Vectors.self, from: bytes)
        XCTAssertEqual(vectors.cases.map(\.id), ["new-typeless-enum", "new-boolean-property"])
        return vectors
    }

    func testNewSchemasHaveExactIngressServingRecountAndBenchmarkParity() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for row in try vectors().cases {
            let body = Data(row.request_json.utf8)
            let provider = try ProviderLoop.decodeOpenAIRequest(body) // Production model-blind ingress.
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            XCTAssertNotEqual(provider.tools, local.request.tools, "The fixture must exercise real ingress mutation")
            let localIDs = try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "mimo_v2",
                    allowInternalSchemaMetadata: false),
                request: local.request, tokenizer: tokenizer.inner, modelType: "mimo_v2",
                templateControls: local.templateControls)
            XCTAssertEqual(try ProviderPromptContractPipeline.tokenizeProviderBody(
                body, tokenizer: tokenizer.inner, modelType: "mimo_v2"), localIDs, row.id)
            XCTAssertEqual(ProviderLoop.promptTokenFloor(request: provider, tokenizer: tokenizer,
                modelType: "mimo_v2", templateControls: controls), localIDs.count, row.id)
            XCTAssertEqual(try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: tokenizer.inner,
                modelType: "mimo_v2", defaultDate: PromptRenderDate("2026-10-17")!).tokens, localIDs, row.id)
            for (request, control) in [(provider, controls), (local.request, local.templateControls)] {
                let serving = MiMoConsumerServing(tokenizer: tokenizer, output: "Ready")
                do {
                    _ = try await serving.service(control).createChatCompletion(request: request)
                    XCTAssertEqual(serving.backend.prompts, [localIDs], row.id)
                    await serving.bridge.shutdown()
                } catch {
                    await serving.bridge.shutdown()
                    throw error
                }
            }
        }
    }

    func testOriginalSchemaControlsValidationAndOtherFamiliesStayIsolated() throws {
        for row in try vectors().cases {
            let body = Data(row.request_json.utf8)
            let provider = try ProviderLoop.decodeOpenAIRequest(body)
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let restored = try controls.rawMiMoTools.restoring(provider, modelType: "mimo_v2")
            XCTAssertEqual(restored, local.request, row.id)
            XCTAssertEqual(controls.withPromptDate(.capture()).rawMiMoTools, controls.rawMiMoTools)
            for family in [nil, "llama", "glm5_next", "mimo_v2_alias"] as [String?] {
                XCTAssertEqual(try controls.rawMiMoTools.restoring(provider, modelType: family), provider)
            }
            for choice: OpenAIToolChoice in [.mode(.auto), .mode(.none), .mode(.required), .function(name: "echo")] {
                var a = restored, b = local.request
                a.toolChoice = choice; b.toolChoice = choice
                let left = Result { try ToolChoicePromptPolicy.prepare(a, modelType: "mimo_v2", allowInternalSchemaMetadata: false) }
                let right = Result { try ToolChoicePromptPolicy.prepare(b, modelType: "mimo_v2", allowInternalSchemaMetadata: false) }
                switch (left, right) {
                case (.success(let p), .success(let q)):
                    XCTAssertEqual(p.tools, q.tools); XCTAssertEqual(p.messages, q.messages)
                    XCTAssertEqual(p.mode, q.mode); XCTAssertEqual(p.allowedToolNames, q.allowedToolNames)
                    XCTAssertEqual(p.allowsParallelCalls, q.allowsParallelCalls)
                case (.failure(let p), .failure(let q)):
                    XCTAssertEqual(String(describing: p), String(describing: q))
                default: XCTFail("Tool-choice acceptance/refusal differs between ingresses")
                }
            }
        }
        XCTAssertLessThan(MemoryLayout<MiMoV26RawControlEvidence>.size, 32)
        XCTAssertEqual(ToolSchemaNormalization.maxNormalizationBytes, 4 * 1024 * 1024)
    }

    func testOriginalMetadataCannotAcquireNormalizerTrust() throws {
        let marker = ToolSchemaNormalization.originalBooleanSchemaKey
        for row in try vectors().cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.request_json.utf8)) as? [String: Any])
            var tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
            var function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
            function["parameters"] = ["type": "object", marker: false]
            tools[0]["function"] = function; object["tools"] = tools
            for choice in ["auto", "none", "required"] {
                object["tool_choice"] = choice
                let body = try JSONSerialization.data(withJSONObject: object)
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                let controls = ProviderLoop.extractChatTemplateControls(from: body)
                XCTAssertThrowsError(try controls.rawMiMoTools.restoring(request, modelType: "mimo_v2"))
                XCTAssertNoThrow(try controls.rawMiMoTools.restoring(request, modelType: "llama"))
            }
        }
    }
    func testHostedToolsFollowActualFallbackWithRawSchemaServingRecountAndBenchmarkParity() async throws {
        let (tokenizer, _) = try await MiMoConsumerFixture.load()
        for row in try vectors().cases {
            for hostedOnly in [false, true] {
                var referenceObject = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(row.request_json.utf8)) as? [String: Any])
                if hostedOnly { referenceObject["tools"] = [] as [Any] }
                let referenceBody = try JSONSerialization.data(withJSONObject: referenceObject)
                let reference = try JSONDecoder().decode(LocalChatRequest.self, from: referenceBody)
                var mixedObject = referenceObject
                mixedObject["tools"] = try XCTUnwrap(referenceObject["tools"] as? [Any])
                    + [["type": "web_search"], ["type": "custom", "custom": ["format": "text"]]]
                let mixed = try JSONSerialization.data(withJSONObject: mixedObject)
                XCTAssertThrowsError(try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: mixed),
                    "The fixture must enter the real ingress repair branch")
                let decoded = try ProviderLoop.decodeOpenAIRequest(mixed)
                let controls = ProviderLoop.extractChatTemplateControls(from: mixed)
                XCTAssertEqual(try controls.rawMiMoTools.restoring(decoded, modelType: "mimo_v2"),
                    reference.request, row.id)
                let expected = try ProviderPromptContractPipeline.tokenize(
                    prepared: ToolChoicePromptPolicy.prepare(reference.request, modelType: "mimo_v2",
                        allowInternalSchemaMetadata: false),
                    request: reference.request, tokenizer: tokenizer.inner, modelType: "mimo_v2",
                    templateControls: reference.templateControls)
                XCTAssertEqual(try ProviderPromptContractPipeline.tokenizeProviderBody(
                    mixed, tokenizer: tokenizer.inner, modelType: "mimo_v2"), expected, row.id)
                XCTAssertEqual(ProviderLoop.promptTokenFloor(request: decoded, tokenizer: tokenizer,
                    modelType: "mimo_v2", templateControls: controls), expected.count, row.id)
                XCTAssertEqual(try EngineV2Factory.benchmarkPrompt(body: mixed, tokenizer: tokenizer.inner,
                    modelType: "mimo_v2", defaultDate: PromptRenderDate("2026-10-17")!).tokens, expected)
                let serving = MiMoConsumerServing(tokenizer: tokenizer, output: "Ready")
                do {
                    _ = try await serving.service(controls).createChatCompletion(request: decoded)
                    XCTAssertEqual(serving.backend.prompts, [expected], row.id)
                    await serving.bridge.shutdown()
                } catch {
                    await serving.bridge.shutdown()
                    throw error
                }
            }
        }
    }

    func testFallbackCaptureUsesStructuralSDKRuleAndRetainsMalformedFunctionFailures() throws {
        let base = try XCTUnwrap(try vectors().cases.first)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(base.request_json.utf8)) as? [String: Any])
        let entries: [(Any, Int)] = [
            (["name": "echo", "input_schema": ["type": "object"]], 1),
            (["type": 7, "name": "echo", "parameters": ["type": "object"]], 1),
            (["function": [], "name": "echo", "parameters": ["type": "object"]], 1),
            (["type": "custom", "name": "echo", "parameters": ["type": "object"]], 1),
            (["function": "bad"], 0), (7, 0), (NSNull(), 0)
        ]
        for (entry, expectedCount) in entries {
            var object = original
            object["tools"] = [entry, ["type": "web_search"]]
            let body = try JSONSerialization.data(withJSONObject: object)
            let decoded = try ProviderLoop.decodeOpenAIRequest(body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let restored = try controls.rawMiMoTools.restoring(decoded, modelType: "mimo_v2")
            let expected: [OpenAITool]
            if expectedCount == 1 {
                expected = [try JSONDecoder().decode(OpenAITool.self,
                    from: JSONSerialization.data(withJSONObject: entry))]
            } else { expected = [] }
            XCTAssertEqual(restored.tools, expected)
            XCTAssertEqual(restored.tools?.map(\.function.name), decoded.tools?.map(\.function.name))
            XCTAssertEqual(restored.tools?.map(\.type), decoded.tools?.map(\.type))
            XCTAssertEqual(restored.tools?.count, expectedCount)
            if restored.tools?.first?.type == "custom" {
                XCTAssertThrowsError(try MiMoV26TemplateFix.validateRequest(restored),
                    "Preserving decoder repair does not relax native function-only admission")
            }
        }
        let valid = try ProviderLoop.decodeOpenAIRequest(Data(base.request_json.utf8))
        for entry: Any in [["function": [:]], ["function": ["name": 7]],
            ["function": ["name": "echo", "strict": "yes"]], ["name": "echo", "strict": "yes"]] {
            var object = original
            object["tools"] = [entry, ["type": "web_search"]]
            let body = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ProviderLoop.decodeOpenAIRequest(body))
            XCTAssertThrowsError(try ProviderLoop.extractChatTemplateControls(from: body)
                .rawMiMoTools.restoring(valid, modelType: "mimo_v2"))
        }
    }

}
