import CryptoKit
import Foundation
import MLXLMServer
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Production prompt parity")
struct ProductionPromptParityTests {
    @Test("serving tokenizer matches manifest-generated vectors")
    func servingTokenizerVectors() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let vectorsPath = environment["PROMPT_PARITY_VECTORS"],
              let artifactRootPath = environment["PROMPT_PARITY_ARTIFACT_ROOT"]
        else {
            #expect(
                environment["PROMPT_PARITY_REQUIRED"] != "1",
                "production parity gate requires PROMPT_PARITY_VECTORS and PROMPT_PARITY_ARTIFACT_ROOT")
            return
        }
        let corpus = try JSONDecoder().decode(
            Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: vectorsPath)))
        #expect(corpus.schemaVersion == 1)
        #expect(!corpus.models.isEmpty)

        let artifactRoot = URL(fileURLWithPath: artifactRootPath, isDirectory: true)
        var historyNullCases: Set<String> = []
        var toolUnionTypeCases: Set<String> = []
        var toolRawSchemaCases: Set<String> = []
        var forwardingDifferences: Set<String> = []
        for model in corpus.models {
            let modelDirectory = artifactRoot.appendingPathComponent(
                model.promptContractID, isDirectory: true)
            if !model.cacheRoutingEligible {
                #expect(model.ineligibilityReason == "dynamic_time")
                #expect(model.cases.isEmpty)
                #expect(throws: PromptContractIdentity.Error.invalidArtifact) {
                    try PromptContractIdentity.compute(modelDirectory: modelDirectory)
                }
                continue
            }
            #expect(model.ineligibilityReason == nil)
            let actualContract = try PromptContractIdentity.compute(modelDirectory: modelDirectory)
            #expect(actualContract == model.promptContractID,
                    "production cache identity diverged for \(model.modelID)")
            let tokenizer = try await LocalTokenizerLoader().load(
                from: modelDirectory)
            let detectedModelType = ModelScanner.parseConfigJSON(
                at: modelDirectory.appendingPathComponent("config.json")
            ).modelType
            let modelType = model.modelType ?? detectedModelType
            #expect(modelType != nil, "production prompt artifact must identify its model type")
            #expect(!model.cases.isEmpty)
            for fixture in model.cases {
                let providerBody = try JSONSerialization.data(
                    withJSONObject: fixture.providerBody.foundationObject())
                // Exercise the actual service entry point before tokenization: it can
                // inject response-format instructions into the engine request.
                func tokens(_ body: Data) async throws -> [Int] {
                    let request = try ProviderLoop.decodeOpenAIRequest(body)
                    let engine = PromptPreparationCaptureEngine()
                    let frames = try await MLXOpenAIService(engine: engine)
                        .streamChatCompletionFrames(request: request)
                    for try await _ in frames {}
                    let generationRequest = try #require(await engine.request)
                    return try ProviderPromptContractPipeline.tokenize(
                        prepared: ToolChoicePromptPolicy.prepare(generationRequest, modelType: modelType),
                        request: generationRequest,
                        tokenizer: tokenizer,
                        modelType: modelType,
                        templateControls: ProviderLoop.extractChatTemplateControls(from: body)
                            .resolvingPromptDate())
                }
                // Provider-rendered and uncacheable: an earlier tool call's null
                // arguments render here as `null`, while this contract
                // (normalization v9) drops them. Such a body is served without the
                // prompt cache, so no receipt names its prompt; the vectors stay
                // the contract for the same body with those nulls dropped by the
                // production sanitizer.
                // The classification is the serving decision itself.
                let request = try ProviderLoop.decodeOpenAIRequest(providerBody)
                let served = ToolCallHistoryNullCache.servingContext(
                    RemotePrefixCacheContext(cacheScope: fixture.scopeID, cacheReceiptNonce: "parity-" + fixture.id),
                    for: request, modelType: modelType, managedSuper: false)
                // A Gemma tool render type that changed is served cold by the
                // next rule; the vectors stay the contract for the same body
                // with each property declared without a type typed `string`,
                // as the shared repair renders it.
                let declared = ProviderLoop.extractChatTemplateControls(from: providerBody).declaredTools
                let renderTypeChanged = GemmaToolUnionTypeCache.changesRender(
                    request, modelType: modelType, declared: declared)
                if renderTypeChanged {
                    toolUnionTypeCases.insert(model.modelID + "/" + fixture.id)
                    let renderServed = GemmaToolUnionTypeCache.servingContext(
                        served.context, for: request, modelType: modelType, declared: declared)
                    #expect((served.servedCold || renderServed.servedCold) && renderServed.context.receiptNonce == nil
                            && !renderServed.context.cacheEnabled,
                            "\(model.modelID)/\(fixture.id): a changed tool render must be served without the prompt cache")
                    if !served.servedCold {
                        let rendered = try await tokens(providerBody)
                        #expect(rendered != fixture.tokenIDs,
                                "\(model.modelID)/\(fixture.id): the tool render change no longer changes the prompt")
                    }
                }
                // GPT-OSS renders a declaration this contract repairs as
                // written (GPTOSSToolSchemaRender); such a body is served cold,
                // and the vectors stay the contract for its repaired tools.
                let rawSchema = GPTOSSToolSchemaCache.servingContext(
                    RemotePrefixCacheContext(cacheScope: fixture.scopeID, cacheReceiptNonce: "parity-" + fixture.id),
                    for: request,
                    declared: declared, modelType: modelType)
                if rawSchema.servedCold {
                    toolRawSchemaCases.insert(model.modelID + "/" + fixture.id)
                    #expect(rawSchema.context.receiptNonce == nil && rawSchema.context.scope == nil,
                            "\(model.modelID)/\(fixture.id): a changed GPT-OSS tool render must be served cold")
                }
                // The coordinator forwards these tools repaired today and may
                // forward the caller's own: every prompt but an intended,
                // served-cold change is the same for both.
                if request.tools?.isEmpty == false {
                    let original = try await tokens(providerBody)
                    let routed = try await tokens(ToolSchemaNormalization.ensureParameterTypes(in: providerBody))
                    if original != routed {
                        forwardingDifferences.insert(model.modelID + "/" + fixture.id)
                    }
                    #expect(original == routed || rawSchema.servedCold || renderTypeChanged,
                            "\(model.modelID)/\(fixture.id): the original tools render a different prompt")
                }
                var contractBody = served.servedCold ? try Self.v9HistoryArguments(providerBody) : providerBody
                if renderTypeChanged { contractBody = try Self.v9TypedDeclarations(contractBody) }
                if rawSchema.servedCold {
                    contractBody = ToolSchemaNormalization.ensureParameterTypes(in: contractBody)
                }
                if served.servedCold {
                    historyNullCases.insert(model.modelID + "/" + fixture.id)
                    #expect(served.context.receiptNonce == nil && served.context.scope == nil
                            && !served.context.cacheEnabled,
                            "\(model.modelID)/\(fixture.id): a history null must be served without the prompt cache")
                    let rendered = try await tokens(providerBody)
                    #expect(rendered != fixture.tokenIDs,
                            "\(model.modelID)/\(fixture.id): the history null no longer changes the prompt")
                }
                let actual = try await tokens(contractBody)
                let difference = firstDifference(actual, fixture.tokenIDs).map { index in
                    let actualToken = actual.indices.contains(index)
                        ? "\(actual[index]) \(tokenizer.convertIdToToken(actual[index]) ?? "<unknown>")"
                        : "<missing>"
                    let expectedToken = fixture.tokenIDs.indices.contains(index)
                        ? "\(fixture.tokenIDs[index]) \(tokenizer.convertIdToToken(fixture.tokenIDs[index]) ?? "<unknown>")"
                        : "<missing>"
                    return "first difference at \(index): Swift=\(actualToken), Rust=\(expectedToken)"
                } ?? "token arrays differ without an indexed difference"
                #expect(
                    actual == fixture.tokenIDs,
                    "serving tokenizer diverged for \(model.modelID)/\(fixture.id); \(difference)")
                #expect(actual.count == fixture.plan.promptTokenCount)
                let hasher = CBv2BlockHasher(promptContractID: model.promptContractID, scopeID: fixture.scopeID)
                let chains = hasher.chainHashes(tokens: actual, maxBlocks: hasher.maxLookupBlocks(tokenCount: actual.count))
                #expect(chains.map { $0.map { String(format: "%02x", $0) }.joined() } == fixture.plan.blockBoundaries.map(\.chainHash))
                if let first = chains.first {
                    let otherScope = CBv2BlockHasher(promptContractID: model.promptContractID, scopeID: fixture.scopeID + "-other")
                    #expect(first != otherScope.chainHashes(tokens: actual, maxBlocks: 1).first)
                }
            }
        }
        // Exactly the vector bodies whose earlier tool call carries a null.
        #expect(historyNullCases == Self.historyNullCases,
                "provider-rendered cases changed: \(historyNullCases.symmetricDifference(Self.historyNullCases).sorted())")
        // Exactly the Gemma vector bodies whose tool render type changed
        // (GemmaToolUnionTypeCache): a property declared without a type.
        #expect(toolUnionTypeCases == Self.toolUnionTypeCases,
                "Gemma tool-union cases changed: \(toolUnionTypeCases.sorted())")
        // Exactly the GPT-OSS vector bodies with a declaration rendered as
        // written (GPTOSSToolSchemaCache).
        #expect(toolRawSchemaCases == Self.toolRawSchemaCases,
                "GPT-OSS tool-schema cases changed: \(toolRawSchemaCases.symmetricDifference(Self.toolRawSchemaCases).sorted())")
        // Original and repaired tools render apart only in those and the
        // Gemma cases, each served cold.
        let intended = Self.toolRawSchemaCases.union(Self.toolUnionTypeCases)
        #expect(forwardingDifferences.isSubset(of: intended),
                "original tools render apart: \(forwardingDifferences.subtracting(intended).sorted())")
    }

    /// Gemma 4 prompt contracts on the served artifacts: a request that asks
    /// for nothing renders contract 1 (0.10.12, the sidecar's plans), and one
    /// the coordinator asks for contract 2 renders vLLM's prompt. The vectors
    /// are Transformers' chat-template render of the same artifacts
    /// (`gemma4_prompt_contract_vectors.json`).
    @Test("Gemma 4 prompt contract 1 and 2 render the vectors")
    func gemmaPromptContractVectors() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let vectorsPath = environment["PROMPT_PARITY_VECTORS"],
              let artifactRootPath = environment["PROMPT_PARITY_ARTIFACT_ROOT"]
        else {
            #expect(
                environment["PROMPT_PARITY_REQUIRED"] != "1",
                "production parity gate requires PROMPT_PARITY_VECTORS and PROMPT_PARITY_ARTIFACT_ROOT")
            return
        }
        let vectorsURL = URL(fileURLWithPath: vectorsPath)
        let vectors = try JSONDecoder().decode(GemmaPromptContractVectors.self, from: Data(contentsOf:
            vectorsURL.deletingLastPathComponent().appendingPathComponent("gemma4_prompt_contract_vectors.json")))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: vectorsURL))
        let model = try #require(corpus.models.first { $0.modelID == vectors.modelID })
        let modelDirectory = URL(fileURLWithPath: artifactRootPath, isDirectory: true)
            .appendingPathComponent(model.promptContractID, isDirectory: true)
        #expect(Gemma4ToolConstraintContract.templateSHA256(at: modelDirectory) == vectors.templateSHA256)
        let tokenizerFile = try Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer.json"))
        #expect(SHA256.hash(data: tokenizerFile).map { String(format: "%02x", $0) }.joined()
                == vectors.tokenizerSHA256)
        let tokenizer = try await LocalTokenizerLoader().load(from: modelDirectory)
        let modelType = ModelScanner.parseConfigJSON(
            at: modelDirectory.appendingPathComponent("config.json")).modelType
        #expect(modelType == "gemma4")
        #expect(vectors.cases.map(\.id) == [
            "gpqa_string_system", "gpqa_developer_system", "gpqa_list_system_user", "list_parts_whitespace",
            "no_system", "no_system_thinking_off", "system_thinking_off", "tools_string_system",
            "tools_no_system", "tau2_policy", "assistant_list_parts", "later_system_list", "empty_system",
            "null_system", "list_system_tool_required", "list_user_tool_named", "empty_user_tool_required",
            "empty_system_tool_required", "list_system_response_format", "developer_list", "list_empty_parts",
            "null_system_tool_required",
        ])
        let gpqa = try #require(vectors.cases.first)
        #expect(gpqa.contract1TokenIDs.count == 87 && gpqa.contract2TokenIDs.count == 88)
        for fixture in vectors.cases {
            let providerBody = try JSONSerialization.data(
                withJSONObject: fixture.providerBody.foundationObject())
            let request = try ProviderLoop.decodeOpenAIRequest(providerBody)
            let engine = PromptPreparationCaptureEngine()
            let frames = try await MLXOpenAIService(engine: engine)
                .streamChatCompletionFrames(request: request)
            for try await _ in frames {}
            let generationRequest = try #require(await engine.request)
            let controls = ProviderLoop.extractChatTemplateControls(from: providerBody).resolvingPromptDate()
            func tokens(contract: Int?, promptCacheScope: String? = nil) throws -> [Int] {
                try ProviderPromptContractPipeline.tokenize(
                    prepared: ToolChoicePromptPolicy.prepare(generationRequest, modelType: modelType),
                    request: generationRequest,
                    tokenizer: tokenizer,
                    modelType: modelType,
                    templateControls: controls.askingGemmaPromptContract(contract, enabled: true),
                    promptCacheScope: promptCacheScope)
            }
            let contract1 = try tokens(contract: nil)
            let contract2 = try tokens(contract: 2)
            #expect(try tokens(contract: 1) == contract1, "\(fixture.id): asking for contract 1 changed the render")
            // Planned requests, the ones that ask for contract 2, render through
            // the prompt-token cache: the same tokens cold and warm, one scope
            // shared by both contracts.
            let scope = "gemma-prompt-contract-parity-" + fixture.id
            for _ in 0..<2 {
                #expect(try tokens(contract: nil, promptCacheScope: scope) == contract1,
                        "\(fixture.id): the prompt-token cache changed contract 1")
                #expect(try tokens(contract: 2, promptCacheScope: scope) == contract2,
                        "\(fixture.id): the prompt-token cache changed contract 2")
            }
            if fixture.providerMatchesTransformers {
                #expect(contract1 == fixture.contract1TokenIDs,
                        "\(fixture.id): contract 1 \(contract1.count) tokens, vectors \(fixture.contract1TokenIDs.count); first difference at \(firstDifference(contract1, fixture.contract1TokenIDs) ?? -1)")
                #expect(contract2 == fixture.contract2TokenIDs,
                        "\(fixture.id): contract 2 \(contract2.count) tokens, vectors \(fixture.contract2TokenIDs.count); first difference at \(firstDifference(contract2, fixture.contract2TokenIDs) ?? -1)")
            }
            // Contract 2 against the provider's own contract 1: no change, or
            // the one token the parts add where the vectors' two renders first differ.
            // Where contract 2 changes the vectors' render in more than one
            // place, the provider is checked against the vectors alone.
            switch firstDifference(fixture.contract1TokenIDs, fixture.contract2TokenIDs) {
            case nil:
                #expect(contract2 == contract1, "\(fixture.id): contract 2 differs from contract 1")
            case let index? where fixture.contract2TokenIDs.count == fixture.contract1TokenIDs.count + 1
                && Self.inserting(fixture.contract2TokenIDs[index], into: fixture.contract1TokenIDs, at: index)
                    == fixture.contract2TokenIDs:
                let expected = Self.inserting(fixture.contract2TokenIDs[index], into: contract1, at: index)
                #expect(Array(contract1.prefix(index)) == Array(fixture.contract1TokenIDs.prefix(index)),
                        "\(fixture.id): contract 1 differs from the vectors before contract 2's token")
                #expect(contract2 == expected,
                        "\(fixture.id): contract 2 is not contract 1 plus the token at \(index); first difference at \(firstDifference(contract2, expected) ?? -1)")
            default:
                #expect(fixture.providerMatchesTransformers, "\(fixture.id): checked only against the vectors")
            }
        }
    }
}

