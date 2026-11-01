import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// MiMo V2.6 tensor parallel (`mimo_v26_heads_and_expert_channels_v1`): the
/// plan against the registered artifact's 1,732 tensor names and shapes, the
/// SDK shard's cuts against independent slices and byte runs, the shard
/// configuration and per-rank KV geometry, two real ranks (two threads whose
/// all-sum adds both ranks' FP32 elements) against each other and the whole
/// model, and the vocabulary-split head against the whole head. CPU only;
/// synthetic weights, never a model pass.
@Suite("MiMo V2.6 tensor parallel", .serialized)
struct MiMoTensorParallelTests {
    struct InventoryTensor: Decodable { let name: String; let shape: [Int]; let byteCount: Int }

    static func fixture(_ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-mimo-v26-flash-mopd.\(name).json"))
    }

    static func local(_ name: String) -> String { String(name.dropFirst(MiMoTensorParallelPlan.textNamespace.count)) }

    // MARK: - The plan against the registered artifact

    @Test func planDisposesOfEveryRegisteredTensor() throws {
        let plan = try MiMoTensorParallelPlan(configuration: Self.fixture("configuration"))
        let inventory = try JSONDecoder().decode([InventoryTensor].self, from: Self.fixture("tensor-inventory"))
        #expect(inventory.count == 1_732)
        var excluded: [String: Int] = [:], replicated = 0, divided = 0, rankBytes = 0
        let shards = try (0 ..< 2).map { try MiMoV26TensorShard(rank: $0) }
        for tensor in inventory {
            switch try plan.disposition(of: tensor.name) {
            case .excluded(let component):
                excluded[component, default: 0] += 1
                #expect(throws: (any Error).self) { try plan.cut(key: tensor.name) }
            case .replicated:
                replicated += 1
                rankBytes += tensor.byteCount
                #expect(try plan.expectedShape(key: tensor.name) == tensor.shape, "\(tensor.name)")
                #expect(try MiMoV26TensorShard.splitAxis(Self.local(tensor.name)) == nil, "\(tensor.name)")
            case .divided(let axis):
                divided += 1
                rankBytes += tensor.byteCount / 2
                #expect(try plan.expectedShape(key: tensor.name) == tensor.shape, "\(tensor.name)")
                #expect(try MiMoV26TensorShard.splitAxis(Self.local(tensor.name)) == axis, "\(tensor.name)")
                var half = tensor.shape
                half[axis] /= 2
                #expect(try plan.localShape(key: tensor.name, shape: tensor.shape) == half)
                for shard in shards {
                    #expect(try shard.localShape(tensor.shape, axis: axis) == half)
                    let runs = try shard.byteRuns(shape: tensor.shape, axis: axis, bytes: tensor.byteCount)
                    #expect(runs.bytes * 2 == tensor.byteCount && runs.end <= tensor.byteCount)
                }
            }
        }
        #expect(excluded == ["mtp": 42, "vision": 364, "audio": 163, "speech": 60])
        #expect(replicated == 194 && divided == 909)
        // Text weights one rank holds: half of every divided tensor plus every replicated one.
        #expect(rankBytes == 84_013_770_176)
        #expect(plan.kvHeadsPerRank.filter { $0 == 2 }.count == 9 && plan.kvHeadsPerRank.filter { $0 == 4 }.count == 39)
        #expect(plan.queryHeadsPerRank.allSatisfy { $0 == 32 })
        #expect(plan.vocabularyRange(rank: 1) == 76_288 ..< 152_576)
        #expect(plan.partialBytesPerToken == 16_384 && plan.reductionsPerForward == 96 && plan.reductionsPerStep == 1)
    }

