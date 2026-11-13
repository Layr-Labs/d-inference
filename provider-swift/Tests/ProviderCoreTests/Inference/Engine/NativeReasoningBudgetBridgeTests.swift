// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import MLXLMServer
import NIOCore
import NIOFoundationCompat
import Testing
import XCTest
@testable import ProviderCore

private struct BudgetBridgeTokenizer: MLXLMCommon.Tokenizer {
    var promptToken = 0
    var splitsClose = false
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        switch text {
        case "<think>": return [14]
        case "</think>": return splitsClose ? [7, 8] : [8]
        default: return [promptToken]
        }
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { convertIdToToken($0)! }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        switch token { case "<think>": return 14; case "</think>": return 8; default: return nil }
    }
    func convertIdToToken(_ id: Int) -> String? {
        switch id { case 14: return "<think>"; case 8: return "</think>"; default: return "t\(id)" }
    }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [promptToken] }
}

/// XCTest runs separately from Swift Testing. The raw-ingress flag is restored
/// after each case; the native engine's capability is explicit and immutable.
final class NativeReasoningBudgetIngressTests: XCTestCase {
    private let flag = "DARKBLOOM_NATIVE_REASONING_BUDGET"
    private var previous: String?

    override func setUp() {
        super.setUp()
        previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
    }

    override func tearDown() {
        if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        super.tearDown()
    }

    private func bridge(model: String, tokenizer: BudgetBridgeTokenizer,
                        enabled: Bool = true) -> EngineV2Bridge {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 1)]
        let engine = EngineV2(model: BudgetBridgeModel(), layerKinds: kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            reasoningBudgetsEnabled: enabled)
        return EngineV2Bridge(engine: engine, modelId: model,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], extraEOSTokens: [],
            defaultMaxTokens: 6, maxConcurrentRequests: 2)
    }

    private func collect(_ stream: AsyncStream<GenerationEvent>) async
        -> (text: String, completion: Int?, errors: [String]) {
        var result = (text: "", completion: Optional<Int>.none, errors: [String]())
        for await event in stream {
            switch event {
            case .chunk(let text): result.text += text
            case .info(_, let count, _, _): result.completion = count
            case .error(let message): result.errors.append(message)
            case .terminal: result.errors.append("unexpected abort")
            case .logprobs: break
            }
        }
        return result
    }

    func testSuperRawBudgetControlsTheActualGeneratedTokens() async throws {
        let model = NemotronSuperLocalBinding.modelID
        let bridge = bridge(model: model, tokenizer: .init())
        for (budget, expected) in [(1, "t1</think>t9t10t11t12"),
                                   (2, "t1t2</think>t9t10t11"),
                                   (3, "t1t2t3</think>t9t10")] {
            let body = Data("""
            {"model":"\(model)","messages":[{"role":"user","content":"Hello"}],
             "reasoning":{"max_tokens":\(budget)},"max_tokens":6,"temperature":0}
            """.utf8)
            let plan = try NemotronSuperRequestPlan(body: body)
            let result = await collect(await bridge.submitTokenized(promptTokens: [0],
                request: plan.bridgeRequest, cacheEnabled: false))
            XCTAssertTrue(result.errors.isEmpty)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.completion, 6)
        }
        await bridge.shutdown()
    }

    func testMiMoHTTPChatAndResponsesPreserveNThroughTheRealScheduler() async throws {
        // The ON prompt ends outside thought. The deterministic model emits
        // opener14, payload15/0, forced close8, then answer9/10: six tokens.
        let tokenizer = BudgetBridgeTokenizer(promptToken: 13)
        let bridge = bridge(model: "budget-mimo", tokenizer: tokenizer)
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "budget-fixture"),
            defaultMaxTokens: 6,
            acquire: { model in
                .init(tokenizer: TokenizerHandle(tokenizer),
                    releaseToken: .init(release: { _ in }, modelId: model),
                    modelType: "mimo_v2", engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(tokenizer: TokenizerHandle(tokenizer), modelType: "mimo_v2") },
            availableModels: { ["budget-mimo"] }, mtpSlots: { [] })
        try await app.test(.router) { client in
            for responses in [false, true] {
                for (budget, expectedThought, expectedAnswer) in [
                    (1, "t15", "t9t10t11"), (2, "t15t0", "t9t10"), (3, "t15t0t1", "t9")
                ] {
                    let input = responses ? #""input":"Hello","max_output_tokens":6"#
                        : #""messages":[{"role":"user","content":"Hello"}],"max_tokens":6"#
                    let body = Data("""
                    {"model":"budget-mimo",\(input),"reasoning":{"max_tokens":\(budget)},"temperature":0}
                    """.utf8)
                    try await client.execute(uri: responses ? "/v1/responses" : "/v1/chat/completions",
                        method: .post, headers: [.contentType: "application/json", .authorization: "Bearer budget-fixture"],
                        body: ByteBuffer(bytes: body)) { result in
                        XCTAssertEqual(result.status, .ok, String(buffer: result.body))
                        let bytes = Data(buffer: result.body)
                        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
                        XCTAssertEqual(usage[responses ? "output_tokens" : "completion_tokens"] as? Int, 6)
                        if responses {
                            let response = try JSONDecoder().decode(OpenAIResponse.self, from: bytes)
                            XCTAssertEqual(response.outputText, expectedAnswer)
                            XCTAssertEqual(response.output.filter { $0.type == "reasoning" }
                                .flatMap { $0.summary ?? [] }.map(\.text).joined(), expectedThought)
                        } else {
                            let response = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: bytes)
                            let message = try XCTUnwrap(response.choices.first?.message)
                            XCTAssertEqual(message.content.text, expectedAnswer)
                            XCTAssertEqual(message.reasoningContent, expectedThought)
                        }
                    }
                }
            }
        }
        await bridge.shutdown()
    }

    func testUnsupportedEngineAndSplitMarkerRefuseBeforeOutput() async throws {
        for (enabled, tokenizer) in [(false, BudgetBridgeTokenizer()),
                                      (true, BudgetBridgeTokenizer(splitsClose: true))] {
            let bridge = bridge(model: "budget-refusal", tokenizer: tokenizer, enabled: enabled)
            var request = ChatCompletionRequest(model: "budget-refusal", messages: [], temperature: 0, max_tokens: 6)
            request.nativeReasoningBudget = .init(maximumTokens: 2, family: .nemotronSuper)
            let result = await collect(await bridge.submitTokenized(promptTokens: [0], request: request, cacheEnabled: false))
            XCTAssertEqual(result.text, "")
            XCTAssertFalse(result.errors.isEmpty)
            XCTAssertNil(result.completion)
            await bridge.shutdown()
        }
    }

    func testUntrustedWireCannotSetOrRoundTripTheInternalBudget() throws {
        let data = Data(#"{"model":"fixture","messages":[],"max_tokens":7,"seed":23,"min_p":0.2,"nativeReasoningBudget":{"maximumTokens":2,"family":"nemotronSuper"}}"#.utf8)
        var decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        XCTAssertNil(decoded.nativeReasoningBudget)
        decoded.nativeReasoningBudget = .init(maximumTokens: 2, family: .nemotronSuper)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["nativeReasoningBudget"])
        let roundTrip = try JSONDecoder().decode(ChatCompletionRequest.self, from: encoded)
        XCTAssertEqual(roundTrip.max_tokens, 7)
        XCTAssertEqual(roundTrip.seed, 23)
        XCTAssertEqual(roundTrip.min_p, 0.2)
        XCTAssertNil(roundTrip.nativeReasoningBudget)
    }
}

