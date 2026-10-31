import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

private let hidden = 4096, intermediate = 12288, heads = 16, kvHeads = 4, headDim = 256
private let linearKeyHeads = 16, linearValueHeads = 32, linearDim = 128

// Batch invariance at the registered 9B's shapes (random weights, four layers,
// no artifact). A request's row is bit-identical alone and beside batchmates
// only if every operation of a decode step is. Each probe runs one operation
// on one row and on that row stacked with a different one and compares the
// first row bit for bit; the model probe does the same through the stage KV
// host for both backends. Norms, RoPE with per-row offsets, the depthwise
// convolution and the gated delta step are required to be row invariant; the
// affine quantized projections are reported (MLX routes two or more rows to
// qmv_wide, one row to qmv_fast), and with them the model row.
//
// A diagnosis and contract test on synthetic weights, not a model result.

@Suite("Batch invariance at the registered 9B's shapes (synthetic weights, no artifact)", .serialized)
struct CBv2BatchInvarianceProbeTests {
    static let vocabulary = 1024

    static func bits(_ a: MLXArray) -> [Float] { a.asType(.float32).asArray(Float.self) }

    /// First row alone and the same row beside another: equal bit for bit.
    /// `required` false only reports (a known batch-variant operation).
    @discardableResult
    static func rowInvariant(_ name: String, required: Bool = true, rows: (Int) -> MLXArray,
                             _ op: (MLXArray) -> MLXArray) -> Bool {
        let two = rows(2)
        let alone = op(two[0 ..< 1]), batched = op(two)
        eval(alone, batched)
        let equal = bits(alone) == bits(batched[0 ..< 1])
        print("batch-invariance probe \(name): \(equal ? "identical" : "DIFFERS")")
        if required { #expect(equal, "\(name): a row alone differs from the same row beside a batchmate") }
        return equal
    }

    static func random(_ shape: [Int], seed: UInt64, scale: Float = 1) -> MLXArray {
        withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
    }

    static func quantizedLinear(_ input: Int, _ output: Int, seed: UInt64) -> Linear {
        let quantized = QuantizedLinear(weight: random([output, input], seed: seed, scale: 0.02), bias: nil,
            groupSize: 64, bits: 4)
        eval(quantized)
        return quantized
    }

    @Test func quantizedProjectionsAtDecodeShapes() {
        let cases: [(String, Int, Int)] = [("q_proj 4096->8192", hidden, 2 * heads * headDim),
            ("k_proj 4096->1024", hidden, kvHeads * headDim), ("o_proj 4096->4096", heads * headDim, hidden),
            ("mlp up 4096->12288", hidden, intermediate), ("mlp down 12288->4096", intermediate, hidden),
            ("in_proj_qkv 4096->8192", hidden, 2 * linearKeyHeads * linearDim + linearValueHeads * linearDim),
            ("in_proj_b 4096->32", hidden, linearValueHeads), ("lm_head 4096->1024", hidden, Self.vocabulary)]
        for (index, (name, input, output)) in cases.enumerated() {
            let linear = Self.quantizedLinear(input, output, seed: UInt64(10 + index))
            // MLX sends two or more rows of an affine quantized matmul to
            // qmv_wide (eight lanes reduce K per output) and one row to
            // qmv_fast (32 lanes): reported, not required.
            Self.rowInvariant(name + " [B,1,K]", required: false, rows: { Self.random([$0, 1, input], seed: 99) }) { linear($0) }
            Self.rowInvariant(name + " [B,K]", required: false, rows: { Self.random([$0, input], seed: 98) }) { linear($0) }
        }
    }

    @Test func normsRopeAndConvAtDecodeShapes() {
        let weight = Self.random([hidden], seed: 3, scale: 0.1) + 1
        Self.rowInvariant("rmsNorm [B,1,4096]", rows: { Self.random([$0, 1, hidden], seed: 4) }) {
            MLXFast.rmsNorm($0, weight: weight, eps: 1e-6)
        }
        // Per-row device offsets, as the stage attention passes them.
        Self.rowInvariant("rope array offsets [B,16,1,256]", rows: { Self.random([$0, heads, 1, headDim], seed: 5) }) { x in
            let offsets = MLXArray((0 ..< x.dim(0)).map { Int32(700 + 311 * $0) })
            return MLXFast.RoPE(x, dimensions: headDim / 4, traditional: false, base: 10_000_000, scale: 1, offset: offsets)
        }
        let channels = 2 * linearKeyHeads * linearDim + linearValueHeads * linearDim
        let conv = Conv1d(inputChannels: channels, outputChannels: channels, kernelSize: 4, stride: 1, padding: 0,
            dilation: 1, groups: channels, bias: false)
        try! conv.update(parameters: ModuleParameters.unflattened(["weight": Self.random([channels, 4, 1], seed: 6, scale: 0.3)]),
            verify: [Module.VerifyUpdate.shapeMismatch])
        eval(conv)
        Self.rowInvariant("depthwise conv1d [B,4,8192]", rows: { Self.random([$0, 4, channels], seed: 7) }) { silu(conv($0)) }
    }

    @Test func gatedDeltaStepAtDecodeShapes() {
        let aLog = Self.random([linearValueHeads], seed: 20, scale: 0.5).asType(.float32)
        let dtBias = Self.random([linearValueHeads], seed: 21, scale: 0.5)
        Self.rowInvariant("gated delta T=1 output", rows: { b in
            // Pack q, k, v, a, b and the state rows into one array per row so
            // the probe's row split applies to all of them.
            Self.random([b, 2 * linearKeyHeads * linearDim + linearValueHeads * linearDim + 2 * linearValueHeads], seed: 22)
        }) { packed in
            let b = packed.dim(0)
            let q = packed[0..., 0 ..< (linearKeyHeads * linearDim)].reshaped(b, 1, linearKeyHeads, linearDim)
            let k = packed[0..., (linearKeyHeads * linearDim) ..< (2 * linearKeyHeads * linearDim)]
                .reshaped(b, 1, linearKeyHeads, linearDim)
            let vEnd = 2 * linearKeyHeads * linearDim + linearValueHeads * linearDim
            let v = packed[0..., (2 * linearKeyHeads * linearDim) ..< vEnd].reshaped(b, 1, linearValueHeads, linearDim)
            let a = packed[0..., vEnd ..< (vEnd + linearValueHeads)].reshaped(b, 1, linearValueHeads)
            let beta = packed[0..., (vEnd + linearValueHeads)...].reshaped(b, 1, linearValueHeads)
            // Two state rows always, so the lone row is the batch's first row.
            let state = Self.random([2, linearValueHeads, linearDim, linearDim], seed: 23, scale: 0.1).asType(.float32)
            let (y, next) = gatedDeltaUpdate(q: q, k: k, v: v, a: a, b: beta, aLog: aLog, dtBias: dtBias,
                state: state[0 ..< b])
            return concatenated([y.reshaped(b, -1).asType(.float32), next.reshaped(b, -1)], axis: 1)
        }
    }

    // MARK: Model

    static func configuration(layers: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5_text", "vocab_size": vocabulary, "hidden_size": hidden, "intermediate_size": intermediate,
            "num_hidden_layers": layers, "full_attention_interval": 4, "head_dim": headDim,
            "num_attention_heads": heads, "num_key_value_heads": kvHeads, "linear_conv_kernel_dim": 4,
            "linear_key_head_dim": linearDim, "linear_num_key_heads": linearKeyHeads,
            "linear_num_value_heads": linearValueHeads, "linear_value_head_dim": linearDim,
            "max_position_embeddings": 32_768, "rms_norm_eps": 1e-6, "tie_word_embeddings": false,
            "rope_theta": 10_000_000, "partial_rotary_factor": 0.25, "attention_bias": false,
            "mtp_num_hidden_layers": 0,
        ] as [String: Any], options: [.sortedKeys])
    }

    static func model(layers: Int) throws -> Qwen35TextModel {
        let data = try configuration(layers: layers)
        let model = try withRandomState(MLXRandom.RandomState(seed: 11)) { () -> Qwen35TextModel in
            let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
            var scaled: [String: MLXArray] = [:]
            for (name, value) in model.parameters().flattened() {
                scaled[name] = (MLXRandom.normal(value.shape) * 0.02).asType(.bfloat16)
            }
            try model.update(parameters: ModuleParameters.unflattened(scaled), verify: [.noUnusedKeys, .shapeMismatch])
            return model
        }
        quantize(model: model, groupSize: 64, bits: 4, mode: .affine, filter: { _, module in module is Linear })
        model.freeze(); eval(model)
        return model
    }

    static func geometry(_ model: Qwen35TextModel, layers: Int, host: CBv2StageKVHost) throws -> CBv2RequestGeometry {
        try CBv2RequestGeometry(model: model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model), layerCount: layers,
            vocabularySize: vocabulary, configurationData: configuration(layers: layers), maximumTokens: 2048, host: host)
    }

    static func logits(_ model: Qwen35TextModel, _ tokens: [[Int]], caches: [any CBv2AttendingLayerCache],
                       evaluations: [CBv2RecurrentStateEvaluation]) -> MLXArray {
        let input = MLXArray(tokens.flatMap { $0.map(Int32.init) }).reshaped([tokens.count, tokens[0].count])
        return model.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
            recurrentState: evaluations, positionIds: nil).logits[0..., -1, 0...]
    }

    static func prefilled(_ model: Qwen35TextModel, layers: Int, host: CBv2StageKVHost, prompt: [Int]) throws
        -> (CBv2OwnedRequestState, MLXArray) {
        let state = try CBv2OwnedRequestState(geometry: geometry(model, layers: layers, host: host),
            promptCount: prompt.count, outputCount: 16)
        var offset = 0, last: MLXArray?
        while offset < prompt.count {
            let part = Array(prompt[offset ..< min(prompt.count, offset + 512)])
            last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                logits(model, [part], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
            offset += part.count
        }
        return (state, last!)
    }

    /// One decode step of request A: alone through `run`, alone through
    /// `runBatch`, and beside request B through `runBatch`.
    @Test(arguments: [ClusterStageKVBackendKind.paged, .contiguous])
    func decodeRowAloneEqualsRowInABatch(kind: ClusterStageKVBackendKind) throws {
        let layers = 4
        let model = try Self.model(layers: layers)
        let host = try CBv2StageKVHost(model: model, kind: kind, lanes: 3, maximumTokensPerRequest: 2048,
            maximumChunkTokens: 512)
        let promptA = (0 ..< 600).map { ($0 * 37 + 11) % Self.vocabulary }
        let promptB = (0 ..< 1100).map { ($0 * 53 + 7) % Self.vocabulary }
        let token = 5
        func decodeAlone(batchPath: Bool) throws -> [Float] {
            let (state, _) = try Self.prefilled(model, layers: layers, host: host, prompt: promptA)
            let row: MLXArray
            if batchPath {
                row = try CBv2OwnedRequestState.runBatch([state], tokenCount: 1, check: {}, forward: { caches, evaluations in
                    Self.logits(model, [[token]], caches: caches, evaluations: evaluations)
                }, validateOutput: { _ in })[0 ..< 1]
            } else {
                row = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                    Self.logits(model, [[token]], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
            }
            let values = Self.bits(row)
            try state.retire()
            return values
        }
        let alone = try decodeAlone(batchPath: false)
        let aloneThroughBatch = try decodeAlone(batchPath: true)
        let (a, _) = try Self.prefilled(model, layers: layers, host: host, prompt: promptA)
        let (b, _) = try Self.prefilled(model, layers: layers, host: host, prompt: promptB)
        let rows = try CBv2OwnedRequestState.runBatch([a, b], tokenCount: 1, check: {}, forward: { caches, evaluations in
            Self.logits(model, [[token], [token + 1]], caches: caches, evaluations: evaluations)
        }, validateOutput: { _ in })
        let batched = Self.bits(rows[0 ..< 1])
        try a.retire(); try b.retire()
        print("batch-invariance probe model \(kind): run vs runBatch(1) \(alone == aloneThroughBatch ? "identical" : "DIFFERS"); "
            + "alone vs beside a batchmate \(alone == batched ? "identical" : "DIFFERS")")
        #expect(alone == aloneThroughBatch, "\(kind): one row through runBatch differs from run")
        // Reported only: the quantized projections of two or more rows take
        // MLX's qmv_wide (see quantizedProjectionsAtDecodeShapes).
        #expect(host.isDrained)
    }
}