    @Test func planRefusesRenamedForeignAndOddTensors() throws {
        let data = try Self.fixture("configuration")
        let plan = try MiMoTensorParallelPlan(configuration: data)
        for name in [
            "language_model.model.layers.1.self_attn.q_projection.weight",
            "language_model.model.layers.48.input_layernorm.weight",
            "language_model.model.layers.01.input_layernorm.weight",
            "language_model.model.layers.1.mlp.gate_proj.weight",
            "language_model.model.layers.0.mlp.gate.weight",
            "language_model.model.layers.0.self_attn.attention_sink_bias",
            "language_model.model.layers.1.mlp.switch_mlp.down_proj.biases",
            "language_model.lm_head.bias", "lm_head.weight", "model.norm.weight", "unknown.weight",
        ] {
            #expect(throws: (any Error).self, "\(name)") { try plan.disposition(of: name) }
        }
        for name in ["vision_tower.blocks.0.attn.qkv.weight", "audio_encoder.projection.0.weight",
                     "speech_embeddings.3.weight", "language_model.model.mtp.layers.0.eh_proj.weight"] {
            #expect(throws: (any Error).self, "\(name)") { try plan.cut(key: name) }
            #expect(throws: (any Error).self, "\(name)") { try plan.expectedShape(key: name) }
        }
        #expect(throws: (any Error).self) {
            try plan.localShape(key: "language_model.model.layers.1.self_attn.q_proj.weight", shape: [12_287, 1_024])
        }
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func refuses(_ label: String, _ change: (inout [String: Any]) -> Void) {
            var changed = root
            change(&changed)
            #expect(throws: (any Error).self, "\(label)") {
                try MiMoTensorParallelPlan(configuration: JSONSerialization.data(withJSONObject: changed))
            }
        }
        refuses("full KV heads that do not halve") { $0["num_key_value_heads"] = 3 }
        refuses("sliding KV heads that do not halve") { $0["swa_num_key_value_heads"] = 5 }
        refuses("1,008 expert channels per rank: not whole MXFP4 groups") { $0["moe_intermediate_size"] = 2_016 }
        refuses("8,160 dense channels per rank: not whole 8-bit groups") { $0["intermediate_size"] = 16_320 }
        refuses("an odd vocabulary") { $0["vocab_size"] = 152_575 }
        refuses("a tied head") { $0["tie_word_embeddings"] = true }
        refuses("another model type") { $0["model_type"] = "mimo" }
        refuses("a quantization entry for the router") {
            var table = $0["quantization"] as! [String: Any]
            table["language_model.model.layers.1.mlp.gate"] = ["group_size": 64, "bits": 8, "mode": "affine"]
            $0["quantization"] = table
        }
    }

    @Test func shardConfigurationHalvesExactlySixFields() throws {
        let data = try Self.fixture("configuration")
        let full = try JSONDecoder().decode(MiMoV26Configuration.self, from: data)
        let plan = try MiMoTensorParallelPlan(configuration: data)
        let halved: Set<String> = ["num_attention_heads", "num_key_value_heads", "swa_num_attention_heads",
                                   "swa_num_key_value_heads", "intermediate_size", "moe_intermediate_size"]
        for rank in 0 ..< 2 {
            let shard = try MiMoV26TensorShard(rank: rank)
            let local = try shard.localConfiguration(full)
            let changed = Set(local.rawFields.keys).union(full.rawFields.keys)
                .filter { local.rawFields[$0] != full.rawFields[$0] }
            #expect(changed == halved.union(["num_nextn_predict_layers", "vision_config", "audio_config", "processor_config"]))
            #expect(local.fullAttention.queryHeads == 32 && local.fullAttention.keyValueHeads == 2)
            #expect(local.slidingAttention.queryHeads == 32 && local.slidingAttention.keyValueHeads == 4)
            #expect(local.intermediateSize == 8_192 && local.moeIntermediateSize == 1_024)
            #expect(local.numNextnPredictLayers == 0 && local.vision == nil && local.audio == nil)
            #expect(local.fullAttention.headDim == 192 && local.fullAttention.valueHeadDim == 128)
            #expect(local.slidingAttention.hasSinks && !local.fullAttention.hasSinks)
            #expect(local.slidingAttention.rotaryDimensions == full.slidingAttention.rotaryDimensions)
            #expect(local.vocabularySize == full.vocabularySize && local.routedExpertCount == 256 && local.expertsPerToken == 8)
            let fromPlan = try JSONDecoder().decode(MiMoV26Configuration.self,
                                                    from: plan.shardConfigurationData(data, rank: rank))
            #expect(fromPlan.fullAttention == local.fullAttention && fromPlan.slidingAttention == local.slidingAttention)
            #expect(fromPlan.intermediateSize == local.intermediateSize && fromPlan.moeIntermediateSize == local.moeIntermediateSize)
            #expect(try shard.vocabularyRange(full) == plan.vocabularyRange(rank: rank))
        }
    }

    /// A rank of the registered geometry, constructed lazily (nothing is
    /// evaluated): 32 query heads with 2 full or 4 sliding KV heads, sinks 32,
    /// and request state of 11,520 B per token on the full layers.
    @Test func perRankKVGeometryOfTheRegisteredModel() throws {
        let data = try Self.fixture("configuration")
        let plan = try MiMoTensorParallelPlan(configuration: data)
        let local = try MiMoV26TensorShard(rank: 1).localConfiguration(
            JSONDecoder().decode(MiMoV26Configuration.self, from: data))
        let model = try MiMoV26TextModel(local)
        for (index, layer) in model.model.layers.enumerated() {
            let attention = layer.selfAttention, kv = plan.kvHeadsPerRank[index]
            #expect(attention.geometry.keyValueHeads == kv && attention.geometry.queryHeads == 32)
            #expect(attention.attentionSinkBias?.shape == (plan.hasSinks(layer: index) ? [32] : nil))
            #expect(attention.qProj.weight.shape == [32 * 192, 4_096] && attention.oProj.weight.shape == [4_096, 32 * 128])
            #expect(attention.kProj.weight.shape == [kv * 192, 4_096] && attention.vProj.weight.shape == [kv * 128, 4_096])
        }
        let caches = model.newCache()
        #expect(caches.indices.allSatisfy { caches[$0].maxSize == (plan.slidingLayers[$0] ? 128 : nil) })
        let fullLayerBytes = (0 ..< plan.layerCount).filter { !plan.slidingLayers[$0] }
            .reduce(0) { $0 + plan.kvHeadsPerRank[$1] * (192 + 128) * 2 }
        #expect(fullLayerBytes == 11_520)
    }

    // MARK: - The SDK shard's cuts

    @Test func shardCutsEqualReferenceSlicesAndByteRuns() throws {
        try Device.withDefaultDevice(.cpu) {
            let cases: [([Int], Int, DType)] = [([6, 8], 0, .uint32), ([6, 8], 1, .bfloat16), ([4, 6, 8], 0, .float32),
                                                ([4, 6, 8], 1, .uint8), ([4, 6, 8], 2, .uint32)]
            for (shape, axis, dtype) in cases {
                let count = shape.reduce(1, *)
                let value = MLXArray((0 ..< count).map { Float($0) }, shape).asType(dtype)
                let strides = shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
                for rank in 0 ..< 2 {
                    let shard = try MiMoV26TensorShard(rank: rank)
                    let part = try shard.slice(value, axis: axis)
                    var local = shape
                    local[axis] /= 2
                    #expect(part.shape == local && part.dtype == dtype)
                    // Each local element is the global element `rank * half` further along `axis`.
                    let localStrides = local.indices.map { local[($0 + 1)...].reduce(1, *) }
                    let expected = (0 ..< local.reduce(1, *)).map { flat -> Float in
                        var global = 0
                        for dimension in local.indices {
                            var index = flat / localStrides[dimension] % local[dimension]
                            if dimension == axis { index += rank * local[axis] }
                            global += index * strides[dimension]
                        }
                        return Float(global)
                    }
                    #expect(part.asType(.float32).asArray(Float.self) == expected, "\(shape) axis \(axis) rank \(rank)")
                    let bytes = value.asData(access: .copy).data
                    let runs = try shard.byteRuns(shape: shape, axis: axis, bytes: bytes.count)
                    var selected = Data()
                    for run in 0 ..< runs.count {
                        let start = runs.offset + run * runs.stride
                        selected.append(bytes[start ..< start + runs.length])
                    }
                    #expect(selected == part.asData(access: .copy).data, "\(shape) axis \(axis) rank \(rank) runs")
                }
            }
            #expect(throws: (any Error).self) { try MiMoV26TensorShard(rank: 0).slice(MLXArray.zeros([5, 4]), axis: 0) }
            #expect(throws: (any Error).self) { try MiMoV26TensorShard(rank: 2) }
            #expect(throws: (any Error).self) { try MiMoV26TensorShard.splitAxis("model.mtp.layers.0.enorm.weight") }
        }
    }

    // MARK: - Synthetic checkpoints

    private typealias Pair = Gemma4TensorParallelLocalPair

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static func synthetic(dtype: DType) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-tp-tiny-\(dtype)-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try MiMoTensorParallelModel.writeSyntheticCheckpoint(directory: directory, variant: .tiny, dtype: dtype)
        }
        return directory
    }

    /// Longer than the 8-token window, in 4-token chunks.
    private static let prompt = (0 ..< 12).map { ($0 * 37 + 11) % 512 }

    private static func ranks(_ directory: URL, steps: Int = 6, recordTop: Int = 4)
        throws -> (generations: [MiMoTensorParallelModel.Generation], payloads: [[Int]], models: [MiMoTensorParallelModel]) {
        let pair = Pair()
        let models = try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                 reduction: pair.reduction(rank: rank))
            }
        }
        let shared = Box(models)
        let generations = try Pair.run(device: .cpu) { rank in
            try shared.value[rank].generate(prompt: prompt, outputCount: steps, chunk: 4, recordTop: recordTop)
        }
        return (generations, pair.payloads, models)
    }

    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    /// Every parameter of each rank's shard equals an independent slice of the
    /// whole stored tensor; excluded components were skipped by name.
    @Test func shardParametersEqualIndependentSlices() throws {
        let directory = try Self.synthetic(dtype: .bfloat16)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let whole = try loadArrays(url: directory.appendingPathComponent("model.safetensors"))
            let plan = try MiMoTensorParallelPlan(configuration: Data(contentsOf: directory.appendingPathComponent("config.json")))
            let text = try whole.filter { key, _ in
                if case .excluded = try plan.disposition(of: key) { return false }
                return true
            }
            #expect(whole.count == text.count + 2)
            let pair = Pair()
            for rank in 0 ..< 2 {
                let model = try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                             reduction: pair.reduction(rank: rank))
                let parameters = Dictionary(uniqueKeysWithValues: model.model.parameters().flattened())
                #expect(Set(parameters.keys) == Set(text.keys.map(Self.local)))
                for (key, value) in text.sorted(by: { $0.key < $1.key }) {
                    let part = try #require(parameters[Self.local(key)])
                    var expected = value
                    if case .divided(let axis) = try plan.disposition(of: key) {
                        let half = value.dim(axis) / 2, rows = (rank * half) ..< ((rank + 1) * half)
                        expected = axis == 0 ? value[rows] : (axis == 1 ? value[0..., rows] : value[0..., 0..., rows])
                    }
                    #expect(part.shape == expected.shape && part.dtype == expected.dtype, "\(key) rank \(rank)")
                    #expect(arrayEqual(part, expected).item(Bool.self), "\(key) rank \(rank) differs from its slice")
                }
                #expect(model.model.headVocabularyRange == plan.vocabularyRange(rank: rank))
                #expect(!model.model.hasLoadedReadoutPrecision && model.model.hasLoadedReadoutPrecision(rows: 256))
            }
        }
    }

    /// Two real ranks against each other and the whole model, FP32: every
    /// token, top logit, log probability, step row and the final row agree
    /// bit for bit across ranks, with two collectives a layer and three per
    /// step (selection, top-k gather, row gather); the tokens equal the whole
    /// model's, and each rank's caches hold its half of the KV heads.
    @Test func tensorParallelRanksAgreeAndMatchTheWholeModel() throws {
        let directory = try Self.synthetic(dtype: .float32)
        defer { try? FileManager.default.removeItem(at: directory) }
        let steps = 6
        let (generations, payloads, models) = try Self.ranks(directory, steps: steps)
        let whole = try Device.withDefaultDevice(.cpu) {
            try MiMoTensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
                .generate(prompt: Self.prompt, outputCount: steps, chunk: 4, recordTop: 4)
        }
        #expect(generations[0].tokenIDs == generations[1].tokenIDs)
        #expect(Self.bits(generations[0].topLogits) == Self.bits(generations[1].topLogits))
        #expect(Self.bits(generations[0].topLogprobs) == Self.bits(generations[1].topLogprobs))
        #expect(generations[0].stepRowSHA256 == generations[1].stepRowSHA256)
        #expect(generations[0].finalLogits.map { $0.map(\.bitPattern) } == generations[1].finalLogits.map { $0.map(\.bitPattern) })
        #expect(generations[0].cacheSHA256 != generations[1].cacheSHA256)
        let plan = models[0].plan
        let forwards = (Self.prompt.count + 3) / 4 + steps - 1
        #expect(payloads.count == forwards * plan.reductionsPerForward + steps * 3)
        #expect(payloads.filter { $0 == [1, 4, plan.hiddenSize] }.count == 3 * plan.reductionsPerForward)
        #expect(whole.tokenIDs == generations[0].tokenIDs)
        for (step, row) in whole.topLogits.enumerated() {
            for (index, value) in row.enumerated() {
                #expect(abs(value - generations[0].topLogits[step][index]) <= 1e-3, "step \(step)")
            }
        }
        let wholeRow = try #require(whole.finalLogits), splitRow = try #require(generations[0].finalLogits)
        #expect(zip(wholeRow, splitRow).map { abs($0 - $1) }.max()! <= 1e-3)
        // Each rank's caches hold half the KV heads of every layer (both ranks
        // run the chunk together: every forward takes the other rank's sums).
        let shared = Box(models)
        let heads = try Pair.run(device: .cpu) { rank -> [Int?] in
            let model = shared.value[rank], cache = model.newCache()
            eval(try model.prefill(Array(Self.prompt.prefix(4)), chunk: 4, cache: cache))
            return cache.map { $0.state.first?.dim(1) }
        }
        #expect(heads == [plan.kvHeadsPerRank, plan.kvHeadsPerRank].map { $0.map { Optional($0) } })
    }

    /// Sampling through the gathered row: both ranks draw the same tokens with
    /// the product's sampler, and (FP32) the whole model's tokens under the same keys.
    @Test func sampledRanksDrawTheWholeModelsTokens() throws {
        let directory = try Self.synthetic(dtype: .float32)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampling = MiMoTensorParallelModel.Sampling(temperature: 0.8, seed: 5)
        let pair = Pair()
        let models = try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                 reduction: pair.reduction(rank: rank))
            }
        }
        let shared = Box(models)
        let generations = try Pair.run(device: .cpu) { rank in
            try shared.value[rank].generate(prompt: Self.prompt, outputCount: 8, chunk: 4, sampling: sampling)
        }
        let whole = try Device.withDefaultDevice(.cpu) {
            try MiMoTensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
                .generate(prompt: Self.prompt, outputCount: 8, chunk: 4, sampling: sampling)
        }
        #expect(generations[0].tokenIDs == generations[1].tokenIDs)
        #expect(generations[0].tokenIDs == whole.tokenIDs)
        #expect(generations[0].cacheSHA256 != generations[1].cacheSHA256)
    }

    // MARK: - The vocabulary-split head

    /// The shard's head rows give the whole head's logits for its rows bit
    /// for bit; the split greedy choice (planted ties across the boundary go
    /// to the lowest ID), top-k IDs, logits and log probabilities and the row
    /// gather equal the whole head's.
    @Test func splitHeadGreedyAndLogprobsEqualTheWholeHead() throws {
        let directory = try Self.synthetic(dtype: .bfloat16)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let full = try Device.withDefaultDevice(.cpu) {
            try MiMoTensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        }
        var shards: [MiMoTensorParallelModel] = []
        for rank in 0 ..< 2 {
            shards.append(try Device.withDefaultDevice(.cpu) {
                try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                 reduction: pair.reduction(rank: rank))
            })
        }
        for seed in [3, 4, 5] as [UInt64] {
            let heads = [full.model.lmHead] + shards.map { $0.model.lmHead }
            let rows = Device.withDefaultDevice(.cpu) { () -> [MLXArray] in
                let hidden = withRandomState(MLXRandom.RandomState(seed: seed)) { MLXRandom.normal([1, 1, 256]) }
                    .asType(.bfloat16)
                let projected = heads.map { head -> MLXArray in head!(hidden)[0..., 0, 0...].asType(.float32) }
                eval(projected)
                return projected
            }
            let wholeLogits = rows[0]
            for rank in 0 ..< 2 {
                let range = shards[rank].vocabularyRange
                let expected = Device.withDefaultDevice(.cpu) { wholeLogits[0..., range].asArray(Float.self) }
                #expect(rows[rank + 1].asArray(Float.self).map(\.bitPattern) == expected.map(\.bitPattern))
            }
            try Self.checkSplitSelection(whole: wholeLogits, shards: shards, seed: seed)
            // A planted tie across the two halves goes to the lower token ID.
            let planted = Device.withDefaultDevice(.cpu) { () -> MLXArray in
                var values = wholeLogits.asType(.float32).asArray(Float.self)
                let peak = values.max()! + 1
                values[300] = peak
                values[40] = peak
                return MLXArray(values, [1, 512])
            }
            try Self.checkSplitSelection(whole: planted, shards: shards, seed: seed, expectedGreedy: 40)
        }
    }

    private struct Choice: Sendable {
        let greedy: Int, sampled: Int, tokenIDs: [Int], logits: [UInt32], logprobs: [Float], row: [UInt32]
    }

    private static func checkSplitSelection(whole: MLXArray, shards: [MiMoTensorParallelModel], seed: UInt64,
                                            expectedGreedy: Int? = nil) throws {
        let values = Device.withDefaultDevice(.cpu) { whole.asType(.float32) }
        let wholeTop = try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelSelection(vocabularyRange: 0 ..< 512, vocabularySize: 512, reduction: nil)
                .topK(values, count: 8)
        }
        let greedy = Device.withDefaultDevice(.cpu) { Int(argMax(values, axis: -1).item(Int32.self)) }
        let key = MLXRandom.key(seed)
        let sampled = Device.withDefaultDevice(.cpu) {
            Int(MLXRandom.categorical(values * (1 / Float(0.8)), key: key).item(Int32.self))
        }
        let logSoftmax = Device.withDefaultDevice(.cpu) { (values - logSumExp(values, axis: -1, keepDims: true)).asArray(Float.self) }
        let row = Device.withDefaultDevice(.cpu) { values.asArray(Float.self).map(\.bitPattern) }
        let shared = Box((values, shards, key))
        let choices = try Pair.run(device: .cpu) { rank -> Choice in
            let shard = shared.value.1[rank]
            let local = shared.value.0[0..., shard.vocabularyRange]
            let selection = shard.selection
            let token = selection.greedy(local)
            eval(token)
            let top = try selection.topK(local, count: 8)
            let gathered = selection.gather(local)
            eval(gathered)
            let draw = MLXRandom.categorical(gathered * (1 / Float(0.8)), key: shared.value.2)
            return Choice(greedy: Int(token.item(Int32.self)), sampled: Int(draw.item(Int32.self)), tokenIDs: top.tokenIDs,
                          logits: top.logits.map(\.bitPattern), logprobs: top.logprobs,
                          row: gathered.asArray(Float.self).map(\.bitPattern))
        }
        if let expectedGreedy { #expect(greedy == expectedGreedy) }
        for choice in choices {
            #expect(choice.greedy == greedy, "seed \(seed)")
            #expect(choice.sampled == sampled, "seed \(seed): the product's sampler over the gathered row")
            #expect(choice.tokenIDs == wholeTop.tokenIDs && choice.logits == wholeTop.logits.map(\.bitPattern))
            for (index, id) in choice.tokenIDs.enumerated() {
                #expect(abs(choice.logprobs[index] - logSoftmax[id]) <= 2e-6, "seed \(seed) token \(id)")
            }
            #expect(choice.row == row)
        }
    }

    // MARK: - Refusals

    @Test func tensorParallelInstallationAndOtherOwnersRefuse() throws {
        let directory = try Self.synthetic(dtype: .bfloat16)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let full = try JSONDecoder().decode(MiMoV26Configuration.self, from: data)
            let model = try MiMoV26TextModel(try MiMoV26TensorShard(rank: 0).localConfiguration(full))
            try model.installTensorParallel(reduce: { $0 }, vocabularyRows: 0 ..< 256)
            #expect(model.tensorParallelVocabularyRows == 0 ..< 256)
            #expect(throws: (any Error).self) { try model.installTensorParallel(reduce: { $0 }, vocabularyRows: 0 ..< 256) }
            let other = try MiMoV26TextModel(full)
            #expect(throws: (any Error).self) { try other.installTensorParallel(reduce: { $0 }, vocabularyRows: 0 ..< 513) }
            let pair = Pair()
            let rank = try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: 1),
                                                        reduction: pair.reduction(rank: 1))
            // Paged, CBv2 and MTP owners require the whole vocabulary's readout.
            #expect(throws: (any Error).self) { try MiMoV26CBv2Adapter(target: rank.model) }
            #expect(throws: (any Error).self) {
                try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: 1), reduction: nil)
            }
            #expect(throws: (any Error).self) {
                try MiMoTensorParallelModel.load(modelDirectory: directory, role: .full, reduction: pair.reduction(rank: 0))
            }
        }
    }
}
