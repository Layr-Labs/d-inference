import Foundation
import MLX
@_spi(GemmaEncoder) @testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Gemma 4 MoE tensor parallel (`gemma4_heads_and_expert_channels_v1`): the
/// plan against the registered 26B's real tensor names and shapes, the cut
/// shards against independent slices of the whole tensors, two real ranks
/// (two threads whose all-sum adds both ranks' FP32 elements in rank order)
/// against the single-process oracle bit for bit, the packed feed-forward
/// collective against separate ones, and the vocabulary-split head against
/// the whole head. CPU only; synthetic weights, never a model pass.
@Suite("Gemma 4 tensor parallel", .serialized)
struct Gemma4TensorParallelTests {
    // MARK: - Registered artifact fixture (safetensors headers, no payload)

    static let inputs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StageMetadataChecks/Inputs")

    struct StoredTensor { let name: String; let shape: [Int]; let dtype: String }

    /// The QAT 4-bit artifact's 1,697 stored tensors from its three headers.
    static func registeredTensors() throws -> [StoredTensor] {
        var tensors: [StoredTensor] = []
        for index in 1 ... 3 {
            let url = inputs.appendingPathComponent("model-0000\(index)-of-00003.safetensors.header.json")
            let header = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            for (name, value) in header where name != "__metadata__" {
                let entry = try #require(value as? [String: Any])
                tensors.append(.init(name: name, shape: try #require(entry["shape"] as? [Int]),
                                     dtype: try #require(entry["dtype"] as? String)))
            }
        }
        return tensors.sorted { $0.name < $1.name }
    }

    /// The registered configuration (QAT 4-bit, SHA-256 29910322…); the 8-bit
    /// artifact's differs only in its default bits.
    static func registeredConfiguration(bits: Int) throws -> [String: Any] {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: inputs.appendingPathComponent("config.json"))) as? [String: Any])
        for key in ["quantization", "quantization_config"] {
            var table = try #require(root[key] as? [String: Any])
            table["bits"] = bits
            root[key] = table
        }
        return root
    }

    static func elements(_ shape: [Int]) -> Int { shape.reduce(1, *) }

    /// Each rank's local logical shape of a module, from the plan's local geometry.
    static func localLogical(_ plan: Gemma4TensorParallelPlan, layer: Int, module: String) throws -> [Int] {
        let h = plan.hiddenSize, d = plan.headDim(layer: layer)
        let dense = try plan.denseSplit(rank: 0).localWidth, expert = try plan.expertSplit(rank: 0).localWidth
        switch module {
        case "self_attn.q_proj": return [plan.queryHeadsPerRank * d, h]
        case "self_attn.k_proj", "self_attn.v_proj": return [plan.kvHeadsPerRank[layer] * d, h]
        case "self_attn.o_proj": return [h, plan.queryHeadsPerRank * d]
        case "mlp.gate_proj", "mlp.up_proj": return [dense, h]
        case "mlp.down_proj": return [h, dense]
        case "experts.switch_glu.gate_proj", "experts.switch_glu.up_proj": return [plan.expertCount, expert, h]
        case "experts.switch_glu.down_proj": return [plan.expertCount, h, expert]
        case "router.proj": return [plan.expertCount, h]
        default: throw ProbeError("no local shape for \(module)")
        }
    }

    /// Every text tensor of `tensors` (`shape` the whole stored shape) is the
    /// shape the plan expects; each rank's part has the shape the rank's local
    /// configuration constructs; rows, owned channels and replicated tensors
    /// cover every tensor exactly once across the two ranks (an odd group
    /// count overlaps one stored group, its other half zero); vision tensors
    /// are refused. Returns each rank's stored bytes and the text bytes.
    static func checkCoverage(_ plan: Gemma4TensorParallelPlan, _ tensors: [StoredTensor]) throws
        -> (rankBytes: [Int], textBytes: Int, vision: Int) {
        var rankBytes = [0, 0], textBytes = 0, vision = 0
        for tensor in tensors {
            let width = tensor.dtype == "U32" || tensor.dtype == "F32" ? 4 : 2
            if !tensor.name.hasPrefix("language_model.") {
                #expect(Gemma4TensorParallelPlan.isVisionTensor(tensor.name), "\(tensor.name) is neither text nor vision")
                #expect(throws: (any Error).self) { try plan.cut(key: tensor.name, rank: 0) }
                vision += 1
                continue
            }
            textBytes += elements(tensor.shape) * width
            #expect(try plan.expectedShape(key: tensor.name) == tensor.shape, "\(tensor.name): \(tensor.shape)")
            let cuts = try (0 ..< 2).map { try plan.cut(key: tensor.name, rank: $0) }
            let locals = try (0 ..< 2).map { try plan.localShape(key: tensor.name, shape: tensor.shape, cut: cuts[$0]) }
            for rank in 0 ..< 2 { rankBytes[rank] += elements(locals[rank]) * width }
            let parts = tensor.name.split(separator: ".").map(String.init)
            let leaf = parts.last!
            switch (cuts[0], cuts[1]) {
            case (.replicate, .replicate):
                #expect(locals[0] == tensor.shape && locals[1] == tensor.shape)
                continue
            case (.rows(let a, let a0, let a1), .rows(let b, let b0, let b1)),
                 (.expertRows(let a, let a0, let a1), .expertRows(let b, let b0, let b1)):
                let axis = tensor.shape.count == 3 ? 1 : 0
                #expect(a.lowerBound == 0 && a.upperBound == b.lowerBound && b.upperBound == tensor.shape[axis],
                        "\(tensor.name): rows \(a), \(b) do not cover \(tensor.shape[axis]) exactly once")
                #expect(a.count + a0 + a1 == b.count + b0 + b1, "\(tensor.name): unequal shares")
            case (.inputColumns(let a), .inputColumns(let b)), (.expertInputColumns(let a), .expertInputColumns(let b)):
                let module = parts.dropLast().joined(separator: ".")
                let divisor = leaf == "weight" ? 32 / plan.bits(forModule: module) : plan.groupSize
                let logical = tensor.shape.last! * divisor
                #expect(a.lowerBound == 0 && b.upperBound == logical && a.count == b.count, "\(tensor.name): \(a) \(b)")
                // Stored columns overlap by at most one group (an odd group count).
                #expect(a.upperBound - b.lowerBound == 0 || a.upperBound - b.lowerBound == plan.groupSize,
                        "\(tensor.name): stored columns \(a), \(b) overlap by more than one group")
            default:
                Issue.record("\(tensor.name): the ranks' cuts are of different kinds")
                continue
            }
            // The local shape is the local configuration's module, packed.
            let layer = Int(parts[3])!
            let module = parts[4 ..< parts.count - 1].joined(separator: ".")
            let logical = try localLogical(plan, layer: layer, module: module)
            let divisor = leaf == "weight" ? 32 / plan.bits(forModule: parts.dropLast().joined(separator: ".")) : plan.groupSize
            #expect(locals[0] == logical.dropLast() + [logical.last! / divisor], "\(tensor.name): local \(locals[0])")
            #expect(locals[1] == locals[0])
        }
        return (rankBytes, textBytes, vision)
    }

    @Test func planCoversTheRegisteredQAT4BitArtifactExactly() throws {
        let tensors = try Self.registeredTensors()
        let plan = try Gemma4TensorParallelPlan(configuration: try Self.registeredConfiguration(bits: 4))
        #expect(tensors.count == 1697)
        let coverage = try Self.checkCoverage(plan, tensors)
        #expect(coverage.vision == 358)
        #expect(coverage.textBytes == 14_467_688_508, "the registered QAT 4-bit text bytes")
        // Equal shares: with the replicated tensors, the shared group and its
        // zero rows, each rank stores 55.6% of the text bytes.
        #expect(coverage.rankBytes == [8_040_450_108, 8_040_450_108])
        #expect(plan.kvHeadsPerRank == (0 ..< 30).map { ($0 + 1) % 6 == 0 ? 1 : 4 })
        #expect(plan.queryHeadsPerRank == 8)
        #expect(try plan.denseSplit(rank: 0).localWidth == 1088 && plan.expertSplit(rank: 1).localWidth == 384)
        #expect(plan.reductionsPerForward == 60 && plan.reductionsPerStep == 1)
        #expect(plan.layerPartialBytesPerToken == (1 + 8 + 1) * 2816 * 4)
    }

    /// The 8-bit artifact (`gemma-4-26b-8bit`): the same names; the shapes the
    /// plan expects at its default bits add up to its registered text bytes.
    @Test func planCoversTheRegistered8BitArtifactExactly() throws {
        let plan = try Gemma4TensorParallelPlan(configuration: try Self.registeredConfiguration(bits: 8))
        let tensors = try Self.registeredTensors().map { tensor -> StoredTensor in
            guard tensor.name.hasPrefix("language_model.") else { return tensor }
            return .init(name: tensor.name, shape: try plan.expectedShape(key: tensor.name), dtype: tensor.dtype)
        }
        let coverage = try Self.checkCoverage(plan, tensors)
        #expect(coverage.textBytes == 26_810_869_820, "the registered 8-bit text bytes")
        #expect(coverage.rankBytes == [14_915_635_260, 14_915_635_260])
        #expect(try plan.expectedShape(key: "language_model.model.embed_tokens.weight") == [262_144, 704])
    }

    @Test func planRefusesUnknownMisalignedAndVisionTensors() throws {
        let plan = try Gemma4TensorParallelPlan(configuration: try Self.registeredConfiguration(bits: 4))
        for key in ["language_model.lm_head.weight", "language_model.model.layers.5.self_attn.v_proj.weight",
                    "language_model.model.layers.30.input_layernorm.weight", "language_model.model.layers.0.experts.gate_up_proj",
                    "language_model.model.layers.00.layer_scalar", "vision_tower.encoder.layers.0.mlp.fc1.weight",
                    "embed_vision.embedding_projection.weight", "model.layers.0.mlp.down_proj.weight"] {
            #expect(throws: (any Error).self, "\(key)") { try plan.cut(key: key, rank: 0) }
        }
        #expect(throws: (any Error).self) { try plan.cut(key: "language_model.model.norm.weight", rank: 2) }
        // A cut that would split a packed word or a group is refused.
        #expect(throws: (any Error).self) {
            try plan.localShape(key: "language_model.model.layers.0.mlp.down_proj.weight", shape: [2816, 528],
                                cut: .inputColumns(0 ..< 1056))
        }
        func refuses(_ change: (inout [String: Any]) -> Void) throws {
            var root = try Self.registeredConfiguration(bits: 4)
            var text = try #require(root["text_config"] as? [String: Any])
            change(&text)
            root["text_config"] = text
            #expect(throws: (any Error).self) { try Gemma4TensorParallelPlan(configuration: root) }
        }
        try refuses { $0["intermediate_size"] = 2112 + 32 }                  // not whole groups
        try refuses { $0["head_dim"] = 36 }                                   // attention shard off a group
        try refuses { $0["num_global_key_value_heads"] = 1 }                  // a KV head would split
        try refuses { $0["tie_word_embeddings"] = false }                     // untied head
        try refuses { $0["enable_moe_block"] = false }                        // dense variants
        try refuses { $0["num_kv_shared_layers"] = 4 }                        // shared KV
        try refuses { $0["layer_types"] = ["sliding_attention"] }             // kinds per layer
        var root = try Self.registeredConfiguration(bits: 4)
        var table = try #require(root["quantization"] as? [String: Any])
        table["language_model.model.layers.0.experts.switch_glu.down_proj"] = ["group_size": 32, "bits": 8]
        root["quantization"] = table
        #expect(throws: (any Error).self) { try Gemma4TensorParallelPlan(configuration: root) }
    }

    /// The plan's arithmetic and the SDK's (`Gemma4ChannelShard`,
    /// `Gemma4TensorShard.localConfiguration`) are one split; the per-rank KV
    /// geometry the SDK derives for the 26B is 4 sliding and 1 full head.
    @Test func planAndSDKShardAgreeOnGeometry() throws {
        for (width, group) in [(2112, 64), (704, 64), (320, 64), (192, 64), (256, 64), (2048, 128)] {
            for rank in 0 ..< 2 {
                let plan = try Gemma4TensorParallelPlan.ChannelSplit(width: width, groupSize: group, rank: rank)
                let sdk = try Gemma4ChannelShard(width: width, groupSize: group, rank: rank)
                #expect(plan.channels == sdk.channels && plan.storedColumns == sdk.storedColumns)
                #expect(plan.zeroBefore == sdk.paddingBefore && plan.zeroAfter == sdk.paddingAfter)
                #expect(sdk.localWidth == (width / group + 1) / 2 * group)
            }
        }
        let root = try Self.registeredConfiguration(bits: 4)
        let plan = try Gemma4TensorParallelPlan(configuration: root)
        let full = try JSONDecoder().decode(Gemma4Configuration.self,
            from: JSONSerialization.data(withJSONObject: root)).textConfiguration
        for rank in 0 ..< 2 {
            let local = try Gemma4TensorShard(rank: rank).localConfiguration(full)
            let text = try plan.shardTextConfiguration(try #require(root["text_config"] as? [String: Any]), rank: rank)
            #expect(local.numAttentionHeads == text["num_attention_heads"] as? Int)
            #expect(local.numKeyValueHeads == text["num_key_value_heads"] as? Int)
            #expect(local.numGlobalKeyValueHeads == text["num_global_key_value_heads"] as? Int)
            #expect(local.intermediateSize == text["intermediate_size"] as? Int)
            #expect(local.moeIntermediateSize == text["moe_intermediate_size"] as? Int)
            #expect(local.cbv2LayerKinds.map(\.kvHeads) == plan.kvHeadsPerRank)
            #expect(try Gemma4TensorShard(rank: rank).vocabularyRange(full) == plan.vocabularyRange(rank: rank))
        }
    }

    // MARK: - Synthetic two-rank runs (CPU)

    /// The in-process pair's reduction for one rank.
    private typealias Pair = Gemma4TensorParallelLocalPair

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static func synthetic(bits: Int, dtype: DType = .bfloat16) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-tp-\(bits)-\(dtype)-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, bits: bits, dtype: dtype)
        }
        return directory
    }

    private static let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }

    /// Both ranks' generations, each rank on its own thread and stream.
    private static func ranks(_ directory: URL, pack: Bool = true, steps: Int = 6, recordTop: Int = 4)
        throws -> (generations: [Gemma4TensorParallelModel.Generation], payloads: [[Int]], models: [Gemma4TensorParallelModel]) {
        let pair = Pair()
        let models = try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                   reduction: pair.reduction(rank: rank), packFeedForward: pack)
            }
        }
        let shared = Box(models)
        let generations = try Pair.run(device: .cpu) { rank in
            try shared.value[rank].generate(prompt: prompt, outputCount: steps, chunk: 16, recordTop: recordTop)
        }
        return (generations, pair.payloads, models)
    }

    private static func single(_ directory: URL, role: Gemma4TensorParallelModel.Role, steps: Int = 6,
                               recordTop: Int = 4) throws -> Gemma4TensorParallelModel.Generation {
        try Device.withDefaultDevice(.cpu) {
            let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: role, reduction: nil)
            return try model.generate(prompt: prompt, outputCount: steps, chunk: 16, recordTop: recordTop)
        }
    }

    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    /// Every parameter of each rank's shard equals an independent slice of the
    /// whole stored tensor (rows, stored columns, zero rows for the other
    /// rank's half of an overlapped group), and a zero row dequantizes to zero.
    @Test(arguments: [4, 8]) func shardParametersEqualReferenceSlices(bits: Int) throws {
        let directory = try Self.synthetic(bits: bits)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let whole = try loadArrays(url: directory.appendingPathComponent("model.safetensors"))
            let plan = try Gemma4TensorParallelPlan(configuration: try #require(try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]))
            let pair = Pair()
            for rank in 0 ..< 2 {
                let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                               reduction: pair.reduction(rank: rank))
                let parameters = Dictionary(uniqueKeysWithValues: model.model.parameters().flattened())
                #expect(Set(parameters.keys) == Set(whole.keys))
                let dense = try plan.denseSplit(rank: rank), expert = try plan.expertSplit(rank: rank)
                for (key, value) in whole.sorted(by: { $0.key < $1.key }) {
                    let local = try #require(parameters[key])
                    let leaf = key.split(separator: ".").last!
                    let module = key.split(separator: ".").dropLast().joined(separator: ".")
                    let divisor = leaf == "weight" ? 32 / plan.bits(forModule: module) : plan.groupSize
                    let layer = key.hasPrefix("language_model.model.layers.") ? Int(key.split(separator: ".")[3])! : 0
                    let d = plan.headDim(layer: layer), q = plan.queryHeadsPerRank, kv = plan.kvHeadsPerRank[layer]
                    func zeros(_ shape: [Int]) -> MLXArray { MLXArray.zeros(shape, dtype: value.dtype) }
                    var expected: MLXArray
                    if key.contains(".self_attn.q_proj.") {
                        expected = value[(rank * q * d) ..< ((rank + 1) * q * d)]
                    } else if key.contains(".self_attn.k_proj.") || key.contains(".self_attn.v_proj.") {
                        expected = value[(rank * kv * d) ..< ((rank + 1) * kv * d)]
                    } else if key.contains(".self_attn.o_proj.") {
                        expected = value[0..., (rank * q * d / divisor) ..< ((rank + 1) * q * d / divisor)]
                    } else if key.contains(".mlp.gate_proj.") || key.contains(".mlp.up_proj.") {
                        let rows = value[dense.channels]
                        let pad = zeros([dense.localWidth - dense.channels.count, value.dim(1)])
                        expected = concatenated(rank == 0 ? [rows, pad] : [pad, rows], axis: 0)
                    } else if key.contains(".mlp.down_proj.") {
                        expected = value[0..., (dense.storedColumns.lowerBound / divisor) ..< (dense.storedColumns.upperBound / divisor)]
                    } else if key.contains(".experts.switch_glu.gate_proj.") || key.contains(".experts.switch_glu.up_proj.") {
                        let rows = value[0..., expert.channels]
                        let pad = zeros([value.dim(0), expert.localWidth - expert.channels.count, value.dim(2)])
                        expected = concatenated(rank == 0 ? [rows, pad] : [pad, rows], axis: 1)
                    } else if key.contains(".experts.switch_glu.down_proj.") {
                        expected = value[0..., 0..., (expert.storedColumns.lowerBound / divisor) ..< (expert.storedColumns.upperBound / divisor)]
                    } else {
                        expected = value
                    }
                    #expect(local.shape == expected.shape && local.dtype == expected.dtype, "\(key) rank \(rank)")
                    #expect(arrayEqual(local, expected).item(Bool.self), "\(key) rank \(rank) differs from its slice")
                }
                // A padded channel of the dense and expert gate projections dequantizes to zero.
                let gate = try #require(model.textModel.model.layers[0].mlp.gateProj as? QuantizedLinear)
                let padded = rank == 0 ? dense.localWidth - 1 : 0
                let row = dequantized(gate.weight[padded ..< padded + 1], scales: gate.scales[padded ..< padded + 1],
                                      biases: gate.biases?[padded ..< padded + 1], groupSize: gate.groupSize, bits: gate.bits)
                #expect(row.abs().max().item(Float.self) == 0)
                #expect(model.textModel.kvHeads == plan.kvHeadsPerRank)
            }
        }
    }

    /// Two real ranks, a 40-token prompt in 16-token chunks (sorted expert
    /// gathers) and greedy steps: every token, recorded top logit and log
    /// probability and the final row on both ranks equal the single-process
    /// oracle bit for bit, with two collectives a layer plus the head's.
    @Test(arguments: [4, 8]) func tensorParallelRanksEqualTheSplitSumOracleBitwise(bits: Int) throws {
        let directory = try Self.synthetic(bits: bits)
        defer { try? FileManager.default.removeItem(at: directory) }
        let splitSum = try Self.single(directory, role: .splitSum)
        let pair = try Self.ranks(directory)
        for (rank, generation) in pair.generations.enumerated() {
            #expect(generation.tokenIDs == splitSum.tokenIDs, "rank \(rank) tokens differ from the oracle")
            #expect(generation.topTokenIDs == splitSum.topTokenIDs)
            #expect(Self.bits(generation.topLogits) == Self.bits(splitSum.topLogits), "rank \(rank) logits")
            #expect(Self.bits(generation.topLogprobs) == Self.bits(splitSum.topLogprobs), "rank \(rank) log probabilities")
            #expect(generation.finalLogits.map { $0.map(\.bitPattern) } == splitSum.finalLogits.map { $0.map(\.bitPattern) })
        }
        let layers = pair.models[0].plan.layerCount, hidden = pair.models[0].plan.hiddenSize
        let forwards = 3 + 5 // three prompt chunks, five decode steps
        let heads = 6 * 2 + 1 // a selection and a top-k per step, the final row
        #expect(pair.payloads.count == forwards * 2 * layers + heads)
        // A decode step's packed feed-forward collective: four expert rows and the dense row.
        #expect(pair.payloads.contains([5, hidden]))
        // A prefill chunk's: 16 x 4 expert rows and 16 dense rows.
        #expect(pair.payloads.contains([16 * 4 + 16, hidden]))
    }

    /// The dense partial packed in the experts' collective against its own
    /// collective: the same bits, two collectives a layer against three.
    @Test func packedFeedForwardCollectiveEqualsTwoCollectives() throws {
        let directory = try Self.synthetic(bits: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packed = try Self.ranks(directory, pack: true, steps: 4, recordTop: 0)
        let separate = try Self.ranks(directory, pack: false, steps: 4, recordTop: 0)
        for rank in 0 ..< 2 {
            #expect(packed.generations[rank].tokenIDs == separate.generations[rank].tokenIDs)
        }
        let layers = packed.models[0].plan.layerCount, forwards = 3 + 3
        #expect(packed.payloads.count == forwards * 2 * layers + 4)
        #expect(separate.payloads.count == forwards * 3 * layers + 4)
    }

    /// Under the registered prompt policy (each token the bytes of its own
    /// one-token call) and the scoped batch decode (singleton rows), each rank
    /// packs every expert partial and the dense partial into ONE collective,
    /// and its expert output and dense sum equal the split-sum oracle's
    /// forward bit for bit. A prompt chunk's tokens share one gate dispatch,
    /// never hinted as sorted (a sorted hint keeps CPU bytes but changes the
    /// GPU kernel route: `promptChunkExpertsEqualOneTokenCallsOnGPU`), from 2
    /// tokens up, at the gather's sort threshold (16 x 4 = 64 routes) and past
    /// it (24 x 4); independent decode rows keep one dispatch each.
    @Test(arguments: ["prompt", "prompt-2", "prompt-boundary", "prompt-sorted", "batch"])
    func scopedSlicesPackIntoOneCollective(scope: String) throws {
        let directory = try Self.synthetic(bits: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = scope.hasPrefix("prompt")
        let geometry: [String: (rows: Int, tokens: Int)] = [
            "prompt": (1, 6), "prompt-2": (1, 2), "prompt-boundary": (1, 16), "prompt-sorted": (1, 24), "batch": (3, 1),
        ]
        let (rows, tokens) = try #require(geometry[scope])
        let shape = [rows, tokens, 256]
        let expected: (experts: [UInt16], dense: [UInt16], indices: MLXArray, weights: MLXArray) = try Device.withDefaultDevice(.cpu) {
            let oracle = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .splitSum, reduction: nil)
            let layer = oracle.textModel.model.layers[0]
            let x = withRandomState(MLXRandom.RandomState(seed: 31)) { MLXRandom.normal(shape).asType(.bfloat16) }
            let (indices, weights) = layer.router!(x)
            let (experts, dense) = Self.scoped(scope, rows: rows, tokens: tokens) {
                (layer.experts!(x, topKIndices: indices, topKWeights: weights, isExpertPrefill: true), layer.mlp(x))
            }
            eval(experts, dense, indices, weights)
            return (experts.asType(.float32).asArray(Float.self).map { UInt16($0.bitPattern >> 16) },
                    dense.asType(.float32).asArray(Float.self).map { UInt16($0.bitPattern >> 16) }, indices, weights)
        }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                   reduction: pair.reduction(rank: rank))
            }
        })
        let gates = Box(try models.value.map { try ObservedGate.install(in: $0.textModel.model.layers[0]) })
        let inputs = Box((expected.indices, expected.weights))
        let results = try Pair.run(device: .cpu) { rank -> ([UInt16], [UInt16]) in
            let layer = models.value[rank].textModel.model.layers[0]
            let x = withRandomState(MLXRandom.RandomState(seed: 31)) { MLXRandom.normal(shape).asType(.bfloat16) }
            let (experts, dense) = Self.scoped(scope, rows: rows, tokens: tokens) {
                layer.experts!.tensorParallelCall(x, topKIndices: inputs.value.0, topKWeights: inputs.value.1,
                    isExpertPrefill: true, carrying: layer.mlp.tensorParallelPartial(x))
            }
            let rounded = dense.asType(.bfloat16)
            eval(experts, rounded)
            return (experts.asType(.float32).asArray(Float.self).map { UInt16($0.bitPattern >> 16) },
                    rounded.asType(.float32).asArray(Float.self).map { UInt16($0.bitPattern >> 16) })
        }
        for (rank, result) in results.enumerated() {
            #expect(result.0 == expected.experts, "rank \(rank): \(scope) expert output differs from the oracle")
            #expect(result.1 == expected.dense, "rank \(rank): \(scope) dense sum differs from the oracle")
            // A prompt chunk's tokens share one gate dispatch, never hinted as sorted; decode rows keep one each.
            let gate = gates.value[rank]
            #expect(gate.sorted == Array(repeating: false, count: prompt ? 1 : rows), "rank \(rank): \(scope): \(gate.sorted)")
        }
        // One collective: every slice's top-4 expert rows, then the dense rows.
        #expect(pair.payloads == [[rows * tokens * 4 + rows * tokens, 256]])
    }

    /// A rank's prompt chunk through `tensorParallelCall` on the GPU against the
    /// same rank's one-token calls, bit for bit (expert output and dense rows):
    /// a small geometry whose gather sorts from 8 tokens and a rank of the
    /// registered 26B (2,816 hidden, 384 stored expert columns, 128 experts,
    /// top-8; sorts from 8 tokens x 8 routes = 64). One gate dispatch per chunk,
    /// never hinted as sorted: a sorted hint takes MLX's `gather_qmm_rhs` route
    /// on the GPU and changes these bytes.
    @Test(arguments: [4, 8]) func promptChunkExpertsEqualOneTokenCallsOnGPU(bits: Int) throws {
        let geometries = [(hidden: 768, width: 192, experts: 16), (hidden: 2816, width: 384, experts: 128)]
        try Device.withDefaultDevice(.gpu) {
            for geometry in geometries {
                let (module, gate) = try Self.rankExperts(bits: bits, hidden: geometry.hidden, width: geometry.width,
                                                          experts: geometry.experts)
                for tokens in [2, 7, 8, 9, 63, 64, 65, 512] {
                    MLXRandom.seed(UInt64(tokens * 31 + bits))
                    let x = MLXRandom.normal([1, tokens, geometry.hidden]).asType(.bfloat16)
                    let scores = MLXRandom.uniform(low: 0, high: 1, [1, tokens, geometry.experts])
                    let kth = geometry.experts - Self.rankTopK
                    let indices = MLX.argPartition(scores, kth: kth, axis: -1)[.ellipsis, kth...].asType(.uint32)
                    let weights = MLX.softmax(MLXRandom.normal([1, tokens, Self.rankTopK]), axis: -1).asType(.bfloat16)
                    let dense = MLXRandom.normal([1, tokens, geometry.hidden])
                    eval(x, indices, weights, dense)
                    gate.reset()
                    let (chunk, chunkDense) = Gemma4PrefillProjectionScope.withPrefillFrame(
                        tokens: MLXArray.zeros([1, tokens], dtype: .int32), enabled: true
                    ) {
                        module.tensorParallelCall(x, topKIndices: indices, topKWeights: weights, isExpertPrefill: true,
                                                  carrying: dense)
                    }
                    eval(chunk, chunkDense)
                    let label = "bits=\(bits) hidden=\(geometry.hidden) experts=\(geometry.experts) tokens=\(tokens)"
                    #expect(gate.sorted == [false], "\(label): \(gate.sorted)")
                    var rows: [MLXArray] = [], denseRows: [MLXArray] = []
                    for token in 0 ..< tokens {
                        let (row, denseRow) = module.tensorParallelCall(
                            x[0..., token ..< token + 1], topKIndices: indices[0..., token ..< token + 1],
                            topKWeights: weights[0..., token ..< token + 1], isExpertPrefill: true,
                            carrying: dense[0..., token ..< token + 1])
                        eval(row, denseRow)
                        rows.append(row); denseRows.append(denseRow)
                    }
                    #expect(Self.bytes(chunk) == Self.bytes(concatenated(rows, axis: 1)), "\(label): expert output")
                    #expect(Self.bytes(chunkDense) == Self.bytes(concatenated(denseRows, axis: 1)), "\(label): dense rows")
                }
            }
        }
    }

    /// The top-K of `rankExperts`, as the registered 26B routes.
    private static let rankTopK = 8

    private static func bytes(_ value: MLXArray) -> Data {
        eval(value)
        return value.asData(access: .copy).data
    }

    /// A Gemma 4 expert block as one rank holds it: packed random gate/up
    /// banks of the rank's stored width (the gate observed) and a
    /// `TensorParallelSwitchLinear` down projection whose sum is the identity.
    private static func rankExperts(bits: Int, hidden: Int, width: Int, experts: Int) throws
        -> (Gemma4Experts, ObservedGate) {
        let values: [String: Any] = [
            "hidden_size": hidden, "num_hidden_layers": 1, "intermediate_size": 128,
            "num_attention_heads": 2, "head_dim": 64, "num_key_value_heads": 1,
            "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
            "vocab_size": 128, "enable_moe_block": true, "num_experts": experts,
            "top_k_experts": rankTopK, "moe_intermediate_size": width, "sliding_window": 512,
            "layer_types": ["sliding_attention"], "use_double_wide_mlp": false,
        ]
        let config = try JSONDecoder().decode(
            Gemma4TextConfiguration.self, from: JSONSerialization.data(withJSONObject: values))
        let module = Gemma4Experts(config)
        MLXRandom.seed(UInt64(4099 + bits + hidden))
        func bank(_ outputs: Int, _ inputs: Int) throws -> QuantizedSwitchLinear {
            let groups = [experts, outputs, inputs / 64]
            return try QuantizedSwitchLinear(
                inputDims: inputs, outputDims: outputs, numExperts: experts,
                weight: MLXRandom.randInt(Int32(0) ..< Int32.max, [experts, outputs, inputs * bits / 32]).asType(.uint32),
                scales: MLXRandom.uniform(low: 0.001, high: 0.01, groups).asType(.bfloat16),
                biases: MLXRandom.uniform(low: -0.02, high: 0.02, groups).asType(.bfloat16),
                groupSize: 64, bits: bits)
        }
        let gate = try ObservedGate(observing: try bank(width, hidden))
        let down = try TensorParallelSwitchLinear(try bank(hidden, width), allSum: { $0 })
        module.switchGLU.update(modules: .unflattened([
            "gate_proj": gate, "up_proj": try bank(width, hidden), "down_proj": down,
        ]))
        eval(module)
        return (module, gate)
    }

    /// `body` under the registered prompt policy or the scoped batch decode.
    private static func scoped<T>(_ scope: String, rows: Int, tokens: Int, _ body: () throws -> T) rethrows -> T {
        let frame = MLXArray.zeros([rows, tokens], dtype: .int32)
        return scope.hasPrefix("prompt")
            ? try Gemma4PrefillProjectionScope.withPrefillFrame(tokens: frame, enabled: true, body)
            : try Gemma4BatchDecodeScope.withDecodeFrame(tokens: frame, enabled: true, body)
    }

    /// Each oracle projection against the whole projection it replaces, on
    /// random inputs: the split sums change only rounding.
    @Test(arguments: [DType.float32, .bfloat16]) func splitSumProjectionsEqualWholeProjections(dtype: DType) throws {
        let directory = try Self.synthetic(bits: 4, dtype: dtype)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let full = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
            let splitSum = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .splitSum, reduction: nil)
            let tolerance: Float = dtype == .float32 ? 1e-4 : 2e-2
            for layer in [0, 2] {
                let a = full.textModel.model.layers[layer], b = splitSum.textModel.model.layers[layer]
                #expect(b.selfAttn.oProj is Gemma4SplitSumLinear && b.mlp.downProj is Gemma4SplitSumLinear)
                for (whole, oracle) in [(a.selfAttn.oProj, b.selfAttn.oProj), (a.mlp.downProj, b.mlp.downProj)] {
                    let input = withRandomState(MLXRandom.RandomState(seed: UInt64(layer + 1))) {
                        MLXRandom.normal([1, 3, (whole as! QuantizedLinear).shape.1]).asType(dtype)
                    }
                    let expected = whole(input).asType(.float32), actual = oracle(input).asType(.float32)
                    let scale = expected.abs().max().item(Float.self)
                    let error = (expected - actual).abs().max().item(Float.self)
                    #expect(error <= tolerance * max(1, scale), "layer \(layer): \(error) of \(scale)")
                }
                let wholeExperts = try #require(a.experts?.switchGLU), oracleExperts = try #require(b.experts?.switchGLU)
                let x = withRandomState(MLXRandom.RandomState(seed: 9)) { MLXRandom.normal([20, 256]).asType(dtype) }
                let indices = withRandomState(MLXRandom.RandomState(seed: 10)) {
                    MLXRandom.randInt(low: 0, high: 16, [20, 4]).asType(.uint32)
                }
                let expected = wholeExperts(x, indices).asType(.float32), actual = oracleExperts(x, indices).asType(.float32)
                let scale = expected.abs().max().item(Float.self)
                let error = (expected - actual).abs().max().item(Float.self)
                #expect(error <= tolerance * max(1, scale), "layer \(layer) experts: \(error) of \(scale)")
            }
        }
    }

    /// Diagnostic (`GEMMA_TP_DIAG=1`, `GEMMA_TP_DIAG_DEVICE=gpu` with
    /// `mlx.metallib` beside the test bundle): each column-parallel operation
    /// of a rank against the same rows of the whole operation, bit for bit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMMA_TP_DIAG"] == "1"))
    func diagnosticShardOperationsEqualWholeOperations() throws {
        let directory = try Self.synthetic(bits: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device: Device = ProcessInfo.processInfo.environment["GEMMA_TP_DIAG_DEVICE"] == "gpu" ? .gpu : .cpu
        try Device.withDefaultDevice(device) { try Self.compareOperations(directory, label: "\(device)") }
    }

    private static func report(_ label: String, _ a: MLXArray, _ b: MLXArray) {
        guard a.shape == b.shape else { print("DIAG \(label): SHAPES \(a.shape) \(b.shape)"); return }
        let equal = arrayEqual(a, b).item(Bool.self)
        let error = (a.asType(.float32) - b.asType(.float32)).abs().max().item(Float.self)
        print("DIAG \(label): \(equal ? "bitwise" : "DIFFERS max \(error)")")
    }

    private static func compareOperations(_ directory: URL, label: String) throws {
        let full = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        let shard = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: 0),
            reduction: QwenTensorParallelLocalReduction(rank: 0, size: 2))
        for tokens in [1, 16] {
            let x = withRandomState(MLXRandom.RandomState(seed: 3)) { MLXRandom.normal([1, tokens, 256]).asType(.bfloat16) }
            for layer in [0, 2] {
                let f = full.textModel.model.layers[layer], s = shard.textModel.model.layers[layer]
                let tag = "\(label) T\(tokens) L\(layer)"
                let qs = s.selfAttn.qProj(x), qf = f.selfAttn.qProj(x)
                report("\(tag) q_proj", qf[.ellipsis, 0 ..< qs.dim(-1)], qs)
                let ks = s.selfAttn.kProj!(x), kf = f.selfAttn.kProj!(x)
                report("\(tag) k_proj", kf[.ellipsis, 0 ..< ks.dim(-1)], ks)
                report("\(tag) gate_proj", f.mlp.gateProj(x)[.ellipsis, 0 ..< 160], s.mlp.gateProj(x)[.ellipsis, 0 ..< 160])
                let headDim = qs.dim(-1) / 8
                let qd = qs.reshaped(1, tokens, 8, headDim).transposed(0, 2, 1, 3)
                let kd = ks.reshaped(1, tokens, ks.dim(-1) / headDim, headDim).transposed(0, 2, 1, 3)
                let qw = qf.reshaped(1, tokens, 16, headDim).transposed(0, 2, 1, 3)
                let kw = kf.reshaped(1, tokens, kf.dim(-1) / headDim, headDim).transposed(0, 2, 1, 3)
                let half = MLXFast.scaledDotProductAttention(queries: qd, keys: kd, values: kd, scale: 1, mask: .causal)
                let whole = MLXFast.scaledDotProductAttention(queries: qw, keys: kw, values: kw, scale: 1, mask: .causal)
                report("\(tag) sdpa", whole[0..., 0 ..< 8], half)
            }
            let hidden = withRandomState(MLXRandom.RandomState(seed: 5)) { MLXRandom.normal([1, tokens, 256]).asType(.bfloat16) }
            report("\(label) T\(tokens) head", full.textModel.applyLMHead(hidden)[.ellipsis, 0 ..< 256],
                   shard.textModel.applyLMHead(hidden))
        }
    }

    /// The whole model against the oracle: an FP32 synthetic model (a random
    /// router's top-k ties are too close for BF16 rounding to keep) agrees on
    /// every token; the split sums change only rounding.
    @Test func wholeModelAndSplitSumOracleAgreeOnTokensInFloat32() throws {
        let directory = try Self.synthetic(bits: 4, dtype: .float32)
        defer { try? FileManager.default.removeItem(at: directory) }
        let full = try Self.single(directory, role: .full, steps: 8)
        let splitSum = try Self.single(directory, role: .splitSum, steps: 8)
        #expect(full.tokenIDs == splitSum.tokenIDs)
        for (a, b) in zip(full.topLogits, splitSum.topLogits) {
            for (x, y) in zip(a, b) { #expect(abs(x - y) <= 1e-3 * max(1, abs(x))) }
        }
    }

    // MARK: - Vocabulary-split head

    /// Runs `body` on two rank threads, each with its own selection over its
    /// half of `logits`; returns both ranks' results.
    private static func splitHead<T>(_ logits: MLXArray, _ body: @escaping (Gemma4TensorParallelSelection, MLXArray) throws -> T)
        throws -> [T] {
        let pair = Pair()
        let vocabulary = logits.dim(-1)
        eval(logits)
        let shared = Box((logits, body))
        return try Pair.run(device: .cpu) { rank in
            let range = (rank * vocabulary / 2) ..< ((rank + 1) * vocabulary / 2)
            let selection = Gemma4TensorParallelSelection(vocabularyRange: range, vocabularySize: vocabulary,
                                                          reduction: pair.reduction(rank: rank))
            return try shared.value.1(selection, shared.value.0[0..., range])
        }
    }

    private static func headLogits(seed: UInt64, tieAt planted: [Int] = []) -> MLXArray {
        Device.withDefaultDevice(.cpu) {
            var logits = withRandomState(MLXRandom.RandomState(seed: seed)) { MLXRandom.normal([1, 512]) * 3 }
            if !planted.isEmpty {
                let peak = logits.max().item(Float.self) + 1
                var values = logits.asArray(Float.self)
                for index in planted { values[index] = peak }
                logits = MLXArray(values, [1, 512])
            }
            return logits
        }
    }

    @Test func splitVocabularyGreedyEqualsTheWholeHead() throws {
        for (seed, planted) in [(1, []), (2, [37, 300]), (3, [300, 400]), (4, [255, 256]), (5, [511])] as [(UInt64, [Int])] {
            let logits = Self.headLogits(seed: seed, tieAt: planted)
            let whole = Device.withDefaultDevice(.cpu) { Int(argMax(logits, axis: -1).item(Int32.self)) }
            let split = try Self.splitHead(logits) { selection, local -> Int in
                let token = selection.greedy(local)
                eval(token)
                return Int(token.item(Int32.self))
            }
            #expect(split == [whole, whole], "seed \(seed): \(split) against \(whole)")
            if let first = planted.first { #expect(whole == first) }
        }
    }

    @Test func splitVocabularyTopKLogprobsEqualTheWholeHead() throws {
        for seed in [11, 12, 13] as [UInt64] {
            let logits = Self.headLogits(seed: seed)
            let whole = try Device.withDefaultDevice(.cpu) {
                try Gemma4TensorParallelSelection(vocabularyRange: 0 ..< 512, vocabularySize: 512, reduction: nil)
                    .topK(logits, count: 16)
            }
            let reference = Device.withDefaultDevice(.cpu) { (logits - logSumExp(logits, axis: -1, keepDims: true)).asArray(Float.self) }
            let split = try Self.splitHead(logits) { selection, local in try selection.topK(local, count: 16) }
            for result in split {
                #expect(result.tokenIDs == whole.tokenIDs)
                #expect(Self.bits([result.logits]) == Self.bits([whole.logits]))
                for (index, id) in result.tokenIDs.enumerated() {
                    #expect(abs(result.logprobs[index] - reference[id]) <= 2e-6, "seed \(seed) token \(id)")
                    #expect(abs(whole.logprobs[index] - reference[id]) <= 2e-6)
                }
            }
            #expect(split[0].logprobs.map(\.bitPattern) == split[1].logprobs.map(\.bitPattern))
        }
    }

    /// The row gather keeps every bit, so the product's sampler draws the
    /// whole row's token from it on every rank.
    @Test func rowGatherKeepsEveryBitForTheProductSampler() throws {
        let logits = Self.headLogits(seed: 21)
        let rows = try Self.splitHead(logits) { selection, local -> [UInt32] in
            let row = selection.gather(local)
            eval(row)
            return row.asArray(Float.self).map(\.bitPattern)
        }
        let expected = Device.withDefaultDevice(.cpu) { logits.asArray(Float.self).map(\.bitPattern) }
        #expect(rows == [expected, expected])
        let key = MLXRandom.key(9)
        let product = Device.withDefaultDevice(.cpu) { Int(MLXRandom.categorical(logits * (1 / Float(0.8)), key: key).item(Int32.self)) }
        let gathered = try Self.splitHead(logits) { selection, local -> Int in
            Int(MLXRandom.categorical(selection.gather(local) * (1 / Float(0.8)), key: key).item(Int32.self))
        }
        #expect(gathered == [product, product])
    }
}

/// An expert gate projection that records the sorted hint of every dispatch
/// (the gathers of a prompt chunk must never be told their rows are sorted).
/// Bound on one thread; not synchronized.
private final class ObservedGate: QuantizedSwitchLinear, @unchecked Sendable {
    private(set) var sorted: [Bool] = []
    func reset() { sorted = [] }

    init(observing gate: QuantizedSwitchLinear) throws {
        try super.init(
            inputDims: gate.shape.inputDims, outputDims: gate.shape.outputDims, numExperts: gate.shape.numExperts,
            weight: gate.weight, scales: gate.scales, biases: try #require(gate.biases), groupSize: gate.groupSize, bits: gate.bits)
    }

    /// Installs an observer in place of `layer`'s expert gate projection.
    static func install(in layer: Gemma4DecoderLayer) throws -> ObservedGate {
        let switchGLU = try #require(layer.experts?.switchGLU)
        let current = switchGLU.leafModules().flattened().first { $0.0 == "gate_proj" }?.1
        let gate = try ObservedGate(observing: try #require(current as? QuantizedSwitchLinear))
        switchGLU.update(modules: .unflattened(["gate_proj": gate]))
        return gate
    }

    override func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool = false) -> MLXArray {
        sorted.append(sortedIndices)
        return super.callAsFunction(x, indices, sortedIndices: sortedIndices)
    }
}
