import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// GPT-OSS renders each tool's parameters from the body's own declaration
/// without the repair's render types (`GPTOSSToolSchemaRender`): its Harmony
/// template prints a `type` list as `a | b`, a `oneOf` as a union and a node
/// without a type as `any`. A body whose tools arrive repaired renders as
/// before; a coordinator request whose render changed is served cold.
@Suite("GPT-OSS tool schema render")
struct GPTOSSToolSchemaRenderTests {
    /// A chat body offering tool `f` with `schema` as its one required
    /// parameter `value`.
    private static func body(_ schema: Any, model: String = "gpt-oss-20b") throws -> Data {
        try body(parameters: ["type": "object", "properties": ["value": schema], "required": ["value"]], model: model)
    }

    private static func body(parameters: Any, model: String = "gpt-oss-20b") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "Go."]],
            "tools": [["type": "function", "function": ["name": "f", "description": "d", "parameters": parameters]]],
        ] as [String: Any])
    }

    /// `body` as today's coordinator forwards it: its tools already repaired.
    private static func repaired(_ body: Data) -> Data {
        ToolSchemaNormalization.ensureParameterTypes(in: body)
    }

    private static func template() throws -> Template {
        let url = try #require(Bundle.module.url(
            forResource: "chat_template", withExtension: "jinja", subdirectory: "Fixtures/GPTOSS"))
        return try Template(String(contentsOf: url, encoding: .utf8), with: .init(lstripBlocks: true, trimBlocks: true))
    }

    private static func render(_ template: Template, _ input: ProviderPromptContractPipeline.NormalizedInput) throws
        -> String
    {
        var context: [String: Jinja.Value] = [
            "messages": try Jinja.Value(any: input.messages),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = try Jinja.Value(any: tools) }
        for (key, value) in input.additionalContext ?? [:] {
            context[key] = try (value as? Jinja.Value) ?? Jinja.Value(any: value)
        }
        return try template.render(context)
    }

    /// The GPT-OSS prompt the serving path renders for `body` on the
    /// coordinator route (ingress repair, controls from the same bytes), and
    /// the prompt it rendered before: the same input with the repaired tools.
    private static func prompts(_ body: Data, template: Template) throws -> (served: String, before: String) {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let prepared = try ToolChoicePromptPolicy.prepare(
            request, modelType: "gpt_oss", allowInternalSchemaMetadata: true)
        let input = try ProviderPromptContractPipeline.templateInput(
            prepared: prepared, request: request, modelType: "gpt_oss", templateControls: controls)
        let before = ProviderPromptContractPipeline.NormalizedInput(
            messages: input.messages,
            tools: ChatTemplateFixes.normalizeTools(
                prepared.tools?.map { $0.toolSpec() }, context: .init(modelId: request.model, modelType: "gpt_oss")),
            additionalContext: input.additionalContext)
        return (try render(template, input), try render(template, before))
    }

    /// The type the prompt shows for parameter `value`.
    private static func valueType(_ prompt: String) throws -> String {
        let start = try #require(prompt.range(of: "\nvalue: "), "\(prompt)")
        let end = try #require(prompt.range(of: ",\n}) => any;", range: start.upperBound..<prompt.endIndex), "\(prompt)")
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    /// Declarations the repair types with one of their members or `string`,
    /// and what GPT-OSS's template shows for them as written.
    private static var unionsAndTypeless: [(schema: Any, written: String, repaired: String)] {
        [
            (["type": ["string", "integer"]] as [String: Any], "string | integer", "string"),
            (["type": ["integer", "string", "null"]] as [String: Any], "integer | string | null", "number"),
            ([String: Any](), "any", "string"),
            (true, "any", "string"),
            (["anyOf": [["type": "string"], ["type": "number"]]] as [String: Any], "any", "string"),
            (["description": "d"] as [String: Any], "any", "string"),
        ]
    }

    @Test("a type list, a union of several types and a node without a type render as written")
    func unionsAndTypelessNodesRenderAsWritten() throws {
        let template = try Self.template()
        for (schema, written, repaired) in Self.unionsAndTypeless {
            let body = try Self.body(schema)
            let prompts = try Self.prompts(body, template: template)
            #expect(try Self.valueType(prompts.served) == written, "\(schema)")
            #expect(try Self.valueType(prompts.before) == repaired, "\(schema)")
            // Today's coordinator forwards the repaired declaration: unchanged.
            let routed = try Self.prompts(Self.repaired(body), template: template)
            #expect(routed.served == routed.before, "\(schema)")
            #expect(try Self.valueType(routed.served) == repaired, "\(schema)")
        }
    }

    @Test("a oneOf renders as the union of its members")
    func oneOfRendersItsMembers() throws {
        let prompt = try Self.prompts(
            Self.body(["oneOf": [["type": "integer"], ["type": "string"]]]), template: Self.template()).served
        let type = try Self.valueType(prompt)
        #expect(type.contains("number") && type.contains("|") && type.contains("string"), "\(type)")
    }

    @Test("a declaration of one type renders as the repair renders it")
    func singleTypeDeclarationsKeepTheRepairsType() throws {
        let template = try Self.template()
        let single: [[String: Any]] = [
            ["type": ["string", "null"]],
            ["type": ["integer", "null"]],
            ["anyOf": [["type": "string"], ["type": "null"]]],
            ["anyOf": [["type": "integer", "minimum": 0] as [String: Any], ["type": "null"]], "default": NSNull()],
            ["enum": ["a", "b"]],
            ["enum": ["default", "inherit", -1] as [Any]],
            ["type": "object", "properties": ["x": ["type": "string"]]],
            ["items": ["type": "integer"]],
            ["minimum": 1],
        ]
        for schema in single {
            let body = try Self.body(schema)
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let declared = ProviderLoop.extractChatTemplateControls(from: body).declaredTools
            #expect(!GPTOSSToolSchemaRender.changesRender(
                request.tools, declared: declared, modelId: request.model, modelType: "gpt_oss"), "\(schema)")
            let prompts = try Self.prompts(body, template: template)
            #expect(prompts.served == prompts.before, "\(schema)")
        }
    }

    @Test("other families keep the repaired declarations")
    func otherFamiliesAreUnchanged() throws {
        let body = try Self.body(["type": ["string", "integer"]], model: "qwen3.5-9b")
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let declared = ProviderLoop.extractChatTemplateControls(from: body).declaredTools
        for modelType in ["qwen3_5", "gemma4", "glm5_next"] {
            #expect(!GPTOSSToolSchemaRender.changesRender(
                request.tools, declared: declared, modelId: request.model, modelType: modelType))
            #expect(GPTOSSToolSchemaRender.renderedTools(
                request.tools, declared: declared, modelId: request.model, modelType: modelType) == request.tools)
        }
        #expect(GPTOSSToolSchemaRender.changesRender(
            request.tools, declared: declared, modelId: request.model, modelType: "gpt_oss"))
    }

    // MARK: - Today's coordinator

    private static func corpus() throws -> [Any] {
        let url = try #require(Bundle.module.url(
            forResource: "tool-schema-corpus", withExtension: "json", subdirectory: "Fixtures/GPTOSS"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
    }

    @Test("every corpus declaration forwarded repaired renders byte-identically and keeps its cache context")
    func repairedCorpusRendersUnchanged() throws {
        let template = try Self.template()
        let corpus = try Self.corpus()
        #expect(corpus.count == 1_336)
        var rendered = 0
        var changedAsWritten = 0
        for (index, parameters) in corpus.enumerated() {
            let raw = try Self.body(parameters: parameters)
            let routed = Self.repaired(raw)
            guard let request = try? ProviderLoop.decodeOpenAIRequest(routed) else { continue }
            let declared = ProviderLoop.extractChatTemplateControls(from: routed).declaredTools
            #expect(!GPTOSSToolSchemaRender.changesRender(
                request.tools, declared: declared, modelId: request.model, modelType: "gpt_oss"), "corpus[\(index)]")
            let planned = RemotePrefixCacheContext(cacheScope: "scope", cacheReceiptNonce: "nonce")
            let served = GPTOSSToolSchemaCache.servingContext(
                planned, for: request, declared: declared, modelType: "gpt_oss")
            #expect(!served.servedCold && served.context.scope == "scope", "corpus[\(index)]")
            // Byte-identical prompts, or the same refusal.
            switch (Result { try Self.prompts(routed, template: template) }) {
            case .success(let prompts):
                #expect(prompts.served == prompts.before, "corpus[\(index)]")
                rendered += 1
            case .failure:
                break
            }
            // As written, the render never fails where the repaired one renders.
            if case .success(let before) = Result(catching: { try Self.prompts(raw, template: template).before }) {
                let served = try Self.prompts(raw, template: template).served
                if served != before { changedAsWritten += 1 }
            }
        }
        #expect(rendered > corpus.count / 2)
        #expect(changedAsWritten > 0)
    }

    // MARK: - Auto tool grammar

    @Test("under the auto tool grammar {} stays free and a union admits each of its members")
    func autoGrammarKeepsAnythingFreeAndUnionsWhole() throws {
        typealias A = GPTOSSAutoFixture
        typealias F = GPTOSSForcedFixture
        func tool(_ name: String, _ schema: Any) -> [String: Any] {
            A.tool(name, ["type": "object", "properties": ["v": schema], "required": ["v"]])
        }
        // The declarations as the body sends them; the prompt's tools are
        // the ingress repair's, as on the coordinator route.
        let tools = [
            tool("anything", [String: Any]()),
            tool("adjust", ["type": ["string", "integer"]]),
            tool("pick", ["oneOf": [["type": "integer"], ["type": "string"]]]),
            tool("either", ["anyOf": [["type": "string"], ["type": "boolean"]]]),
        ]
        let constraint = try A.constraint(tools: tools)
        #expect(!constraint.constrainsArguments(of: "anything"))
        let values: [(String, [String])] = [
            ("anything", ["-0.75", "[1,2]", #"{"a":null}"#, "true", "null", #""x""#]),
            ("adjust", ["-4200", #""-4200""#]),
            ("pick", ["7", #""seven""#]),
            ("either", ["false", #""no""#]),
        ]
        for (name, arguments) in values {
            let header = try #require(A.walk(F.analysis("x") + F.call(name, ""), constraint), "\(name)")
            for value in arguments {
                let state = try #require(A.walk("{\"v\":\(value)}", constraint, from: header), "\(name) \(value)")
                #expect(constraint.nextState(state: state, tokenID: HarmonyByteTestTokenizer.call) == -1,
                        "\(name) \(value)")
            }
        }
    }

    // MARK: - Serving

    @Test("a coordinator request whose GPT-OSS render changed is served cold; others keep their context")
    func changedRenderIsServedCold() throws {
        let planned = RemotePrefixCacheContext(cacheScope: "scope", cacheReceiptNonce: "nonce")
        let raw = try Self.body(["type": ["string", "integer"]])
        for (body, cold) in [(raw, true), (Self.repaired(raw), false)] {
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let declared = ProviderLoop.extractChatTemplateControls(from: body).declaredTools
            let served = GPTOSSToolSchemaCache.servingContext(
                planned, for: request, declared: declared, modelType: "gpt_oss")
            #expect(served.servedCold == cold)
            #expect(served.context.scope == (cold ? nil : "scope"))
            #expect(served.context.receiptNonce == (cold ? nil : "nonce"))
            // A request without a plan has nothing to skip.
            let unplanned = RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil)
            #expect(!GPTOSSToolSchemaCache.servingContext(
                unplanned, for: request, declared: declared, modelType: "gpt_oss").servedCold)
        }
        // Another family keeps its plan, with the caller's tools or repaired
        // ones. The family is the build's (model id and model type, as the
        // Harmony template path selects it), so its own id is used here.
        for (modelId, modelType) in [("qwen3.5-9b", "qwen3_5"), ("qwen3.6-35b-a3b", "qwen3_5_moe"),
                                     ("gemma-4-26b", "gemma4"), ("nvidia-nemotron-3.5-lightning", "nemotron_h")] {
            let original = try Self.body(["type": ["string", "integer"]], model: modelId)
            for body in [original, Self.repaired(original)] {
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                let declared = ProviderLoop.extractChatTemplateControls(from: body).declaredTools
                let served = GPTOSSToolSchemaCache.servingContext(
                    planned, for: request, declared: declared, modelType: modelType)
                #expect(!served.servedCold && served.context.scope == "scope", "\(modelType)")
            }
        }
    }

    @Test("the local API renders the declarations as written")
    func localAPIRendersAsWritten() throws {
        let template = try Self.template()
        for (schema, written, _) in Self.unionsAndTypeless {
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: Self.body(schema))
            let prepared = try ToolChoicePromptPolicy.prepare(local.request, modelType: "gpt_oss")
            let input = try ProviderPromptContractPipeline.templateInput(
                prepared: prepared, request: local.request, modelType: "gpt_oss",
                templateControls: local.templateControls)
            #expect(try Self.valueType(Self.render(template, input)) == written, "\(schema)")
        }
    }

    @Test("the template utility renders GPT-OSS tools as the served prompt does")
    func applyTemplateRendersTheSameTools() async throws {
        let tokenizer = ToolCapturingTokenizer()
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId) },
            tokenizerProvider: { _ in .init(tokenizer: TokenizerHandle(tokenizer), modelType: "gpt_oss") },
            availableModels: { ["gpt-oss-20b"] })
        // The served prompt's tools for each declaration, against what the
        // template utility renders for the same body.
        let schemas: [Any] = [
            ["type": ["string", "integer"]], ["type": ["integer", "null"]], true, [String: Any](),
            ["anyOf": [["type": "string"], ["type": "null"]]],
        ]
        for schema in schemas {
            let body = try Self.body(schema)
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            let served = try ProviderPromptContractPipeline.templateInput(
                prepared: prepared, request: request, modelType: "gpt_oss", templateControls: controls).tools
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            _ = try await engine.applyTemplate(.init(
                model: "gpt-oss-20b", messages: local.request.messages, tools: local.request.tools))
            let utility = try #require(tokenizer.tools)
            #expect(try Jinja.Value(any: utility) == Jinja.Value(any: served ?? []), "\(schema)")
        }
    }

    @Test("the template utility gives Gemma the served prompt's tools")
    func applyTemplateGivesGemmaTheServedTools() async throws {
        let tokenizer = ToolCapturingTokenizer()
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId) },
            tokenizerProvider: { _ in .init(tokenizer: TokenizerHandle(tokenizer), modelType: "gemma4") },
            availableModels: { ["gemma-4-26b"] })
        // A property declared without a type renders untyped (invariant 8),
        // which needs the declarations; a typed one keeps its type.
        let schemas: [(Any, String)] = [([String: Any](), ""), (["description": "d"] as [String: Any], ""),
                                        (["type": "integer"], "integer")]
        for (schema, renderType) in schemas {
            let body = try Self.body(schema, model: "gemma-4-26b")
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
            let served = try ProviderPromptContractPipeline.templateInput(
                prepared: prepared, request: request, modelType: "gemma4", templateControls: controls).tools
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            _ = try await engine.applyTemplate(.init(
                model: "gemma-4-26b", messages: local.request.messages, tools: local.request.tools))
            // The render type Gemma's template prints for `value`.
            func valueType(_ tools: [[String: any Sendable]]?) -> String? {
                let function = tools?.first?["function"] as? [String: any Sendable]
                let parameters = function?["parameters"] as? [String: any Sendable]
                let value = (parameters?["properties"] as? [String: any Sendable])?["value"] as? [String: any Sendable]
                return value?["type"] as? String
            }
            #expect(valueType(served) == renderType, "\(schema)")
            #expect(valueType(tokenizer.tools) == renderType, "\(schema)")
        }
    }

    @Test("the prompt-token floor counts the prompt served")
    func promptTokenFloorRendersTheSameTools() throws {
        let body = try Self.body(["type": ["string", "integer"]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        let rendered = try #require(GPTOSSToolSchemaRender.renderedTools(
            prepared.tools, declared: controls.declaredTools, modelId: request.model, modelType: "gpt_oss"))
        let types = rendered.compactMap { tool -> MLXLMCommon.JSONValue? in
            guard case .object(let parameters)? = tool.function.parameters,
                case .object(let properties)? = parameters["properties"]
            else { return nil }
            return properties["value"]
        }
        #expect(types == [.object(["type": .array([.string("string"), .string("integer")])])])
    }
}

/// Records the tools the template is given.
private final class ToolCapturingTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private(set) var tools: [[String: any Sendable]]?

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        self.tools = tools
        return [1]
    }
}
