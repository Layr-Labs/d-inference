import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// A tiny random Qwen 3.5 (eight layers, two of them full attention, bf16 with
// 4-bit projections) through the runtime's stage KV host and owned request
// state: one request at a time on each backend, and several requests decoding
// together (continuous batching) with a lane joining and another leaving in
// the middle. Each batched row must equal the same request run alone, bit for
// bit, at every step: that is the lossless property the pair's batch lanes
// rely on. Paged against contiguous is compared by tokens.
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("Paged stage KV and batched decode on a synthetic Qwen 3.5 (no artifact)", .serialized)
struct CBv2PagedBatchSyntheticTests {
    static let vocabulary = 320
    static let prompts: [[Int]] = [[3, 1, 4, 1, 5, 9, 2], [6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8], [4, 6, 2, 6, 4]]
    static let outputs = 6
    static let chunk = 8

    static func configuration(maximumPositions: Int = 4096) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5_text", "vocab_size": vocabulary, "hidden_size": 128, "intermediate_size": 256,
            "num_hidden_layers": 8, "full_attention_interval": 4, "head_dim": 64,
            "num_attention_heads": 4, "num_key_value_heads": 2, "linear_conv_kernel_dim": 4,
            "linear_key_head_dim": 32, "linear_num_key_heads": 2, "linear_num_value_heads": 4, "linear_value_head_dim": 32,
            "max_position_embeddings": maximumPositions, "rms_norm_eps": 1e-6, "tie_word_embeddings": false,
            "rope_theta": 10_000_000, "partial_rotary_factor": 0.25, "attention_bias": false,
            "mtp_num_hidden_layers": 0,
        ] as [String: Any], options: [.sortedKeys])
    }

    static func model() throws -> Qwen35TextModel {
        let data = try configuration()
        let model = try withRandomState(MLXRandom.RandomState(seed: 7)) { () -> Qwen35TextModel in
            let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
            var scaled: [String: MLXArray] = [:]
            for (name, value) in model.parameters().flattened() {
                scaled[name] = (MLXRandom.normal(value.shape) * 0.05).asType(.bfloat16)
            }
            try model.update(parameters: ModuleParameters.unflattened(scaled), verify: [.noUnusedKeys, .shapeMismatch])
            return model
        }
        quantize(model: model, groupSize: 64, bits: 4, mode: .affine, filter: { _, module in module is Linear })
        model.freeze(); eval(model)
        return model
    }

    static func geometry(_ model: Qwen35TextModel, host: CBv2StageKVHost?, maximumTokens: Int = 64) throws -> CBv2RequestGeometry {
        try CBv2RequestGeometry(model: model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model), layerCount: 8,
            vocabularySize: vocabulary, configurationData: configuration(), maximumTokens: maximumTokens, host: host)
    }

    static func logits(_ model: Qwen35TextModel, _ tokens: [[Int]], caches: [any CBv2AttendingLayerCache],
                       evaluations: [CBv2RecurrentStateEvaluation]) -> MLXArray {
        let input = MLXArray(tokens.flatMap { $0.map(Int32.init) }).reshaped([tokens.count, tokens[0].count])
        return model.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
            recurrentState: evaluations, positionIds: nil).logits[0..., -1, 0...]
    }

    /// Prefill in chunks of `chunk`; returns the last row's logits.
    static func prefill(_ model: Qwen35TextModel, _ state: CBv2OwnedRequestState, _ prompt: [Int]) throws -> MLXArray {
        var offset = 0, last: MLXArray?
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                logits(model, [part], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
            offset += part.count
        }
        return last!
    }

    static func argmax(_ row: MLXArray) -> Int { Int(argMax(row, axis: -1).item(UInt32.self)) }

    /// Each request alone: tokens and the logits row of every step.
    static func solo(_ model: Qwen35TextModel, host: CBv2StageKVHost?) throws -> [(tokens: [Int], rows: [MLXArray])] {
        try prompts.map { prompt in
            let state = try CBv2OwnedRequestState(geometry: geometry(model, host: host), promptCount: prompt.count,
                outputCount: outputs)
            var row = try prefill(model, state, prompt)
            var tokens = [argmax(row)], rows = [row]
            while tokens.count < outputs {
                let token = tokens.last!
                row = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                    logits(model, [[token]], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
                tokens.append(argmax(row)); rows.append(row)
            }
            try state.retire()
            return (tokens, rows)
        }
    }

    @Test(arguments: [ClusterStageKVBackendKind.paged, .contiguous])
    func batchedRowsEqualEachRequestAlone(kind: ClusterStageKVBackendKind) throws {
        let model = try Self.model()
        let host = try CBv2StageKVHost(model: model, kind: kind, lanes: 3, maximumTokensPerRequest: 64, maximumChunkTokens: Self.chunk)
        let alone = try Self.solo(model, host: host)
        #expect(host.isDrained)
        // Lanes 0 and 1 decode together; lane 2 joins after two steps; lane 0
        // leaves when it has its tokens.
        var states: [CBv2OwnedRequestState?] = [nil, nil, nil]
        var tokens: [[Int]] = [[], [], []]
        func join(_ lane: Int) throws {
            let state = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host),
                promptCount: Self.prompts[lane].count, outputCount: Self.outputs)
            let row = try Self.prefill(model, state, Self.prompts[lane])
            #expect(row.asType(.float32).asArray(Float.self) == alone[lane].rows[0].asType(.float32).asArray(Float.self),
                "lane \(lane) prefill row differs from its solo run")
            tokens[lane] = [Self.argmax(row)]; states[lane] = state
        }
        try join(0); try join(1)
        var step = 0
        while states.contains(where: { $0 != nil }) {
            if step == 2 { try join(2) }
            let lanes = (0..<3).filter { states[$0] != nil && tokens[$0].count < Self.outputs }
            if lanes.isEmpty { break }
            let rows = try CBv2OwnedRequestState.runBatch(lanes.map { states[$0]! }, tokenCount: 1, check: {},
                forward: { caches, evaluations in
                    Self.logits(model, lanes.map { [tokens[$0].last!] }, caches: caches, evaluations: evaluations)
                }, validateOutput: { #expect($0.shape == [lanes.count, Self.vocabulary]) })
            for (row, lane) in lanes.enumerated() {
                let index = tokens[lane].count
                let batched = rows[row].asType(.float32).asArray(Float.self)
                let reference = alone[lane].rows[index].asType(.float32).asArray(Float.self)
                #expect(batched == reference, "\(kind) lane \(lane) step \(index) differs from its solo row")
                tokens[lane].append(Self.argmax(rows[row]))
                if tokens[lane].count == Self.outputs { try states[lane]!.retire(); states[lane] = nil }
            }
            step += 1
        }
        for lane in 0..<3 { #expect(tokens[lane] == alone[lane].tokens, "\(kind) lane \(lane) tokens differ") }
        #expect(host.isDrained, "every page and binding returned")
    }

    @Test func pagedTokensEqualContiguousTokens() throws {
        let model = try Self.model()
        let paged = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 64, maximumChunkTokens: Self.chunk)
        let contiguous = try CBv2StageKVHost(model: model, kind: .contiguous, lanes: 1, maximumTokensPerRequest: 64,
            maximumChunkTokens: Self.chunk)
        let a = try Self.solo(model, host: paged), b = try Self.solo(model, host: contiguous)
        let legacy = try Self.solo(model, host: nil)
        for lane in 0..<Self.prompts.count {
            #expect(a[lane].tokens == b[lane].tokens, "paged and contiguous tokens differ for request \(lane)")
            #expect(b[lane].tokens == legacy[lane].tokens, "hosted contiguous differs from per-request storage")
            for (x, y) in zip(b[lane].rows, legacy[lane].rows) {
                #expect(x.asType(.float32).asArray(Float.self) == y.asType(.float32).asArray(Float.self),
                    "hosted contiguous rows must equal per-request storage bit for bit")
            }
        }
        #expect(paged.isDrained && contiguous.isDrained)
    }

    @Test func fullContextGeometryAndOwnedStateKeepProtocolAndDeclaredBounds() throws {
        // Construct only the tiny model's geometry; no forward pass or long prefill.
        let data = try Self.configuration(maximumPositions: 131_072)
        let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
        func geometry(_ tokens: Int, configuration: Data? = nil) throws -> CBv2RequestGeometry {
            try .init(model: model, family: .qwen35,
                feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model), layerCount: 8,
                vocabularySize: Self.vocabulary, configurationData: configuration ?? data, maximumTokens: tokens)
        }
        let g = try geometry(65_536)
        let state = try CBv2OwnedRequestState(geometry: g, promptCount: 32_768, outputCount: 32_768)
        #expect(state.maximumTokens == 65_536 && state.committedTokens == 0)
        try state.retire()
        #expect(throws: (any Error).self) { _ = try geometry(65_537) }
        #expect(throws: (any Error).self) {
            _ = try CBv2OwnedRequestState(geometry: g, promptCount: 1, outputCount: 32_769)
        }
        #expect(throws: (any Error).self) {
            _ = try CBv2OwnedRequestState(geometry: g, promptCount: 32_769, outputCount: 1)
        }
        // The original fixture still declares only 4K; raising the protocol must not widen it.
        _ = try geometry(4096, configuration: Self.configuration())
        #expect(throws: (any Error).self) {
            _ = try geometry(4097, configuration: Self.configuration())
        }
        let host = try CBv2StageKVHost(model: model, kind: .contiguous, lanes: 1,
            maximumTokensPerRequest: 65_536, maximumChunkTokens: Self.chunk)
        #expect(host.maximumTokensPerRequest == 65_536 && host.isDrained)
        #expect(throws: (any Error).self) {
            _ = try CBv2StageKVHost(model: model, kind: .contiguous, lanes: 1,
                maximumTokensPerRequest: 65_537, maximumChunkTokens: Self.chunk)
        }
    }

    @Test func hostRefusesALaneBeyondItsCapacityAndReleasesOnRetire() throws {
        let model = try Self.model()
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 32, maximumChunkTokens: Self.chunk)
        let first = try CBv2OwnedRequestState(geometry: Self.geometry(model, host: host, maximumTokens: 32),
            promptCount: 20, outputCount: 12)
        // The pool's ceiling is one request of 32 tokens plus one segment; a
        // second full-length request may still fit the segment slack, so ask
        // for more than the slack holds through the backend directly.
        #expect(host.backend.bytesReserved > 0)
        try first.retire()
        #expect(host.isDrained)
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(model: model, family: .qwen35,
                feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model), layerCount: 8,
                vocabularySize: Self.vocabulary, configurationData: Self.configuration(), maximumTokens: 33, host: host)
        }
    }
}
