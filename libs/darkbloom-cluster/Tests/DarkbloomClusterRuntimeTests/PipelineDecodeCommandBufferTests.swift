import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// Pipeline decode of every remaining layer-stage family encodes under
// `QwenLayerStageSession.decodeCommandBuffers` (100 operations a buffer, no
// input-size bound) instead of the rank's 16-operation guard. Only where
// command buffers end may move. Random synthetic stages run as the stage
// sessions drive them: the prompt under the rank's guard, then the decode
// work under a guard and again under the decode limits. Every output row,
// verify window and cache or state array must be the same bytes.
//
// The reference run decodes under the rank's guard, or under `bankGuard` where
// registered banks exceed MLX's size bound and the synthetic stage can
// reproduce it: routed Qwen and Gemma, whose expert banks of 2 Mi elements each
// commit a buffer, as each registered bank does. The Nemotron and GLM fixtures
// are too small for any size bound, so they, like every family, also run with
// a buffer every second dispatch (`everyOperation`), a finer partition than one
// buffer per bank. No artifact, collective or network.

@Suite("Pipeline decode command buffers change no byte (random stages)", .serialized)
struct PipelineDecodeCommandBufferTests {
    /// The rank's own limits as a worker starts it (`ClusterWorkerEnvironmentGuards`):
    /// 16 operations, MLX's per-chip size bound.
    static let rankGuard = GPU.CommandBufferLimits(operations: 16, megabytes: 0)
    /// MLX's size bound counts Mi elements of distinct inputs: at 1, every
    /// bank of 2 Mi elements or more commits a buffer, as a registered bank
    /// of 60-256 Mi elements does at MLX's own 40-50.
    static let bankGuard = GPU.CommandBufferLimits(operations: 16, megabytes: 1)
    /// A buffer ends after every second dispatch: no coarser than one a bank.
    static let everyOperation = GPU.CommandBufferLimits(operations: 1, megabytes: 1)
    static let decodeLimits = QwenLayerStageSession.decodeCommandBuffers

    static func requireSameBytes(_ guarded: [Data], _ decoded: [Data], _ label: String) {
        #expect(guarded.count == decoded.count && !guarded.isEmpty, "\(label): \(guarded.count) against \(decoded.count) arrays")
        let first = zip(guarded, decoded).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(first == nil, "\(label): array \(first ?? -1) of \(guarded.count) differs")
    }

    static func argmax(_ row: MLXArray) -> Int { Int(argMax(row, axis: -1).item(UInt32.self)) }
    static func bytes(_ array: MLXArray) -> Data { eval(array); return array.asData(access: .copy).data }

    @Test func everyPipelineTakesTheTensorParallelDecodeLimits() {
        #expect(QwenLayerStageSession.decodeCommandBuffers == .init(operations: 100, megabytes: 1 << 20))
        #expect(QwenLayerStageSession.decodeCommandBuffers == GLM5NextTensorParallelResidentRuntime.decodeCommandBuffers)
        #expect(QwenLayerStageSession.decodeCommandBuffers == QwenTensorParallelBatchSession.decodeCommandBuffers)
    }

    // MARK: Qwen 3.5 stages (`QwenLayerStageSession`): dense, and routed experts

    static let qwenVocabulary = 320

