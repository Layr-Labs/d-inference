import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import XCTest

@testable import ProviderCore

/// Uses the production local tokenizer and unchanged official literal sources.
/// No fake tokenizer/parser, weights, inference, or network. Missing assets fail
/// this explicit gate; they do not produce an empty successful test or skip.
final class MiMoV26PromptContractTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let request_json: String
            let rendered: String
            let rendered_sha256: String
            let token_ids: [Int]
            let decoded: String
        }
        let cases: [Case]
        let metadata_sha256: [String: String]
        let original31_sha256: String
    }
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func inputs() throws -> (URL, Corpus, [String]) {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try XCTUnwrap(env["MIMO_PROMPT_ARTIFACT_DIRECTORY"],
            "Set MIMO_PROMPT_ARTIFACT_DIRECTORY to the pinned metadata-only directory"))
        let vectorURL = URL(fileURLWithPath: try XCTUnwrap(env["MIMO_PROMPT_REFERENCE_VECTORS"],
            "Set MIMO_PROMPT_REFERENCE_VECTORS to the additional reference-01/vectors.json"))
        let data = try Data(contentsOf: vectorURL)
        XCTAssertEqual(sha(data), "66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb")
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertEqual(corpus.cases.count, 20)
        XCTAssertEqual(corpus.original31_sha256, "c11b2d3a9400bbe935c33f86b1ec6dc0ed91ea6e8b85030d355a4b66d35c2e8e")
        for (file, pin) in corpus.metadata_sha256 {
            XCTAssertEqual(sha(try Data(contentsOf: directory.appendingPathComponent(file))), pin, file)
        }
        let standalone = try String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))) as? [String: Any]
        let inline = try XCTUnwrap(config?["chat_template"] as? String)
        return (directory, corpus, [standalone, inline])
    }

    func testActualProductionPipelineAndBothOriginalTemplatesMatchAdditionalReference() async throws {
        let (directory, corpus, sources) = try inputs()
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        for fixture in corpus.cases {
            let body = Data(fixture.request_json.utf8)
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2")
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let context = ChatTemplateFixContext(modelId: request.model, modelType: "mimo_v2")
            let messages = try ChatTemplateFixes.normalizeMessages(prepared.messages.map { $0.templateMessageDict() }, context: context)
            let tools = ChatTemplateFixes.normalizeTools(prepared.tools?.map { $0.toolSpec() }, context: context)
            let extra = try MiMoV26TemplateFix.additionalContext(request: request, controls: controls)
            var values: [String: Jinja.Value] = ["messages": try .init(any: messages), "add_generation_prompt": .boolean(true)]
            if let tools { values["tools"] = try .init(any: tools) }
            for (key, value) in extra ?? [:] { values[key] = try .init(any: value) }
            for source in sources {
                let rendered = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true)).render(values)
                XCTAssertEqual(Data(rendered.utf8), Data(fixture.rendered.utf8), fixture.id)
                XCTAssertEqual(sha(Data(rendered.utf8)), fixture.rendered_sha256, fixture.id)
                let genericIDs = try tokenizer.applyChatTemplate(messages: messages, chatTemplate: source, tools: tools, additionalContext: extra)
                XCTAssertEqual(genericIDs, fixture.token_ids, fixture.id)
                XCTAssertEqual(tokenizer.encode(text: rendered, addSpecialTokens: false), genericIDs, fixture.id)
            }
            let actualIDs = try ProviderPromptContractPipeline.tokenizeProviderBody(body, tokenizer: tokenizer, modelType: "mimo_v2")
            XCTAssertEqual(actualIDs, fixture.token_ids, fixture.id)
            // Tokenizer NFC decode behavior remains distinct from raw render
            // byte agreement; do not compare canonically-equal Swift Strings.
            XCTAssertEqual(Data(tokenizer.decode(tokenIds: actualIDs, skipSpecialTokens: false).utf8), Data(fixture.decoded.utf8), fixture.id)
        }
    }

    func testUnnormalizedGenericNullRouteFailsThenActualMiMoProviderRoutePreservesNull() async throws {
        let (directory, corpus, _) = try inputs()
        let fixture = try XCTUnwrap(corpus.cases.first { $0.id == "typed-null-array-object-numeric-string" })
        let request = try ProviderLoop.decodeOpenAIRequest(Data(fixture.request_json.utf8))
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        XCTAssertThrowsError(try tokenizer.applyChatTemplate(messages: request.messages.map { $0.templateMessageDict() }, tools: nil, additionalContext: nil))
        let actual = try ProviderPromptContractPipeline.tokenizeProviderBody(Data(fixture.request_json.utf8), tokenizer: tokenizer, modelType: "mimo_v2")
        XCTAssertEqual(actual, fixture.token_ids)
    }

    func testRealProviderBodyRejectsControlLookalikesAndPrimitiveArrayArguments() async throws {
        let (directory, _, _) = try inputs()
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        var bodies: [[String: Any]] = []
        for bad: Any in ["false", 0, 1, NSNull()] {
            bodies.append(["model": "m", "messages": [["role": "user", "content": "hello"]], "enable_thinking": bad])
        }
        bodies.append(["model": "m", "messages": [["role": "user", "content": "hello"]], "reasoning": ["effort": "high"]])
        bodies.append(["model": "m", "messages": [
            ["role": "assistant", "content": "", "tool_calls": [["id": "a", "type": "function",
                "function": ["name": "f", "arguments": [1, NSNull()] as [Any]]]]],
            ["role": "tool", "tool_call_id": "a", "content": "result"]
        ]])
        for body in bodies {
            let data = try JSONSerialization.data(withJSONObject: body)
            XCTAssertThrowsError(try ProviderPromptContractPipeline.tokenizeProviderBody(data, tokenizer: tokenizer, modelType: "mimo_v2"))
        }
    }

    func testSupportedResponsesNoneUsesSameNativeOffTokens() async throws {
        let (directory, _, _) = try inputs()
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let request = OpenAIResponseRequest(model: "m", input: .text("hello"), reasoning: .init(effort: "none")).chatCompletionRequest
        let actual = try ProviderPromptContractPipeline.tokenize(prepared: ToolChoicePromptPolicy.prepare(request, modelType: "mimo_v2"),
            request: request, tokenizer: tokenizer, modelType: "mimo_v2", templateControls: .init())
        let expected = "<|im_start|>user\nhello<|im_end|><|im_start|>assistant\n<think></think>"
        XCTAssertEqual(actual, tokenizer.encode(text: expected, addSpecialTokens: false))
    }

    func testOtherFamilyStillUsesExistingPermissiveControlAndNullNormalization() async throws {
        let (directory, corpus, _) = try inputs()
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        // Same real tokenizer/template isolates provider modelType dispatch;
        // this is a compatibility seam check, not qualification of a Llama.
        let malformedControl = Data(#"{"model":"m","messages":[{"role":"user","content":"hello"}],"enable_thinking":"false"}"#.utf8)
        let actual = try ProviderPromptContractPipeline.tokenizeProviderBody(malformedControl, tokenizer: tokenizer, modelType: "llama")
        XCTAssertEqual(actual, tokenizer.encode(text: "<|im_start|>user\nhello<|im_end|><|im_start|>assistant\n", addSpecialTokens: false))
        let fixture = try XCTUnwrap(corpus.cases.first { $0.id == "typed-null-array-object-numeric-string" })
        let request = try ProviderLoop.decodeOpenAIRequest(Data(fixture.request_json.utf8))
        let oldMessages = try ChatTemplateFixes.normalizeMessages(request.messages.map { $0.templateMessageDict() }, context: .init(modelType: "llama"))
        let oldIDs = try tokenizer.applyChatTemplate(messages: oldMessages, tools: nil, additionalContext: nil)
        XCTAssertNotEqual(oldIDs, fixture.token_ids, "MiMo must not inherit another family's null removal")
    }
}
