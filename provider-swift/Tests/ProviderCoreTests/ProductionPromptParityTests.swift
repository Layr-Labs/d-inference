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
                let request = try ProviderLoop.decodeOpenAIRequest(providerBody)
                let engine = PromptPreparationCaptureEngine()
                let frames = try await MLXOpenAIService(engine: engine)
                    .streamChatCompletionFrames(request: request)
                for try await _ in frames {}
                let generationRequest = try #require(await engine.request)
                let actual = try ProviderPromptContractPipeline.tokenize(
                    prepared: ToolChoicePromptPolicy.prepare(generationRequest),
                    request: generationRequest,
                    tokenizer: tokenizer,
                    modelType: modelType,
                    templateControls: ProviderLoop.extractChatTemplateControls(from: providerBody)
                        .resolvingPromptDate())
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