    /// Four layers (two of full attention, head width 256 with 16 query and 2
    /// KV heads, as the routed rows), 32 experts of width 512 (8 a token): each
    /// expert bank holds 2 Mi elements at 4 bits.
    static func routedConfiguration() throws -> Data {
        let text: [String: Any] = [
            "model_type": "qwen3_5_moe_text", "vocab_size": qwenVocabulary, "hidden_size": 1024,
            "intermediate_size": 1024, "num_hidden_layers": 4, "full_attention_interval": 2, "head_dim": 256,
            "num_attention_heads": 16, "num_key_value_heads": 2, "linear_conv_kernel_dim": 4,
            "linear_key_head_dim": 64, "linear_num_key_heads": 4, "linear_num_value_heads": 8, "linear_value_head_dim": 64,
            "num_experts": 32, "num_experts_per_tok": 8, "moe_intermediate_size": 512,
            "shared_expert_intermediate_size": 512, "norm_topk_prob": true,
            "max_position_embeddings": 4096, "rms_norm_eps": 1e-6, "tie_word_embeddings": false,
            "rope_theta": 10_000_000, "partial_rotary_factor": 0.25, "attention_bias": false,
            "mtp_num_hidden_layers": 0,
        ]
        return try JSONSerialization.data(withJSONObject: ["model_type": "qwen3_5_moe", "text_config": text] as [String: Any],
            options: [.sortedKeys])
    }

    /// The routed rows' class (`QwenRoutedExpertStageModel`).
    static func routedModel() throws -> Qwen35MoEModel {
        let data = try routedConfiguration()
        let model = try withRandomState(MLXRandom.RandomState(seed: 29)) { () -> Qwen35MoEModel in
            let model = Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
            var scaled: [String: MLXArray] = [:]
            for (name, value) in model.parameters().flattened() {
                scaled[name] = (MLXRandom.normal(value.shape) * 0.05).asType(.bfloat16)
            }
            try model.update(parameters: ModuleParameters.unflattened(scaled), verify: [.noUnusedKeys, .shapeMismatch])
            return model
        }
        quantize(model: model, filter: { _, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in (64, 4, .affine) })
        model.freeze(); eval(model)
        let banks = model.parameters().flattened().filter { $0.0.contains("switch_mlp") && $0.0.hasSuffix(".weight") }
        #expect(!banks.isEmpty && banks.allSatisfy { $0.1.size >= 2 << 20 }, "every routed bank holds 2 Mi elements")
        return model
    }

    struct QwenStage {
        let model: any CBv2RecurrentCaptureMTPForwardable & LanguageModel
        let configuration: Data
        let layers: Int
    }

    static func qwenStages() throws -> [(label: String, stage: QwenStage, guarded: GPU.CommandBufferLimits)] {
        [("dense", QwenStage(model: try CBv2PagedBatchSyntheticTests.model(),
                             configuration: try CBv2PagedBatchSyntheticTests.configuration(), layers: 8), rankGuard),
         ("routed", QwenStage(model: try routedModel(), configuration: try routedConfiguration(), layers: 4), bankGuard)]
    }

    static func qwenState(_ stage: QwenStage, host: CBv2StageKVHost, promptCount: Int) throws -> CBv2OwnedRequestState {
        let geometry = try CBv2RequestGeometry(model: stage.model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(stage.model), layerCount: stage.layers,
            vocabularySize: qwenVocabulary, configurationData: stage.configuration, maximumTokens: 64, host: host)
        return try CBv2OwnedRequestState(geometry: geometry, promptCount: promptCount, outputCount: 64 - promptCount)
    }

