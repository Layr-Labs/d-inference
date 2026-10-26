import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// Two Gemma 4 layer stages at the registered attention geometry (sliding
// layers: 8 KV heads of 256 and a 1,024-token window; full layers: 2 KV heads
// of 512; 16 query heads; hidden 2,816, vocabulary 262,144) with seeded random
// 4-bit weights and a tiny expert block, each stage on its own KV host. Prompts
// run past the sliding window, so the paged rings wrap. Paged against
// contiguous is compared by tokens (`CBv2PagedBatchSyntheticTests`); the hosted
// contiguous rows equal per-request storage bit for bit; and on either host
// several requests decoding together (a lane joining, another leaving) give
// each request its own tokens alone.
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("Paged stage KV on synthetic Gemma 4 stages (no artifact)", .serialized)
struct Gemma4StagePagedSyntheticTests {
    static let vocabulary = Gemma4StageGeometry.vocabularySize, hidden = Gemma4StageGeometry.hiddenSize
    static let prompts: [[Int]] = [(0..<1100).map { ($0 * 7919 + 13) % 262_144 }, (0..<300).map { ($0 * 104_729 + 5) % 262_144 },
                                   (0..<700).map { ($0 * 15_485_863 + 77) % 262_144 }]
    static let outputs = 6, chunk = 512, maximumTokens = 2048
    /// One full-attention layer and five sliding ones on each rank.
    static let ranges = [0..<6, 24..<30]