private final class BudgetBridgeModel: CBv2SteppableModel {
    let transitions = MLXArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0])
    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        let kv = broadcast(tokens.asType(.float32).reshaped([tokens.dim(0), 1, tokens.dim(1), 1]),
                           to: [tokens.dim(0), 1, tokens.dim(1), 64])
        for cache in caches {
            _ = cache.updateAndAttend(queries: kv, keys: kv, values: kv, scale: 1, sinks: nil)
        }
        return take(eye(16), take(transitions, tokens, axis: 0), axis: 0)
    }
}

@Suite("Native reasoning budget through the provider bridge", .serialized)
struct NativeReasoningBudgetBridgeTests {
    @Test("The real bridge closes at N and continues the same native request")
    func closesAtBudget() async throws {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 1)]
        let tokenizer = BudgetBridgeTokenizer()
        let engine = EngineV2(model: BudgetBridgeModel(), layerKinds: kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            reasoningBudgetsEnabled: true)
        let bridge = EngineV2Bridge(engine: engine, modelId: "super-budget-fixture",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], extraEOSTokens: [],
            defaultMaxTokens: 6, maxConcurrentRequests: 2)
        var request = ChatCompletionRequest(model: "super-budget-fixture", messages: [],
            temperature: 0, max_tokens: 6)
        request.nativeReasoningBudget = NativeReasoningBudget(maximumTokens: 2, family: .nemotronSuper)
        let stream = await bridge.submitTokenized(promptTokens: [0], request: request, cacheEnabled: false)
        var text = ""
        var completion: Int?
        var errors: [String] = []
        for await event in stream {
            switch event {
            case .chunk(let value): text += value
            case .info(_, let count, _, _): completion = count
            case .error(let message): errors.append(message)
            case .terminal: errors.append("unexpected abort")
            case .logprobs: break
            }
        }
        await bridge.shutdown()
        #expect(errors.isEmpty)
        #expect(text == "t1t2</think>t9t10t11")
        #expect(completion == 6)
    }
}