    static func qwenRows(_ stage: QwenStage, _ tokens: [[Int]], caches: [any CBv2AttendingLayerCache],
                         evaluations: [CBv2RecurrentStateEvaluation]) -> MLXArray {
        let input = MLXArray(tokens.flatMap { $0.map(Int32.init) }).reshaped([tokens.count, tokens[0].count])
        return stage.model.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
            recurrentState: evaluations, positionIds: nil).logits[0..., -1, 0...]
    }

    /// The prompt in frames of eight under the rank's guard; the last row.
    static func qwenPrefill(_ stage: QwenStage, _ state: CBv2OwnedRequestState, _ prompt: [Int]) throws -> MLXArray {
        try GPU.withCommandBufferLimits(rankGuard) {
            var offset = 0, last = MLXArray(0)
            while offset < prompt.count {
                let part = Array(prompt[offset..<min(prompt.count, offset + 8)])
                last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                    qwenRows(stage, [part], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
                offset += part.count
            }
            return last
        }
    }

    /// One request on a paged stage KV host: four decode steps, a verify
    /// window of the next token and three drafts kept to its first two rows
    /// (the captured window `QwenLayerStageSession.beginWindow` builds), and
    /// three more steps, under `limits`. Every row, the window's logits, and
    /// at the end every committed state array, as bytes.
    static func qwenTrace(_ stage: QwenStage, decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let prompt = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]
        let host = try CBv2StageKVHost(model: stage.model, kind: .paged, lanes: 1, maximumTokensPerRequest: 64,
            maximumChunkTokens: 8)
        let state = try qwenState(stage, host: host, promptCount: prompt.count)
        var row = try qwenPrefill(stage, state, prompt)
        var recorded = [bytes(row)]
        try GPU.withCommandBufferLimits(limits) {
            var token = argmax(row)
            func step() throws {
                let fed = token
                row = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                    qwenRows(stage, [[fed]], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
                recorded.append(bytes(row)); token = argmax(row)
            }
            for _ in 0..<4 { try step() }
            let window = [token, (token + 17) % qwenVocabulary, (token + 42) % qwenVocabulary, (token + 7) % qwenVocabulary]
            let input = MLXArray(window.map(Int32.init)).reshaped([1, window.count])
            let built = try state.beginWindow(tokenCount: window.count) { caches, evaluation in
                [stage.model.cbv2ForwardWithHiddenCaptured(input, caches: caches.map { $0 as! any KVCache },
                    recurrentState: [evaluation], positionIds: nil).logits]
            }
            eval(built.outputs + built.roots)
            try state.confirmWindow(check: {})
            recorded.append(bytes(built.outputs[0]))
            eval(try state.settleWindow(keeping: 2))
            try state.confirmSettled(check: {})
            token = argmax(built.outputs[0][0, 1, 0...])
            for _ in 0..<3 { try step() }
        }
        let snapshot = try state.snapshot(globalLayerIndices: Array(0..<stage.layers), includeBytes: true, check: {})
        recorded += snapshot.entries.compactMap(\.bytes)
        try state.retire()
        #expect(host.isDrained)
        return recorded
    }

    /// Two requests on one host, each prompt alone under the rank's guard,
    /// then five steps decoding both as lanes (`QwenLayerStageSession.decodeBatch`'s
    /// call) under `limits`. Every batched row, then every committed state array.
    static func qwenLanes(_ stage: QwenStage, decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let prompts = [[3, 1, 4, 1, 5, 9, 2], [6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8]]
        let host = try CBv2StageKVHost(model: stage.model, kind: .paged, lanes: 2, maximumTokensPerRequest: 64,
            maximumChunkTokens: 8)
        var states: [CBv2OwnedRequestState] = [], tokens: [Int] = []
        for prompt in prompts {
            let state = try qwenState(stage, host: host, promptCount: prompt.count)
            tokens.append(argmax(try qwenPrefill(stage, state, prompt)))
            states.append(state)
        }
        var recorded: [Data] = []
        try GPU.withCommandBufferLimits(limits) {
            for _ in 0..<5 {
                let fed = tokens
                let rows = try CBv2OwnedRequestState.runBatch(states, tokenCount: 1, check: {},
                    forward: { caches, evaluations in
                        Qwen35BatchDecodeScope.$enabled.withValue(true) {
                            qwenRows(stage, fed.map { [$0] }, caches: caches, evaluations: evaluations)
                        }
                    }, validateOutput: { _ in })
                recorded.append(bytes(rows))
                tokens = (0..<fed.count).map { argmax(rows[$0]) }
            }
        }
        for state in states {
            recorded += try state.snapshot(globalLayerIndices: Array(0..<stage.layers), includeBytes: true, check: {})
                .entries.compactMap(\.bytes)
            try state.retire()
        }
        #expect(host.isDrained)
        return recorded
    }

    @Test func qwenStagesDecodeTheSameBytes() throws {
        for (label, stage, guarded) in try Self.qwenStages() {
            let reference = try Self.qwenTrace(stage, decode: guarded)
            Self.requireSameBytes(reference, try Self.qwenTrace(stage, decode: Self.decodeLimits), "qwen \(label) one request")
            Self.requireSameBytes(reference, try Self.qwenTrace(stage, decode: Self.everyOperation),
                "qwen \(label) one request, a buffer per operation")
            Self.requireSameBytes(try Self.qwenLanes(stage, decode: guarded), try Self.qwenLanes(stage, decode: Self.decodeLimits),
                "qwen \(label) lanes")
        }
    }

    // MARK: Nemotron stages (`NemotronStageForward` inside `QwenLayerStageSession`)

    /// The two stages of cut 5 of the synthetic Nemotron: the prompt in two
    /// frames under the rank's guard, then six decode frames under `limits`.
    /// Every residual that crossed the cut, every logits row and, at the end,
    /// every committed state array.
    static func nemotronTrace(decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        typealias N = NemotronStageSyntheticTests
        let configuration = try N.configuration()
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<5, 5..<N.pattern.count])
        let complete = try N.completeModel(configuration)
        let models = try (0...1).map { try N.stage(plan, $0, from: complete) as! NemotronHModel }
        let prompt = [[3, 1, 4, 1, 5], [9, 2, 6]], total = 32
        let states = try (0...1).map { index in
            try CBv2OwnedRequestState(geometry: try CBv2RequestGeometry(model: models[index], family: .qwen35,
                    feedForwardKind: "dense", layerCount: plan.stages[index].layers.count, vocabularySize: N.vocabulary,
                    configurationData: plan.stages[index].constructionConfiguration, maximumTokens: total),
                promptCount: 8, outputCount: total - 8)
        }
        var recorded: [Data] = [], offset = 0, sequence = 0
        func frame(_ tokens: [Int], _ phase: QwenLayerStageFrame.Phase, final: Bool = false) throws -> MLXArray {
            let frame = QwenLayerStageFrame(sequence: sequence, phase: phase, tokenOffset: offset,
                tokenCount: tokens.count, finalPromptChunk: final)
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
            let residual = try states[0].run(tokenCount: tokens.count, check: {}, forward: { caches, evaluation in
                NemotronStageForward.run(model: models[0], stageIndex: 0, tokens: input, residual: nil,
                    caches: caches, evaluation: evaluation, frame: frame)
            }, validateOutput: { _ in })
            // What crosses the cut is bytes: the consumer gets a copy with no graph behind it.
            let crossed = MLXArray(bytes(residual), residual.shape, dtype: residual.dtype)
            let output = try states[1].run(tokenCount: tokens.count, check: {}, forward: { caches, evaluation in
                NemotronStageForward.run(model: models[1], stageIndex: 1, tokens: input, residual: crossed,
                    caches: caches, evaluation: evaluation, frame: frame)
            }, validateOutput: { _ in })
            recorded += [bytes(residual), bytes(output)]
            offset += tokens.count; sequence += 1
            return output
        }
        var row = try GPU.withCommandBufferLimits(rankGuard) { () -> MLXArray in
            _ = try frame(prompt[0], .prefill)
            return try frame(prompt[1], .prefill, final: true)
        }
        try GPU.withCommandBufferLimits(limits) {
            for _ in 0..<6 { row = try frame([argmax(row)], .decode) }
        }
        for (index, state) in states.enumerated() {
            recorded += try state.snapshot(globalLayerIndices: plan.stages[index].layers.map(\.globalIndex),
                includeBytes: true, check: {}).entries.compactMap(\.bytes)
            try state.retire()
        }
        return recorded
    }

    @Test func nemotronStagesDecodeTheSameBytes() throws {
        let reference = try Self.nemotronTrace(decode: Self.rankGuard)
        Self.requireSameBytes(reference, try Self.nemotronTrace(decode: Self.everyOperation), "nemotron, a buffer per operation")
        Self.requireSameBytes(reference, try Self.nemotronTrace(decode: Self.decodeLimits), "nemotron")
    }

    // MARK: Gemma 4 (the decoder its layer-stage seam runs through `QwenLayerStageSession`)

    /// Two layers (one sliding with a window of 8, one full), keys equal to
    /// values, head widths 256 and 512 as registered; 16 experts of width
    /// 1,024 (8 a token) beside the dense MLP: each expert bank holds 2 Mi
    /// elements at 4 bits.
    static func gemmaModel() throws -> Gemma4TextModel {
        let configuration: [String: Any] = [
            "model_type": "gemma4_text", "hidden_size": 1024, "num_hidden_layers": 2,
            "intermediate_size": 512, "num_attention_heads": 4, "head_dim": 256,
            "global_head_dim": 512, "num_key_value_heads": 2, "num_global_key_value_heads": 1,
            "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
            "vocab_size": 512, "tie_word_embeddings": true, "attention_k_eq_v": true,
            "enable_moe_block": true, "num_experts": 16, "top_k_experts": 8,
            "moe_intermediate_size": 1024, "sliding_window": 8,
            "layer_types": ["sliding_attention", "full_attention"],
            "use_double_wide_mlp": false, "final_logit_softcapping": 30.0,
            "rope_parameters": [
                "full_attention": ["partial_rotary_factor": 0.25, "rope_theta": 1_000_000.0, "rope_type": "proportional"],
                "sliding_attention": ["rope_theta": 10_000.0, "rope_type": "default"]],
        ]
        let config = try JSONDecoder().decode(Gemma4TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: configuration))
        let model = withRandomState(MLXRandom.RandomState(seed: 31)) { Gemma4TextModel(config) }
        model.update(parameters: ModuleParameters.unflattened(model.parameters().flattened().map {
            ($0.0, $0.1.asType(.bfloat16))
        }))
        quantize(model: model, filter: { path, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
            (64, path.hasSuffix(".router.proj") ? 8 : 4, .affine)
        })
        model.freeze(); eval(model)
        return model
    }

    /// Two requests on contiguous request-owned KV: each prompt a token at a
    /// time under the rank's guard; then four steps of the first alone and
    /// four of both as lanes, under `limits`. Every logits row, then every
    /// committed key and value array.
    static func gemmaTrace(_ model: Gemma4TextModel, decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 256 << 20, kvDType: .bfloat16))
        let prompts = [[5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71], [9, 4, 81, 2, 15, 66, 30]]
        let requests = try prompts.map {
            try backend.makeSequenceState(layerKinds: model.cbv2LayerKinds, promptLength: $0.count, maxLength: 64)
        }
        let caches = try model.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) }
        defer {
            for cache in caches { cache.setRows([]) }
            for request in requests { backend.release(request) }
        }
        func forward(_ rows: [Int], _ tokens: [Int]) -> MLXArray {
            for index in caches.indices { caches[index].setRows(rows.map { requests[$0][index]! }) }
            let input = MLXArray(tokens.map(Int32.init), [rows.count, 1])
            let output = Gemma4BatchDecodeScope.withDecodeFrame(tokens: input, enabled: rows.count > 1) {
                model(input, cache: caches.map { $0 as! any KVCache })
            }
            eval([output] + caches.flatMap { ($0 as! any KVCache).innerState() })
            return output[0..., -1, 0...]
        }
        var recorded: [Data] = [], next: [Int] = []
        try GPU.withCommandBufferLimits(rankGuard) {
            for (index, prompt) in prompts.enumerated() {
                var row = MLXArray(0)
                for token in prompt { row = forward([index], [token]) }
                next.append(argmax(row))
            }
        }
        GPU.withCommandBufferLimits(limits) {
            for _ in 0..<4 {
                let row = forward([0], [next[0]])
                recorded.append(bytes(row)); next[0] = argmax(row)
            }
            for _ in 0..<4 {
                let rows = forward([0, 1], next)
                recorded.append(bytes(rows)); next = (0..<2).map { argmax(rows[$0]) }
            }
        }
        for request in requests {
            for layer in request {
                guard let snapshot = layer?.snapshot() else { continue }
                recorded += [bytes(snapshot.keys), bytes(snapshot.values)]
            }
        }
        return recorded
    }

    @Test func gemmaDecoderDecodesTheSameBytes() throws {
        let model = try Self.gemmaModel()
        let banks = model.parameters().flattened().filter { $0.0.contains("experts") && $0.0.hasSuffix(".weight") }
        #expect(!banks.isEmpty && banks.allSatisfy { $0.1.size >= 2 << 20 }, "every expert bank holds 2 Mi elements")
        let reference = try Self.gemmaTrace(model, decode: Self.bankGuard)
        Self.requireSameBytes(reference, try Self.gemmaTrace(model, decode: Self.everyOperation), "gemma, a buffer per operation")
        Self.requireSameBytes(reference, try Self.gemmaTrace(model, decode: Self.decodeLimits), "gemma")
    }

    // MARK: GPT-OSS stages (`GPTOSSLayerStageSession`)

    static func gptossPages(_ model: GPTOSSModel) -> [GPTOSSPagedKVCache] {
        model.cbv2LayerKinds.map { kind in
            switch kind.attention {
            case .full: GPTOSSPagedKVCache()
            case .slidingWindow(let window): GPTOSSPagedKVCache(window: window)
            }
        }
    }

    /// Two stages of a packed four-layer GPT-OSS (MXFP4 experts, affine 8-bit
    /// projections, learned sinks, a window of 8) on paged caches: two prompts
    /// alone under the rank's guard, then four steps of the first
    /// (`GPTOSSLayerStageSession.decode`'s forward) and four of both as lanes
    /// (`GPTOSSBatchForward.decode`), under `limits`. Every residual and
    /// logits row, then every cache array.
    static func gptossTrace(decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        typealias F = GPTOSSNativeTestFixture
        let whole = try F.model(layers: 0..<4, dtype: .bfloat16)
        let producer = try F.stage(from: whole, layers: 0..<2, first: true, dtype: .bfloat16)
        let consumer = try F.stage(from: whole, layers: 2..<4, first: false, dtype: .bfloat16)
        let head = try #require(consumer.namedModules().first { $0.0 == "lm_head" }?.1 as? Linear)
        let prompts = [[3, 9, 17, 2, 41, 6, 12, 30, 7, 55, 1], [8, 20, 33, 5, 61]]
        let before = prompts.map { _ in gptossPages(producer) }, after = prompts.map { _ in gptossPages(consumer) }
        var recorded: [Data] = [], next: [Int] = []
        func one(_ lane: Int, _ tokens: [Int]) -> MLXArray {
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
            let residual = producer.model(input, cache: before[lane])
            eval([residual] + before[lane].flatMap { $0.innerState() })
            let crossed = MLXArray(bytes(residual), residual.shape, dtype: residual.dtype)
            let row = head(consumer.model(input, cache: after[lane], inputEmbeddings: crossed))[0..., -1, 0...]
            eval([row] + after[lane].flatMap { $0.innerState() })
            recorded += [bytes(residual), bytes(row)]
            return row
        }
        GPU.withCommandBufferLimits(rankGuard) {
            for (lane, prompt) in prompts.enumerated() { next.append(argmax(one(lane, prompt))) }
        }
        try GPU.withCommandBufferLimits(limits) {
            for _ in 0..<4 { next[0] = argmax(one(0, [next[0]])) }
            for _ in 0..<4 {
                let residual = try GPTOSSBatchForward.decode(model: producer, head: nil, stageIndex: 0, hiddenSize: 64,
                    vocabularySize: 64, dtype: .bfloat16, tokens: next, residual: nil, histories: before, check: {})
                let crossed = MLXArray(bytes(residual), residual.shape, dtype: residual.dtype)
                let rows = try GPTOSSBatchForward.decode(model: consumer, head: head, stageIndex: 1, hiddenSize: 64,
                    vocabularySize: 64, dtype: .bfloat16, tokens: next, residual: crossed, histories: after, check: {})
                recorded += [bytes(residual), bytes(rows)]
                next = (0..<2).map { argmax(rows[$0]) }
            }
        }
        recorded += (before + after).flatMap { $0.flatMap { $0.state } }.map(bytes)
        return recorded
    }

    @Test func gptossStagesDecodeTheSameBytes() throws {
        let reference = try Self.gptossTrace(decode: Self.rankGuard)
        Self.requireSameBytes(reference, try Self.gptossTrace(decode: Self.everyOperation), "gpt-oss, a buffer per operation")
        Self.requireSameBytes(reference, try Self.gptossTrace(decode: Self.decodeLimits), "gpt-oss")
    }

    // MARK: GLM stages (`GLM5NextStageSession`)

    /// The verified stages of the synthetic GLM artifact (`GLM5NextStageSessionTests`,
    /// cut 3 of 8 layers), driven as `GLM5NextStageSession.forward` drives them:
    /// the prompt in two frames under the rank's guard, then five decode
    /// frames under `limits`. Every four-stream boundary, every logits row and,
    /// at the end, every cache array of both stages.
    static func glmTrace(decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let fixture = try GLM5NextStageSessionTests.Fixture()
        defer { try? fixture.first.close(check: {}); try? fixture.last.close(check: {}) }
        let stages = [fixture.firstStage.model, fixture.lastStage.model]
        let caches = stages.map { $0.newCache() }
        var recorded: [Data] = []
        func frame(_ tokens: [Int], logits: Bool) throws -> MLXArray? {
            let produced = try stages[0].prepareForward(tokens: MLXArray(tokens.map(Int32.init), [1, tokens.count]),
                cache: caches[0])
            try produced.commit { roots in eval(roots); Stream.gpu.synchronize() }
            guard case .streams(let streams) = produced.output else { throw ProbeError("GLM producer returned no streams") }
            let crossed = MLXArray(bytes(streams), streams.shape, dtype: streams.dtype)
            let consumed = try stages[1].prepareForward(streams: crossed, cache: caches[1], readout: logits ? .lastToken : .none)
            try consumed.commit { roots in eval(roots); Stream.gpu.synchronize() }
            recorded.append(bytes(streams))
            guard logits, case .final(let value) = consumed.output else { return nil }
            let row = value.logits[0..., -1, 0...]
            recorded.append(bytes(row))
            return row
        }
        var row = try GPU.withCommandBufferLimits(rankGuard) { () -> MLXArray in
            _ = try frame([4, 5], logits: false)
            return try #require(try frame([6, 7], logits: true))
        }
        try GPU.withCommandBufferLimits(limits) {
            for _ in 0..<5 { row = try #require(try frame([argmax(row)], logits: true)) }
        }
        recorded += caches.flatMap { $0.layers.flatMap { $0.innerState() } }.map(bytes)
        return recorded
    }

    @Test func glmStagesDecodeTheSameBytes() throws {
        let reference = try Self.glmTrace(decode: Self.rankGuard)
        Self.requireSameBytes(reference, try Self.glmTrace(decode: Self.everyOperation), "glm, a buffer per operation")
        Self.requireSameBytes(reference, try Self.glmTrace(decode: Self.decodeLimits), "glm")
    }
}