    static func configuration() throws -> Gemma4TextConfiguration {
        let types = (0..<Gemma4StageGeometry.layerCount).map { Gemma4StageGeometry.kind(globalLayerIndex: $0) }
        let text: [String: Any] = [
            "model_type": "gemma4_text", "attention_bias": false, "attention_k_eq_v": true, "enable_moe_block": true,
            "final_logit_softcapping": 30.0, "global_head_dim": 512, "head_dim": 256, "hidden_size": hidden,
            "hidden_size_per_layer_input": 0, "intermediate_size": 64, "layer_types": types,
            "max_position_embeddings": 262_144, "moe_intermediate_size": 64, "num_attention_heads": 16,
            "num_experts": 4, "num_global_key_value_heads": 2, "num_hidden_layers": 30, "num_key_value_heads": 8,
            "num_kv_shared_layers": 0, "rms_norm_eps": 1e-6,
            "rope_parameters": [
                "full_attention": ["partial_rotary_factor": 0.25, "rope_theta": 1_000_000.0, "rope_type": "proportional"],
                "sliding_attention": ["rope_theta": 10_000.0, "rope_type": "default"],
            ],
            "sliding_window": 1024, "tie_word_embeddings": true, "top_k_experts": 2, "use_double_wide_mlp": false,
            "vocab_size": vocabulary, "vocab_size_per_layer_input": vocabulary,
        ]
        return try JSONDecoder().decode(Gemma4TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: text, options: [.sortedKeys]))
    }

    static func models() throws -> [Gemma4LayerStageModel] {
        let configuration = try configuration()
        return try (0...1).map { rank in
            let model = try Gemma4LayerStageModel(configuration: configuration, rank: rank,
                sourceLayerRange: ranges[rank], fuseWeightedUnsort: false)
            try withRandomState(MLXRandom.RandomState(seed: UInt64(17 + rank))) {
                var values: [String: MLXArray] = [:]
                for (name, value) in model.parameters().flattened() {
                    values[name] = MLXRandom.normal(value.shape, dtype: .bfloat16, scale: 0.05)
                }
                try model.update(parameters: ModuleParameters.unflattened(values), verify: [.noUnusedKeys, .shapeMismatch])
            }
            quantize(model: model, groupSize: 64, bits: 4, mode: .affine)
            model.freeze(); eval(model)
            #expect(model.activationDType == .bfloat16)
            return model
        }
    }

    static func hosts(_ models: [Gemma4LayerStageModel], kind: ClusterStageKVBackendKind?, lanes: Int) throws
        -> [CBv2StageKVHost?] {
        try models.map { model in
            try kind.map {
                try CBv2StageKVHost(model: model, kind: $0, lanes: lanes, maximumTokensPerRequest: maximumTokens,
                    maximumChunkTokens: chunk)
            }
        }
    }

    static func state(_ model: Gemma4LayerStageModel, host: CBv2StageKVHost?, promptCount: Int) throws
        -> CBv2OwnedRequestState {
        var geometry = try model.layerStageRequestGeometry(maximumTokens: maximumTokens)
        if let host { geometry = try CBv2RequestGeometry(gemma4Stage: geometry, host: host, maximumTokens: maximumTokens) }
        return try CBv2OwnedRequestState(geometry: geometry, promptCount: promptCount, outputCount: outputs)
    }

    static func argmax(_ row: MLXArray) -> Int { Int(argMax(row, axis: -1).item(UInt32.self)) }
    static func floats(_ row: MLXArray) -> [Float] { row.asType(.float32).asArray(Float.self) }

    static func frame(_ phase: QwenLayerStageFrame.Phase, _ offset: Int, _ count: Int, final: Bool = false)
        -> QwenLayerStageFrame {
        .init(sequence: 0, phase: phase, tokenOffset: offset, tokenCount: count, finalPromptChunk: final)
    }

    /// One frame of one request through both stages.
    static func step(_ models: [Gemma4LayerStageModel], _ states: [CBv2OwnedRequestState], _ tokens: [Int],
                     _ frame: QwenLayerStageFrame) throws -> MLXArray {
        let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
        let residual = try states[0].run(tokenCount: tokens.count, check: {}, forward: { caches, _ in
            models[0].layerStageForward(tokens: input, residual: nil, caches: caches, frame: frame)
        }, validateOutput: { #expect($0.shape == [1, tokens.count, hidden]) })
        return try states[1].run(tokenCount: tokens.count, check: {}, forward: { caches, _ in
            models[1].layerStageForward(tokens: input, residual: residual, caches: caches, frame: frame)
        }, validateOutput: { _ in })
    }

    /// Prefills `prompt` in chunks; returns the open states and the first row.
    static func open(_ models: [Gemma4LayerStageModel], hosts: [CBv2StageKVHost?], _ prompt: [Int]) throws
        -> (states: [CBv2OwnedRequestState], row: MLXArray) {
        let states = try (0...1).map { try state(models[$0], host: hosts[$0], promptCount: prompt.count) }
        var offset = 0, row: MLXArray?
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            row = try step(models, states, Array(prompt[offset..<end]),
                frame(.prefill, offset, end - offset, final: end == prompt.count))
            offset = end
        }
        #expect(row?.shape == [1, vocabulary])
        return (states, row!)
    }

    /// Each request alone: its tokens and the logits row of every step.
    static func solo(_ models: [Gemma4LayerStageModel], hosts: [CBv2StageKVHost?]) throws
        -> [(tokens: [Int], rows: [[Float]])] {
        try prompts.map { prompt in
            var (states, row) = try open(models, hosts: hosts, prompt)
            var tokens = [argmax(row)], rows = [Self.floats(row)]
            while tokens.count < outputs {
                row = try step(models, states, [tokens.last!], frame(.decode, prompt.count + tokens.count - 1, 1))
                tokens.append(argmax(row)); rows.append(floats(row))
            }
            for state in states { try state.retire() }
            return (tokens, rows)
        }
    }

    @Test func pagedStagesGiveTheContiguousTokens() throws {
        let models = try Self.models()
        let paged = try Self.hosts(models, kind: .paged, lanes: 1)
        let contiguous = try Self.hosts(models, kind: .contiguous, lanes: 1)
        for host in paged {
            let host = try #require(host)
            #expect(host.kind == .paged && host.caches.allSatisfy { $0 is PagedLayerCache })
            #expect(host.layerKinds.filter { $0.attention == .full }.count == 1)
        }
        let a = try Self.solo(models, hosts: paged)
        let b = try Self.solo(models, hosts: contiguous)
        let legacy = try Self.solo(models, hosts: [nil, nil])
        // Not vacuous: finite rows, tokens that vary.
        #expect(a.allSatisfy { $0.rows.allSatisfy { $0.allSatisfy(\.isFinite) } })
        #expect(Set(a.flatMap(\.tokens)).count > 2)
        let drift = zip(a.flatMap(\.rows), b.flatMap(\.rows)).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        print("gemma4-paged tokens=\(a.map(\.tokens)) max_abs_logit_diff_vs_contiguous=\(drift)")
        for index in Self.prompts.indices {
            #expect(a[index].tokens == b[index].tokens, "paged and contiguous tokens differ for request \(index)")
            #expect(b[index].tokens == legacy[index].tokens, "hosted contiguous differs from per-request storage")
            #expect(b[index].rows == legacy[index].rows, "hosted contiguous rows must equal per-request storage bit for bit")
        }
        #expect((paged + contiguous).allSatisfy { $0!.isDrained }, "every page and binding returned")
    }

    @Test(arguments: [ClusterStageKVBackendKind.paged, .contiguous])
    func batchedLanesGiveEachRequestItsTokensAlone(kind: ClusterStageKVBackendKind) throws {
        let models = try Self.models()
        let hosts = try Self.hosts(models, kind: kind, lanes: 3)
        let alone = try Self.solo(models, hosts: hosts)
        #expect(hosts.allSatisfy { $0!.isDrained })
        var states: [[CBv2OwnedRequestState]?] = [nil, nil, nil]
        var tokens: [[Int]] = [[], [], []]
        func join(_ lane: Int) throws {
            let (opened, row) = try Self.open(models, hosts: hosts, Self.prompts[lane])
            #expect(Self.floats(row) == alone[lane].rows[0], "\(kind) lane \(lane) prefill row differs")
            tokens[lane] = [Self.argmax(row)]; states[lane] = opened
        }
        try join(0); try join(1)
        var step = 0, identicalRows = 0, differentRows = 0
        while true {
            if step == 2 { try join(2) }
            let lanes = (0..<3).filter { states[$0] != nil && tokens[$0].count < Self.outputs }
            if lanes.isEmpty { break }
            let input = MLXArray(lanes.map { Int32(tokens[$0].last!) }).reshaped([lanes.count, 1])
            let frame = Self.frame(.decode, 0, 1)
            let residual = try CBv2OwnedRequestState.runBatch(lanes.map { states[$0]![0] }, tokenCount: 1, check: {},
                forward: { caches, _ in
                    models[0].layerStageForward(tokens: input, residual: nil, caches: caches, frame: frame)
                }, validateOutput: { #expect($0.shape == [lanes.count, 1, Self.hidden]) })
            let rows = try CBv2OwnedRequestState.runBatch(lanes.map { states[$0]![1] }, tokenCount: 1, check: {},
                forward: { caches, _ in
                    models[1].layerStageForward(tokens: input, residual: residual, caches: caches, frame: frame)
                }, validateOutput: { #expect($0.shape == [lanes.count, Self.vocabulary]) })
            for (row, lane) in lanes.enumerated() {
                let index = tokens[lane].count
                // Rows: two or more rows round the shared quantized
                // projections differently from one (`runBatch`), so a batched
                // row is held to its solo token, and its bytes are counted.
                if Self.floats(rows[row]) == alone[lane].rows[index] { identicalRows += 1 } else { differentRows += 1 }
                tokens[lane].append(Self.argmax(rows[row]))
                if tokens[lane].count == Self.outputs {
                    for state in states[lane]! { try state.retire() }
                    states[lane] = nil
                }
            }
            step += 1
        }
        for lane in 0..<3 { #expect(tokens[lane] == alone[lane].tokens, "\(kind) lane \(lane) tokens differ") }
        print("gemma4-paged-batch kind=\(kind.rawValue) rows_identical=\(identicalRows) rows_different=\(differentRows)")
        #expect(hosts.allSatisfy { $0!.isDrained }, "every page and binding returned")
    }

    /// Model-free: a Gemma stage now takes a host at every lane count (paged
    /// by default), sized for whole pages, and its geometry refuses a request
    /// longer than the host.
    @Test func aGemmaHostIsPagedAtEveryLaneCountAndHoldsWholePages() throws {
        let configuration = try Self.configuration()
        let model = try Gemma4LayerStageModel(configuration: configuration, rank: 0, sourceLayerRange: 0..<12,
            fuseWeightedUnsort: false)
        quantize(model: model, groupSize: 64, bits: 4, mode: .affine)
        for lanes in [1, 2, 8] { #expect(CBv2StageKVHost.supports(model, lanes: lanes)) }
        #expect(try ClusterStageKVBackendKind.fromEnvironment([:]) == .paged)
        let geometry = try model.layerStageRequestGeometry(maximumTokens: 8320)
        let pages = try CBv2StageKVHost.pagedRequestBytes(kinds: geometry.kinds, dtype: geometry.kvDType,
            maximumTokens: 8320, maximumChunkTokens: 512)
        // Two full layers in whole pages (8,320 is whole pages), ten rings of
        // whole pages a page or two past the window.
        let ringPage = 16 * 8 * 256 * 2 * geometry.kvDType.size
        #expect(pages > geometry.kvCapacityBytes && pages <= geometry.kvCapacityBytes + 10 * 2 * ringPage)
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 2, maximumTokensPerRequest: 8320,
            maximumChunkTokens: 512)
        #expect(host.capacityBytes == 2 * pages + CBv2StageKVHost.segmentBytes)
        #expect(host.caches.enumerated().allSatisfy { $0.element.layerIndex == $0.offset })
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(gemma4Stage: geometry, host: host, maximumTokens: 8321)
        }
        // The registered request allowance (the whole model's ledger, charged
        // to each rank) covers the pages of every layer of the model, bf16, and
        // a segment, from one token to the profile's longest request.
        let limits = try Gemma4ResidentAdapterDefinition.contextLimits()
        for tokens in [1, 15, 16, 17, 1024, 1040, 1041, 4096, limits.maximumContextTokens] {
            let all = try CBv2StageKVHost.pagedRequestBytes(kinds: configuration.cbv2LayerKinds, dtype: .bfloat16,
                maximumTokens: tokens, maximumChunkTokens: limits.maximumChunkTokens)
            let budget = try Gemma4StateBudget.estimate(maximumTokens: tokens,
                chunkSize: min(tokens, limits.maximumChunkTokens))
            #expect(all + CBv2StageKVHost.segmentBytes <= budget.stateAndBoundaryBytes, "tokens=\(tokens)")
        }
    }
}
