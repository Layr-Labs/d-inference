import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Pinned GLM5 native prompt policy")
struct GLM5NextPromptPolicyTests {
    private var fixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("fixtures/prompt-contract/glm53-flash")
    }

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let request: MLXLMCommon.JSONValue
            let expectedContext: MLXLMCommon.JSONValue
            let rendered: String
            let renderedSHA256: String
            enum CodingKeys: String, CodingKey {
                case id, request, rendered
                case expectedContext = "expected_context"
                case renderedSHA256 = "rendered_sha256"
            }
        }
        let templateSHA256: String
        let cases: [Case]
        enum CodingKeys: String, CodingKey {
            case cases
            case templateSHA256 = "template_sha256"
        }
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requestAndControls(_ body: Data) throws -> (OpenAIChatCompletionRequest, ChatTemplateControls) {
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        return (request, controls)
    }

    private func normalized(_ body: Data) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let (request, controls) = try requestAndControls(body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request, modelType: "glm5_next", templateControls: controls)
    }

    @Test func officialTemplateAndFullPolicyRendersMatchPinnedGoldens() throws {
        let corpus = try JSONDecoder().decode(Corpus.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("goldens.json")))
        let source = try Data(contentsOf: fixtures.appendingPathComponent("chat_template.jinja"))
        #expect(source.count == 10_950)
        #expect(sha(source) == GLM5NextPromptPolicy.templateSHA256)
        #expect(corpus.templateSHA256 == GLM5NextPromptPolicy.templateSHA256)
        #expect(corpus.cases.count == 7)
        let template = try Template(String(decoding: source, as: UTF8.self),
            with: .init(lstripBlocks: true, trimBlocks: true))
        for fixture in corpus.cases {
            let body = try JSONEncoder().encode(fixture.request)
            let remoteInput = try normalized(body)
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            let localInput = try ProviderPromptContractPipeline.normalizedInput(
                prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "glm5_next"),
                request: local.request, modelType: "glm5_next", templateControls: local.templateControls)
            for input in [remoteInput, localInput] {
                let context = MLXLMCommon.JSONValue.object(
                    (input.additionalContext ?? [:]).mapValues { .from($0) })
                #expect(context == fixture.expectedContext)
                var values: [String: Jinja.Value] = [
                    "messages": try .init(any: input.messages),
                    "add_generation_prompt": .boolean(true),
                ]
                if let tools = input.tools { values["tools"] = try .init(any: tools) }
                for (key, value) in input.additionalContext ?? [:] {
                    values[key] = try .init(any: value)
                }
                let rendered = try template.render(values)
                #expect(Data(rendered.utf8) == Data(fixture.rendered.utf8), "\(fixture.id)")
                #expect(sha(Data(rendered.utf8)) == fixture.renderedSHA256, "\(fixture.id)")
                #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: rendered) == "<think>")
            }
        }
    }

    @Test func exactFamilySelectionDoesNotFollowUserModelNames() {
        for type in ["glm5_next", "glm5_next_text", "glm5_next_mtp"] {
            #expect(GLM5NextPromptPolicy.applies(modelType: type))
        }
        for type: String? in [nil, "glm5", "glm4", "glm5_next_vision", "GLM5_NEXT", " glm5_next"] {
            #expect(!GLM5NextPromptPolicy.applies(modelType: type))
        }
    }

    @Test func effortAndClearThinkingHaveDistinctSemantics() throws {
        let request = OpenAIChatCompletionRequest(model: "not-registered", messages: [])
        for effort in ["low", "high", "max"] {
            for clear in [false, true] {
                let context = try GLM5NextPromptPolicy.additionalContext(request: request,
                    controls: .init(reasoningEffort: effort, clearThinking: clear))
                #expect(context["reasoning_effort"] as? String == effort)
                #expect(context["clear_thinking"] as? Bool == clear)
                #expect(context["enable_thinking"] == nil)
                #expect(context["preserve_thinking"] == nil)
            }
        }
        for effort in ["none", "off", "0", "medium", "xhigh", "LOW", " low", ""] {
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.additionalContext(request: request,
                    controls: .init(reasoningEffort: effort))
            }
        }
        for enabled in [false, true] {
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.additionalContext(request: request,
                    controls: .init(enableThinking: enabled))
            }
        }
    }

    @Test func malformedAndShadowedRawControlsFailClosed() throws {
        let controls: [[String: Any]] = [
            ["reasoning_effort": NSNull()], ["reasoning_effort": false], ["reasoning_effort": "medium"],
            ["clear_thinking": NSNull()], ["clear_thinking": 0], ["clear_thinking": "false"],
            ["enable_thinking": false], ["preserve_thinking": true],
            ["reasoning": ["enabled": true]], ["reasoning": NSNull()],
            ["reasoning": ["effort": "high"], "reasoning_effort": "low "],
            ["chat_template_kwargs": ["clear_thinking": true, "enable_thinking": false]],
            ["clear_thinking": false, "chat_template_kwargs": ["clear_thinking": "true"]],
            ["chat_template_kwargs": ["unrecognized": true]],
        ]
        for var body in controls {
            body["model"] = "fixture-glm5-not-registered"
            body["messages"] = [["role": "user", "content": "Hello."]]
            let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self,
                from: JSONSerialization.data(withJSONObject: body))
            #expect(evidence.invalid)
            #expect(throws: (any Error).self) { try evidence.validate() }
        }
    }

    @Test func precedenceValidatesEveryAliasAndDateCaptureRetainsEvidence() throws {
        let body = Data(#"{"model":"m","messages":[],"reasoning":{"effort":"high"},"reasoning_effort":"low","clear_thinking":false,"chat_template_kwargs":{"reasoning_effort":"max","clear_thinking":true}}"#.utf8)
        let (request, controls) = try requestAndControls(body)
        let captured = controls.resolvingPromptDate(at: Date(timeIntervalSince1970: 0))
        #expect(captured.rawGLM5Controls == controls.rawGLM5Controls)
        let context = try GLM5NextPromptPolicy.additionalContext(request: request, controls: captured)
        #expect(context["reasoning_effort"] as? String == "high")
        #expect(context["clear_thinking"] as? Bool == false)
    }

    @Test func modesDoNotAdvertiseConstrainedDecodingFromInstructions() throws {
        let tool = OpenAITool(function: .init(name: "ping", parameters: .object([
            "type": .string("object"), "properties": .object([:]),
        ])))
        for choice: OpenAIToolChoice in [.mode(.required), .function(name: "ping")] {
            let request = OpenAIChatCompletionRequest(model: "m", messages: [], tools: [tool], toolChoice: choice)
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.normalizedTextInput(request: request,
                    prepared: ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next"), controls: .init())
            }
        }
        let json = OpenAIChatCompletionRequest(model: "m", messages: [], responseFormat: .jsonObject())
        #expect(throws: (any Error).self) {
            try GLM5NextPromptPolicy.normalizedTextInput(request: json,
                prepared: ToolChoicePromptPolicy.prepare(json, modelType: "glm5_next"), controls: .init())
        }
        let none = OpenAIChatCompletionRequest(model: "m", messages: [], tools: [tool], toolChoice: .mode(.none), parallelToolCalls: false)
        let prepared = try ToolChoicePromptPolicy.prepare(none, modelType: "glm5_next")
        #expect(!prepared.allowsParallelCalls)
        #expect(try GLM5NextPromptPolicy.normalizedTextInput(request: none, prepared: prepared, controls: .init()).tools == nil)
    }

    @Test func toolHistoryCorrelationIsExactAndArgumentsMustBeObjects() throws {
        func request(id: String, resultID: String, arguments: String = "{}") -> OpenAIChatCompletionRequest {
            .init(model: "m", messages: [
                .init(role: .assistant, content: .null,
                    toolCalls: [.init(id: id, function: .init(name: "f", arguments: arguments))]),
                .init(role: .tool, content: .text("result"), toolCallID: resultID),
            ])
        }
        for candidate in [request(id: "é", resultID: "e\u{301}"), request(id: "a", resultID: "b"),
            request(id: "a", resultID: "a", arguments: "[null]"), request(id: "a", resultID: "a", arguments: "{bad}"),
            request(id: "a", resultID: "a", arguments: "{\"n\":18446744073709551615}"),
            request(id: "a", resultID: "a", arguments: "{\"n\":1,\"n\":2}")] {
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.normalizedTextInput(request: candidate,
                    prepared: ToolChoicePromptPolicy.prepare(candidate, modelType: "glm5_next"), controls: .init())
            }
        }
    }

    @Test func actualModelIdentityRestoresRawSchemasWithoutChangingOtherFamilies() throws {
        let body = Data(#"{"model":"arbitrary","model_type":"glm5_next","messages":[{"role":"user","content":"Hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"allow":true,"flag":{"type":["boolean","null"]},"count":{"type":["integer","null"]},"text":{"type":["string","null"]}}}}}]}"#.utf8)
        // Keep fixture syntax failures separate from normalization failures.
        _ = try JSONSerialization.jsonObject(with: body)
        // The old model-blind decode remains unchanged for all other families.
        let legacy = try ProviderLoop.decodeOpenAIRequest(body)
        let other = try ProviderLoop.decodeOpenAIRequest(body, modelType: "llama")
        let nativeRequest = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        #expect(legacy.tools == other.tools)
        #expect(legacy.tools != nativeRequest.tools)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let native = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(legacy, modelType: "glm5_next"),
            request: legacy, modelType: "glm5_next", templateControls: controls)
        let tools = try #require(native.tools)
        let rendered = try Template("{{ tools | tojson(ensure_ascii=False) }}").render([
            "tools": try Jinja.Value(any: tools)
        ])
        #expect(rendered.contains(#""allow":true"#))
        #expect(rendered.contains(#""type":["boolean","null"]"#))
        #expect(rendered.contains(#""type":["integer","null"]"#))
        #expect(rendered.contains(#""type":["string","null"]"#))
        #expect(!rendered.contains("x-darkbloom-original-boolean-schema"))
    }

    @Test func forgedInternalMarkersFailOnlyAfterActualGLMIdentityIsSelected() throws {
        let body = Data(#"{"model":"not-a-native-grant","model_type":"glm5_next","messages":[{"role":"user","content":"Hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"string","x-darkbloom-original-boolean-schema":true}}}}}]}"#.utf8)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        #expect(controls.rawGLM5Controls.invalid)
        #expect(throws: (any Error).self) {
            try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        }
        #expect(throws: (any Error).self) {
            try ProviderPromptContractPipeline.validateNativeControls(controls, modelType: "glm5_next")
        }
        // Caller model_type is not authority; existing non-GLM decoding and
        // validation retain their old treatment of coordinator-owned markers.
        _ = try ProviderLoop.decodeOpenAIRequest(body, modelType: "llama")
        try ProviderPromptContractPipeline.validateNativeControls(controls, modelType: "llama")
        let propertyName = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"x-darkbloom-original-boolean-schema":{"type":"string"}}}}}]}"#.utf8)
        #expect(!ProviderLoop.extractChatTemplateControls(from: propertyName).rawGLM5Controls.invalid)
    }

    @Test func responsesUsesTheSameCanonicalControlsAndRejectsMalformedAliases() throws {
        let body = Data(#"{"model":"m","input":"Hi","reasoning":{"effort":"high"},"clear_thinking":true}"#.utf8)
        let local = try JSONDecoder().decode(LocalResponseRequest.self, from: body)
        let chat = local.request.chatCompletionRequest
        let input = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(chat, modelType: "glm5_next"),
            request: chat, modelType: "glm5_next", templateControls: local.templateControls)
        #expect(input.additionalContext?["reasoning_effort"] as? String == "high")
        #expect(input.additionalContext?["clear_thinking"] as? Bool == true)
        let malformed = Data(#"{"model":"m","input":"Hi","reasoning":{"effort":"high"},"clear_thinking":"true"}"#.utf8)
        let invalid = try JSONDecoder().decode(LocalResponseRequest.self, from: malformed)
        #expect(throws: (any Error).self) {
            try ProviderPromptContractPipeline.validateNativeControls(invalid.templateControls, modelType: "glm5_next")
        }
        try ProviderPromptContractPipeline.validateNativeControls(invalid.templateControls, modelType: "llama")
    }

    @Test func exactLargeSchemaNumbersArePreservedOrRejectedBeforeRounding() throws {
        let exact = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"n":{"type":"integer","enum":[9223372036854775807]}}}}}]}"#.utf8)
        let input = try normalized(exact)
        let rendered = try Template("{{ tools | tojson(ensure_ascii=False) }}").render([
            "tools": try Jinja.Value(any: input.tools)
        ])
        #expect(rendered.contains("9223372036854775807"))
        let inexact = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"n":{"type":"integer","enum":[18446744073709551615]}}}}}]}"#.utf8)
        #expect(throws: (any Error).self) { try normalized(inexact) }
    }
}