extension ProductionPromptParityTests {
    /// The vector bodies (model × case) whose earlier tool call carries a JSON
    /// null: provider-rendered and served without the prompt cache.
    static let historyNullCases: Set<String> = Set(
        ["EigenLabs/Qwen3.8-27B-4bit-mtp", "gemma-4-26b", "gemma-4-26b-8bit", "gemma-4-26b-qat-4bit",
         "gpt-oss-20b", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"].flatMap { model in
            ["endpoint_messages_tool_turn", "gemma_tool_turn"].map { model + "/" + $0 }
        })

    /// The vector bodies whose Gemma tool render type changed: the Gemma
    /// models' bodies that declare a property without a type (`city: {}`).
    static let toolUnionTypeCases: Set<String> = Set(
        ["gemma-4-26b", "gemma-4-26b-8bit", "gemma-4-26b-qat-4bit"].flatMap { model in
            ["endpoint_messages_tool_turn", "tools"].map { model + "/" + $0 }
        })

    /// `body` with every tool property declared without a type
    /// (`Gemma4ToolSchemaEnforcement.declaresAnyValue`) typed `string`, as the
    /// shared repair renders it under the v9 contract.
    private static func v9TypedDeclarations(_ body: Data) throws -> Data {
        func typed(_ node: [String: Any]) -> [String: Any] {
            var node = node
            if var properties = node["properties"] as? [String: Any] {
                for (key, value) in properties {
                    guard var property = value as? [String: Any] else { continue }
                    if Gemma4ToolSchemaEnforcement.declaresAnyValue(property) {
                        property["type"] = "string"
                    } else {
                        property = typed(property)
                    }
                    properties[key] = property
                }
                node["properties"] = properties
            }
            if let items = node["items"] as? [String: Any] { node["items"] = typed(items) }
            return node
        }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = object["tools"] as? [Any]
        else { return body }
        object["tools"] = tools.map { tool -> Any in
            guard var tool = tool as? [String: Any], var function = tool["function"] as? [String: Any],
                  let parameters = function["parameters"] as? [String: Any]
            else { return tool }
            function["parameters"] = typed(parameters)
            tool["function"] = function
            return tool
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The vector bodies whose GPT-OSS tool render changed: those declaring
    /// a parameter without a type (`{}`, a description alone).
    static let toolRawSchemaCases: Set<String> = Set(
        ["endpoint_messages_tool_turn", "gemma_tool_turn", "tools"].map { "gpt-oss-20b/" + $0 })

    /// `body` with each earlier tool call's arguments object passed through the
    /// production drop policy (`sanitizeForJinja`, which the v9 contract applies
    /// to them): the prompt the vectors were made for.
    private static func v9HistoryArguments(_ body: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [Any]
        else { return body }
        object["messages"] = try messages.map { message -> Any in
            guard var message = message as? [String: Any], let calls = message["tool_calls"] as? [Any] else {
                return message
            }
            message["tool_calls"] = try calls.map { call -> Any in
                guard var call = call as? [String: Any], var function = call["function"] as? [String: Any],
                      let raw = function["arguments"] as? String,
                      let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                      let dropped = sanitizeForJinja(arguments) as? [String: Any]
                else { return call }
                function["arguments"] = String(
                    decoding: try JSONSerialization.data(withJSONObject: dropped), as: UTF8.self)
                call["function"] = function
                return call
            }
            return message
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// `tokens` with `token` inserted at `index` (at the end when past it).
    private static func inserting(_ token: Int, into tokens: [Int], at index: Int) -> [Int] {
        var result = tokens
        result.insert(token, at: min(index, result.count))
        return result
    }
}

private struct GemmaPromptContractVectors: Decodable {
    let modelID: String
    let templateSHA256: String
    let tokenizerSHA256: String
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let providerBody: JSONValue
        let contract1TokenIDs: [Int]
        let contract2TokenIDs: [Int]
        /// False where the provider's render of the body already differs
        /// from Transformers' for another reason (the Tau2 body's `$ref`
        /// tool declarations, which the coordinator inlines in production).
        let providerMatchesTransformers: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case providerBody = "provider_body"
            case contract1TokenIDs = "contract_1_token_ids"
            case contract2TokenIDs = "contract_2_token_ids"
            case providerMatchesTransformers = "provider_matches_transformers"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            providerBody = try container.decode(JSONValue.self, forKey: .providerBody)
            contract1TokenIDs = try container.decode([Int].self, forKey: .contract1TokenIDs)
            contract2TokenIDs = try container.decode([Int].self, forKey: .contract2TokenIDs)
            providerMatchesTransformers = try container.decodeIfPresent(
                Bool.self, forKey: .providerMatchesTransformers) ?? true
        }
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case templateSHA256 = "template_sha256"
        case tokenizerSHA256 = "tokenizer_sha256"
        case cases
    }
}

private func firstDifference(_ left: [Int], _ right: [Int]) -> Int? {
    let commonCount = min(left.count, right.count)
    if let index = (0 ..< commonCount).first(where: { left[$0] != right[$0] }) {
        return index
    }
    return left.count == right.count ? nil : commonCount
}

private struct Corpus: Decodable {
    let schemaVersion: Int
    let models: [Model]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case models
    }
}

private struct Model: Decodable {
    let modelID: String
    let modelType: String?
    let promptContractID: String
    let cacheRoutingEligible: Bool
    let ineligibilityReason: String?
    let cases: [Fixture]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelType = "model_type"
        case promptContractID = "prompt_contract_id"
        case cacheRoutingEligible = "cache_routing_eligible"
        case ineligibilityReason = "ineligibility_reason"
        case cases
    }
}

