// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

private struct BudgetBridgeTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        switch text {
        case "<think>": return [14]
        case "</think>": return [8]
        default: return [0]
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
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [0] }
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
