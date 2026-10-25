import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A routed-expert layer packs its shared expert's FP32 partial behind the
/// selected experts' rows in one collective. Two real ranks (two threads whose
/// all-sum adds both ranks' FP32 elements in rank order, as the sealed
/// all-gather sum does) must give bit-identical logits and tokens on each rank
/// with the packed collective and with the earlier separate shared-expert
/// collective: a prefill whose gathers sort (T x top-K >= 64), then greedy
/// one-token steps, while the packed run issues two collectives a layer.
@Suite("Qwen MoE tensor-parallel packed collective", .serialized)
struct QwenMoETensorParallelPackingTests {
    init() {
        // Diagnostic only (`QWEN_TP_MOE_NO_BUFFER_CACHE=1`): MLX keeps no freed
        // buffer, so no allocation reuses an earlier test's bytes.
        if ProcessInfo.processInfo.environment["QWEN_TP_MOE_NO_BUFFER_CACHE"] == "1" { Memory.cacheLimit = 0 }
    }

    private final class Rendezvous: @unchecked Sendable {
        let condition = NSCondition()
        var leaving = 0, step = 0
        var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        var output: [Float] = []
        /// Every collective's payload shape, in order.
        var payloads: [[Int]] = []
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            precondition(value.dtype == .float32)
            let bytes = value.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                output = zip(values[0]!, values[1]!).map(+)
                payloads.append(shapes[0]!)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(300)
                while leaving == 0 && step == generation { precondition(condition.wait(until: deadline)) }
            }
            let result = output; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; output = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(result, value.shape)
        }
    }

    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Rendezvous
        init(_ rank: Int, _ wire: Rendezvous) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }

    /// The earlier shared-expert projection: its FP32 partial summed by its
    /// own collective, then rounded. Not packable (no packed-partial
    /// conformance), so the sparse block keeps two MoE collectives.
    private final class SeparateSharedDown: QuantizedLinear {
        private final class Box { let value: QwenTensorParallelReduction; init(_ v: QwenTensorParallelReduction) { value = v } }
        private let reduction: Box
        init(_ source: QuantizedLinear, reduction: QwenTensorParallelReduction) {
            self.reduction = Box(reduction)
            super.init(weight: source.weight, bias: source.bias, scales: source.scales, biases: source.biases,
                       groupSize: source.groupSize, bits: source.bits, mode: source.mode)
            freeze()
        }
        override func callAsFunction(_ x: MLXArray) -> MLXArray {
            reduction.value.allSum(super.callAsFunction(x.asType(.float32))).asType(x.dtype)
        }
    }

    private struct Pair {
        let ranks: [QwenTensorParallelModel]
        let reductions: [Rank]
        let wire: Rendezvous
    }

    private final class Owner: @unchecked Sendable {
        let model: QwenTensorParallelModel
        var rows: [Data] = []
        var tokens: [Int] = []
        var failure: Error?
        init(_ model: QwenTensorParallelModel) { self.model = model }
    }

    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }

    private static let syntheticLayers = 2, syntheticTopK = 2, syntheticHidden = 128

    /// A tiny two-layer routed-expert model, affine4/group64, deterministic
    /// weights. Interval 2: one linear-attention and one full-attention layer
    /// (the Gated DeltaNet kernels run on the GPU only); interval 1: two
    /// full-attention layers, which the CPU runs.
    private static func syntheticCheckpoint(fullAttentionInterval: Int = 2) throws
        -> (configuration: Data, weights: [String: MLXArray]) {
        let text: [String: Any] = [
            "model_type": "qwen3_5_moe_text", "hidden_size": syntheticHidden, "num_hidden_layers": syntheticLayers,
            "num_experts": 8, "num_experts_per_tok": syntheticTopK, "moe_intermediate_size": 128,
            "shared_expert_intermediate_size": 128, "num_attention_heads": 4, "num_key_value_heads": 2,
            "head_dim": 64, "linear_num_key_heads": 2, "linear_num_value_heads": 4,
            "linear_key_head_dim": 64, "linear_value_head_dim": 64, "linear_conv_kernel_dim": 4,
            "rms_norm_eps": 1e-6, "vocab_size": 256, "rope_theta": 100000.0, "partial_rotary_factor": 0.25,
            "max_position_embeddings": 4096, "tie_word_embeddings": false, "attention_bias": false,
            "attn_output_gate": true, "full_attention_interval": fullAttentionInterval, "mtp_num_hidden_layers": 0,
        ]
        let root: [String: Any] = ["model_type": "qwen3_5_moe", "text_config": text,
                                   "quantization": ["group_size": 64, "bits": 4, "mode": "affine"]]
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let model = Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: configuration))
        let values = model.parameters().flattened().map { name, array in
            let seed = name.utf8.reduce(0) { $0 + Int($1) }
            let norm = name.contains("norm.weight")
            var data = (0..<array.size).map { Float(($0 * 17 + seed) % 127 - 63) / 512 + (norm ? 1 : 0) }
            // Recurrent decay terms in a stable range, as the synthetic dense checkpoint keeps them.
            if name.hasSuffix("linear_attn.A_log") { data = data.map { -abs($0) - 0.25 } }
            return (name, MLXArray(data, array.shape).asType(.bfloat16))
        }
        model.update(parameters: ModuleParameters.unflattened(values))
        quantize(model: model) { _, _ in (64, 4, .affine) }
        eval(model)
        return (configuration, Dictionary(uniqueKeysWithValues: model.parameters().flattened()))
    }

    private func pair(device: Device, load: (Int, Rank) throws -> QwenTensorParallelModel) throws -> Pair {
        let wire = Rendezvous()
        let reductions = (0..<2).map { Rank($0, wire) }
        let ranks = try (0..<2).map { rank in
            try Device.withDefaultDevice(device) { try load(rank, reductions[rank]) }
        }
        for model in ranks {
            let leaves = Dictionary(uniqueKeysWithValues: model.model.leafModules().flattened())
            for layer in 0..<model.plan.layerCount {
                let base = "language_model.model.layers.\(layer).mlp."
                // A row-parallel shared projection is packable; the expert projection carries it.
                #expect(leaves[base + "shared_expert.down_proj"] is QwenTensorParallelRowLinear)
                #expect(leaves[base + "switch_mlp.down_proj"] is Qwen35TensorParallelSwitchLinear)
            }
        }
        let pair = Pair(ranks: ranks, reductions: reductions, wire: wire)
        // Diagnostic only (`QWEN_TP_MOE_VIEW_WEIGHTS=1`): the layout the cuts had before LOAD copied them row-major.
        if ProcessInfo.processInfo.environment["QWEN_TP_MOE_VIEW_WEIGHTS"] == "1" { try Self.relayAsViews(pair) }
        return pair
    }

    /// Every matrix parameter re-laid as a column-major view of the same
    /// values, which MLX copies row-major at each call, as it copied the
    /// interior cuts' gather views before LOAD made them row-major.
    private static func relayAsViews(_ pair: Pair) throws {
        for model in pair.ranks {
            let views = model.model.parameters().flattened().map { name, value -> (String, MLXArray) in
                value.ndim >= 2 ? (name, value.swappedAxes(-1, -2).contiguous().swappedAxes(-1, -2)) : (name, value)
            }
            eval(views.map(\.1))
            try model.model.update(parameters: ModuleParameters.unflattened(views), verify: .none)
        }
    }

    /// Restores the earlier schedule on both ranks: every shared expert sums
    /// its own partial in a separate collective.
    private func separateSharedExperts(_ pair: Pair) throws {
        for (rank, model) in pair.ranks.enumerated() {
            let leaves = Dictionary(uniqueKeysWithValues: model.model.leafModules().flattened())
            let replacements = try (0..<model.plan.layerCount).map { layer -> (String, Module) in
                let path = "language_model.model.layers.\(layer).mlp.shared_expert.down_proj"
                let installed = try #require(leaves[path] as? QuantizedLinear)
                return (path, SeparateSharedDown(installed, reduction: pair.reductions[rank]))
            }
            try model.model.update(modules: ModuleChildren.unflattened(replacements), verify: .none)
        }
    }

    /// Both ranks' local logits (the prefill's last row, then each step's) and
    /// greedy tokens (both ranks' distributed selection) for `prompt`.
    private func generate(_ pair: Pair, prompt: [Int], chunk: Int, steps: Int, device: Device) throws -> [Owner] {
        pair.wire.payloads = []
        let owners = pair.ranks.map { Owner($0) }
        let work = Work { owner in
            let cache = owner.model.newCache()
            var logits = owner.model.prefill(prompt, chunk: chunk, cache: cache)
            for step in 0...steps {
                let token = owner.model.select(logits)
                eval(logits, token)
                owner.rows.append(logits.asType(.float32).asData().data)
                owner.tokens.append(Int(token.item(Int32.self)))
                if step < steps { logits = owner.model.step(token, cache: cache) }
            }
        }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            // MLX's default stream is one process-wide, thread-unsafe stream:
            // each rank's thread submits to its own, as each rank's process does.
            Device.withDefaultDevice(device) {
                Stream.withNewDefaultStream(device: device) {
                    do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
                }
            }
        }
        for owner in owners { if let failure = owner.failure { throw failure } }
        return owners
    }

    /// Packed and separate runs of the same ranks: every logit bit and token
    /// equal on both ranks, and the packed run's collectives per layer.
    @discardableResult
    private func checkPackingIsExact(_ pair: Pair, prompt: [Int], chunk: Int, steps: Int, device: Device) throws -> [Int] {
        let layers = pair.ranks[0].plan.layerCount, plan = pair.ranks[0].plan
        let packed = try generate(pair, prompt: prompt, chunk: chunk, steps: steps, device: device)
        let packedPayloads = pair.wire.payloads
        try separateSharedExperts(pair)
        let separate = try generate(pair, prompt: prompt, chunk: chunk, steps: steps, device: device)
        let separatePayloads = pair.wire.payloads
        for rank in 0..<2 {
            #expect(packed[rank].rows.count == steps + 1)
            let differing = zip(packed[rank].rows, separate[rank].rows).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
            #expect(packed[rank].rows == separate[rank].rows, "rank \(rank): packing changed a logit bit (rows \(differing), row 0 is the prefill's)")
            #expect(packed[rank].tokens == separate[rank].tokens && packed[rank].tokens == packed[0].tokens)
        }
        // Each forward: the mixer's row and the packed MoE rows each layer, or
        // the mixer's, the experts' and the shared expert's; each step one selection.
        let chunks = (prompt.count + chunk - 1) / chunk, forwards = chunks + steps
        let isSelection: ([Int]) -> Bool = { $0 == [4] }
        #expect(packedPayloads.filter { !isSelection($0) }.count == forwards * 2 * layers)
        #expect(separatePayloads.filter { !isSelection($0) }.count == forwards * 3 * layers)
        let width = plan.hiddenSize, topK = plan.expertsPerToken
        let firstChunk = min(chunk, prompt.count)
        #expect(packedPayloads[1] == [firstChunk * topK + firstChunk, width], "a prefill MoE collective packs T x K + T rows")
        let lastForward = Array(packedPayloads.filter { !isSelection($0) }.suffix(2 * layers))
        #expect(lastForward[1] == [topK + 1, width], "a decode MoE collective packs K + 1 rows")
        return packed[0].tokens
    }

    @Test func packedSharedExpertCollectiveIsBitIdenticalOnTwoCPURanks() throws {
        let fixture = try Self.syntheticCheckpoint(fullAttentionInterval: 1)
        let pair = try pair(device: .cpu) { rank, reduction in
            try QwenTensorParallelModel.assemble(configurationData: fixture.configuration,
                role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                for name in fixture.weights.keys.sorted() { try keep(name, fixture.weights[name]!) }
            }
        }
        let prompt = (0..<40).map { ($0 * 37 + 11) % 256 }
        try checkPackingIsExact(pair, prompt: prompt, chunk: 40, steps: 3, device: .cpu)
    }

    /// Diagnostic (`QWEN_TP_MOE_GPU_DIAG=1`): the same packed run twice, and
    /// packed against separate with a prompt below the sorted-gather threshold.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MOE_GPU_DIAG"] == "1"))
    func packedRunsRepeatAndShortPromptsOnTwoGPURanks() throws {
        let fixture = try Self.syntheticCheckpoint()
        func load() throws -> Pair {
            try pair(device: .gpu) { rank, reduction in
                try QwenTensorParallelModel.assemble(configurationData: fixture.configuration,
                    role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                    for name in fixture.weights.keys.sorted() { try keep(name, fixture.weights[name]!) }
                }
            }
        }
        func differing(_ a: [Data], _ b: [Data]) -> [Int] {
            zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        }
        for count in [40, 20] {
            let prompt = (0..<count).map { ($0 * 37 + 11) % 256 }
            let pair = try load()
            let first = try generate(pair, prompt: prompt, chunk: count, steps: 3, device: .gpu)
            let second = try generate(pair, prompt: prompt, chunk: count, steps: 3, device: .gpu)
            try separateSharedExperts(pair)
            let separate = try generate(pair, prompt: prompt, chunk: count, steps: 3, device: .gpu)
            let viewed = try load()
            try Self.relayAsViews(viewed)
            let packedViews = try generate(viewed, prompt: prompt, chunk: count, steps: 3, device: .gpu)
            try separateSharedExperts(viewed)
            let separateViews = try generate(viewed, prompt: prompt, chunk: count, steps: 3, device: .gpu)
            for rank in 0..<2 {
                print("qwen-moe-packing-diag prompt=\(count) rank=\(rank) repeat_differs=\(differing(first[rank].rows, second[rank].rows)) "
                    + "packed_vs_separate_differs=\(differing(first[rank].rows, separate[rank].rows)) "
                    + "views_packed_vs_separate_differs=\(differing(packedViews[rank].rows, separateViews[rank].rows)) "
                    + "packed_views_vs_rowmajor_differs=\(differing(packedViews[rank].rows, first[rank].rows)) "
                    + "separate_views_vs_rowmajor_differs=\(differing(separateViews[rank].rows, separate[rank].rows)) "
                    + "tokens_equal=\(first[rank].tokens == separate[rank].tokens)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MOE_GPU"] == "1"))
    func packedSharedExpertCollectiveIsBitIdenticalOnTwoGPURanks() throws {
        let fixture = try Self.syntheticCheckpoint()
        let pair = try pair(device: .gpu) { rank, reduction in
            try QwenTensorParallelModel.assemble(configurationData: fixture.configuration,
                role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                for name in fixture.weights.keys.sorted() { try keep(name, fixture.weights[name]!) }
            }
        }
        let prompt = (0..<40).map { ($0 * 37 + 11) % 256 }
        try checkPackingIsExact(pair, prompt: prompt, chunk: 40, steps: 3, device: .gpu)
    }

    /// The registered artifact's real shards on the GPU, both ranks in one
    /// process (`QWEN_TP_MOE_MODEL` names its directory; an optional
    /// `QWEN_TP_MOE_REQUEST` names a qualification request whose prompt and
    /// chunk size are used, else a synthetic 1,024-token prompt).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MOE_MODEL"] != nil))
    func packedSharedExpertCollectiveIsBitIdenticalOnTheRealArtifact() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["QWEN_TP_MOE_MODEL"]), isDirectory: true)
        var prompt = (0..<1024).map { ($0 * 7919 + 13) % 150_000 }, chunk = 512
        if let path = environment["QWEN_TP_MOE_REQUEST"] {
            let request = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any])
            prompt = try #require(request["promptTokenIDs"] as? [Int])
            chunk = try #require(request["chunkSize"] as? Int)
        }
        let pair = try pair(device: .gpu) { rank, reduction in
            try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: reduction)
        }
        #expect(pair.ranks.allSatisfy { $0.plan.routedExperts && $0.plan.reductionsPerForward == 2 * $0.plan.layerCount })
        let steps = Int(environment["QWEN_TP_MOE_STEPS"] ?? "") ?? 4
        let tokens = try checkPackingIsExact(pair, prompt: prompt, chunk: chunk, steps: steps, device: .gpu)
        print("qwen-moe-tp-packing-real \(directory.lastPathComponent) prompt=\(prompt.count) chunk=\(chunk) "
            + "steps=\(steps) tokens=\(tokens)")
    }

    /// The SDK seam on its own: rows packed behind one expert projection call
    /// inside `carrying`; an element-wise peer sum (what the collective is)
    /// gives every value exactly what two separate collectives give, and a
    /// second projection inside the scope keeps its own collective.
    @Test func carryingPacksRowsBehindItsOwnExpertRowsOnly() throws {
        /// Deterministic values in [-1, 1]: `(i * step + offset) mod m`, centred, over `divisor`.
        func values(_ count: Int, step: Int, offset: Int, modulus: Int, divisor: Float) -> [Float] {
            (0 ..< count).map { index -> Float in
                let integer: Int = (index * step + offset) % modulus - modulus / 2
                return Float(integer) / divisor
            }
        }
        try Device.withDefaultDevice(.cpu) {
            func peer(_ value: MLXArray) -> MLXArray { value * Float(0.75) - Float(0.03125) }
            let weightValues = values(4 * 64 * 128, step: 31, offset: 17, modulus: 257, divisor: 137)
            let weights: MLXArray = MLXArray(weightValues, [4, 64, 128]).asType(.bfloat16)
            let bank = QuantizedSwitchLinear(SwitchLinear(inputDims: 128, outputDims: 64, numExperts: 4,
                weight: weights), groupSize: 64, bits: 4)
            let inputValues = values(8 * 128, step: 19, offset: 3, modulus: 127, divisor: 91)
            let x: MLXArray = MLXArray(inputValues, [8, 1, 128]).asType(.bfloat16)
            let idValues: [UInt32] = (0 ..< 8).map { UInt32($0 % 4) }
            let ids = MLXArray(idValues)
            let rowValues = values(3 * 64, step: 7, offset: 5, modulus: 31, divisor: 193)
            let rows: MLXArray = MLXArray(rowValues, [1, 3, 64])
            var payloads: [[Int]] = []
            let projection = try Qwen35TensorParallelSwitchLinear(bank) { value in
                payloads.append(value.shape)
                return value + peer(value)
            }
            let other = try Qwen35TensorParallelSwitchLinear(bank) { $0 + peer($0) }
            let (output, rowsSum) = projection.carrying(rows) {
                _ = other(x, ids)
                return projection(x, ids)
            }
            let partial = bank(x.asType(.float32), ids)
            let expected = (partial + peer(partial)).asType(.bfloat16), expectedRows = rows + peer(rows)
            eval(output, rowsSum, expected, expectedRows)
            #expect(payloads == [[8 + 3, 64]])
            #expect(output.dtype == .bfloat16 && output.asData().data == expected.asData().data)
            #expect(rowsSum.shape == rows.shape && rowsSum.asData().data == expectedRows.asData().data)
            let alone = projection(x, ids)
            eval(alone)
            #expect(payloads.last == [8, 1, 64] && alone.asData().data == expected.asData().data)
        }
    }

    @Test func routedPlansBindThePackedScheduleAndChargeTopKOncePerLayer() throws {
        let fixture = try Self.syntheticCheckpoint()
        let root = try #require(try JSONSerialization.jsonObject(with: fixture.configuration) as? [String: Any])
        let plan = try QwenTensorParallelPlan(textConfiguration: root["text_config"] as! [String: Any],
            quantization: root["quantization"] as! [String: Any], size: 2)
        #expect(plan.reductionsPerForward == 2 * Self.syntheticLayers)
        #expect(plan.maximumPartialBytesPerToken == (Self.syntheticTopK + 1) * Self.syntheticHidden * 4)
        #expect(plan.layerPartialBytesPerToken == (Self.syntheticTopK + 2) * Self.syntheticHidden * 4)
        #expect(QwenTensorParallelPlan.arithmeticAgreementFields(routedExperts: true)
            == ["qwen-moe-down-projections-f32-sum-before-weighting-packed-v3"])
        #expect(QwenTensorParallelPlan.arithmeticAgreementFields(routedExperts: false).isEmpty)
    }
}