private struct Fixture: Decodable {
    let id: String
    let scopeID: String
    let providerBody: JSONValue
    let plan: Plan
    let tokenIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case scopeID = "scope_id"
        case providerBody = "provider_body"
        case plan
        case tokenIDs = "token_ids"
    }
}

private struct Plan: Decodable {
    let promptTokenCount: Int
    let blockBoundaries: [Boundary]

    struct Boundary: Decodable {
        let chainHash: String
        enum CodingKeys: String, CodingKey { case chainHash = "chain_hash" }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokenCount = "prompt_token_count"
        case blockBoundaries = "block_boundaries"
    }
}

private enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    func foundationObject() -> Any {
        switch self {
        case .object(let value):
            return value.mapValues { $0.foundationObject() }
        case .array(let value):
            return value.map { $0.foundationObject() }
        case .string(let value):
            return value
        case .integer(let value):
            return value
        case .number(let value):
            return value
        case .boolean(let value):
            return value
        case .null:
            return NSNull()
        }
    }
}

// A model-free engine captures the exact post-service request. No generated
// content, production request, prompt logging or weight loading is involved.
private actor PromptPreparationCaptureEngine: MLXServerEngine {
    var request: OpenAIChatCompletionRequest?
    func availableModels() async throws -> [MLXServerModel] { [] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        self.request = request
        return AsyncThrowingStream { $0.finish() }
    }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        TokenizeResponse(tokens: [])
    }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        DetokenizeResponse(text: "")
    }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        TokenizeResponse(tokens: [])
    }
}
