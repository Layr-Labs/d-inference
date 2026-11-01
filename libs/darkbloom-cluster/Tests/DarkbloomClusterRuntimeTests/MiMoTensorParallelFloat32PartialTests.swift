import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// MiMo V2.6 tensor parallel's arithmetic contract v2: every row-parallel
/// partial (routed expert rows, the dense `down_proj`, `o_proj`) is stored as
/// FP32 and rounded once, after the cross-rank sum. On the GPU's production
/// kernels (the MXFP4 decode-expert kernel for 1 to 7 rows, MLX's sorted
/// gather for prompt rows, NAX at TF32 on M5), two ranks' expert rows add up
/// bit for bit to the exact full-width row, which the single Mac rounds once.
/// The weights and inputs make every sum an exact FP32 integer whose halves
/// need more than BF16's 8 significant bits, so a per-half BF16 store (v1)
/// fails here. Synthetic weights only.
@Suite("MiMo V2.6 tensor-parallel FP32 partials", .serialized)
struct MiMoTensorParallelFloat32PartialTests {
    private typealias Pair = Gemma4TensorParallelLocalPair

    private static let hidden = 1024, width = 1024, experts = 16, topK = 8

    /// The kernel variant's whole model and both ranks, loaded on the GPU.
    private static func models() throws -> (whole: MiMoTensorParallelModel, ranks: [MiMoTensorParallelModel], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-tp-fp32-partials-\(UUID().uuidString)")
        try MiMoTensorParallelModel.writeSyntheticCheckpoint(directory: directory, variant: .kernel)
        let pair = Pair()
        let whole = try MiMoTensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        let ranks = try (0 ..< 2).map {
            try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        }
        return (whole, ranks, directory)
    }

    private static func routed(_ model: MiMoTensorParallelModel, layer: Int = 1) throws -> MiMoV26MoE {
        guard let moe = model.model.model.layers[layer].mlp as? MiMoV26MoE else { throw ProbeError("layer \(layer) is not routed") }
        return moe
    }

    /// Random MXFP4 values (E2M1 times `scale`) with a ±6·scale in every group of 32, so
    /// each group's E8M0 scale is exactly `scale` and quantization is exact.
    private static func exactMXFP4(_ shape: [Int], scale: Float, seed: UInt64) -> MLXArray {
        let keys = MLXRandom.split(key: MLXRandom.key(seed), into: 2)
        let table = MLXArray([0, 0.5, 1, 1.5, 2, 3, 4, 6] as [Float])
        let magnitude = take(table, MLXRandom.randInt(0 ..< 8, shape, key: keys[0]))
        let sign = MLXRandom.randInt(0 ..< 2, shape, key: keys[1]).asType(.float32) * 2 - 1
        let groupLead = (MLXArray(Array(Int32(0) ..< Int32(shape.last!))) % 32) .== 0
        return which(groupLead, MLXArray(Float(6)), magnitude) * sign * scale
    }

    private static func pack(_ values: MLXArray) throws -> (weight: MLXArray, scales: MLXArray) {
        let (weight, scales, _) = quantized(values, groupSize: 32, bits: 4, mode: .mxfp4)
        let back = dequantized(weight, scales: scales, biases: nil, groupSize: 32, bits: 4, mode: .mxfp4, dtype: .float32)
        guard arrayEqual(back, values).item(Bool.self) else { throw ProbeError("the synthetic MXFP4 values must quantize exactly") }
        return (weight, scales)
    }

    /// Installs one packed expert bank into a routed layer, cut for `shard` as the loader cuts it.
    private static func install(_ banks: [String: (weight: MLXArray, scales: MLXArray)], into moe: MiMoV26MoE,
                                shard: MiMoV26TensorShard?) throws {
        var parameters: [(String, MLXArray)] = []
        for (module, bank) in banks {
            let axis = try MiMoV26TensorShard.splitAxis("model.layers.1.mlp.switch_mlp.\(module).weight")
            for (leaf, value) in [("weight", bank.weight), ("scales", bank.scales)] {
                parameters.append(("switch_mlp.\(module).\(leaf)", try shard.map { try $0.slice(value, axis: axis) } ?? value))
            }
        }
        try moe.update(parameters: ModuleParameters.unflattened(parameters), verify: [.noUnusedKeys, .shapeMismatch])
        eval(moe)
    }

    /// Contract v2 is in the plan's arithmetic fields and so in the load agreement and the
    /// plan fingerprint: a rank on v1 (BF16 partials) disagrees and both refuse before loading.
    @Test func theLoadAgreementCarriesContractVersion2() throws {
        let fields = MiMoTensorParallelPlan.arithmeticAgreementFields
        for part in ["o-proj-partial", "dense-down-partial", "expert-rows"] {
            #expect(fields.contains { $0.hasPrefix("mimo-v26-\(part)-stored-float32-") && $0.hasSuffix("-rounded-once-v2") }, "\(part)")
        }
        #expect(!fields.contains { $0.contains("bfloat16") || $0.hasSuffix("-v1") && $0.contains("partial") })
        let plan = try MiMoTensorParallelPlan(configuration: JSONSerialization.data(
            withJSONObject: MiMoTensorParallelModel.syntheticConfiguration(.kernel), options: [.sortedKeys]))
        let agreement = MiMoTensorParallelResidentRuntime.loadAgreementFields(plan: plan, chunkTokens: 16)
        #expect(fields.allSatisfy(agreement.contains) && agreement.contains(plan.fingerprint))
    }

    /// Two ranks' FP32 expert rows sum to the exact full-width row, bit for bit, and the
    /// single Mac's BF16 row is that row rounded once. Rows 1 and 4 run the MXFP4
    /// decode-expert kernel; 16 rows run MLX's sorted gather (NAX at TF32 on M5).
    @Test func rankExpertRowsSumToTheExactFullWidthRow() throws {
        let (whole, ranks, directory) = try Self.models()
        defer { try? FileManager.default.removeItem(at: directory) }
        // gate 12: SiLU(12) rounds to 12 in BF16, so each activation is exactly 12·up (≤ 144).
        let up = Self.exactMXFP4([Self.experts, Self.width, Self.hidden], scale: 2, seed: 21)
        let down = Self.exactMXFP4([Self.experts, Self.hidden, Self.width], scale: 1, seed: 22)
        let banks = [
            "gate_proj": try Self.pack(MLXArray.full([Self.experts, Self.width, Self.hidden], values: MLXArray(Float(12)))),
            "up_proj": try Self.pack(up), "down_proj": try Self.pack(down),
        ]
        try Self.install(banks, into: Self.routed(whole), shard: nil)
        for rank in 0 ..< 2 { try Self.install(banks, into: Self.routed(ranks[rank]), shard: MiMoV26TensorShard(rank: rank)) }

        for rows in [1, 4, 16] {
            // One-hot BF16 rows select one input column per token.
            let columns = (0 ..< rows).map { ($0 * 97 + 5) % Self.hidden }
            var onehot = [Float](repeating: 0, count: rows * Self.hidden)
            for (row, column) in columns.enumerated() { onehot[row * Self.hidden + column] = 1 }
            let x = MLXArray(onehot, [1, rows, Self.hidden]).asType(.bfloat16)
            let chosen = (0 ..< rows).flatMap { row in (0 ..< Self.topK).map { UInt32((row + 2 * $0) % Self.experts) } }
            let indices = MLXArray(chosen, [1, rows, Self.topK])

            let rankRows = try (0 ..< 2).map { try Self.routed(ranks[$0]).switchMLP.float32ExpertRows(x, indices) }
            let product = try Self.routed(whole).switchMLP(x, indices)
            eval(rankRows + [product])
            #expect(rankRows.allSatisfy { $0.dtype == .float32 } && product.dtype == .bfloat16)
            if rows <= 7 {
                // The decode-expert kernel produced these rows (not a fallback).
                let kernel = try #require(MiMoV26DecodeExperts.tryProject(
                    x, indices: indices, glu: Self.routed(ranks[0]).switchMLP, enabled: true, float32Rows: true))
                #expect(arrayEqual(kernel.output, rankRows[0]).item(Bool.self), "\(rows) rows")
            }

            // The exact row on the CPU: every partial sum is an integer below 2^21.
            let reference = Device.withDefaultDevice(.cpu) { () -> MLXArray in
                let selected = MLXArray(chosen.map { Int32($0) })
                let tokenColumns = MLXArray(columns.flatMap { column in [Int32](repeating: Int32(column), count: Self.topK) })
                let activation = (up.transposed(0, 2, 1)[selected, tokenColumns] * 12).expandedDimensions(axis: 1)
                let value = gatherMM(activation, down.swappedAxes(-1, -2), rhsIndices: selected)
                    .reshaped([1, rows, Self.topK, Self.hidden])
                eval(value)
                return value
            }
            func bits(_ value: MLXArray) -> [UInt32] {
                Device.withDefaultDevice(.cpu) { value.asType(.float32).asArray(Float.self).map(\.bitPattern) }
            }
            let combined = rankRows[0] + rankRows[1]
            #expect(bits(combined) == bits(reference), "\(rows) rows: the FP32 sum of both halves is the exact full-width row")
            #expect(bits(product) == bits(reference.asType(.bfloat16)), "\(rows) rows: one Mac rounds that row once")
            // Contract v1 stored each half as BF16 first: that is not the full-width row.
            let halvesRounded = rankRows[0].asType(.bfloat16).asType(.float32) + rankRows[1].asType(.bfloat16).asType(.float32)
            let differ = zip(bits(halvesRounded), bits(reference)).filter { $0 != $1 }.count
            #expect(differ > 0, "\(rows) rows: the data must catch a per-half BF16 rounding")
        }
    }

    /// Every partial a rank hands its sum is FP32 (`o_proj`, the dense and the routed
    /// feed-forward), and the result is rounded once to the activation dtype. The routed
    /// layer's two partials equal the whole layer's FP32 combine up to FP32 reassociation,
    /// far inside the BF16 error per-half rows carried before.
    @Test func everyRankPartialIsFloat32AndRoundsOnceAfterTheSum() throws {
        let (whole, ranks, directory) = try Self.models()
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Recorder: @unchecked Sendable { var dtypes: [DType] = [] }
        let recorder = Recorder()
        let x = withRandomState(MLXRandom.RandomState(seed: 9)) { MLXRandom.normal([1, 3, Self.hidden]) }.asType(.bfloat16)
        var partials: [MLXArray] = []
        for rank in ranks {
            let context = MiMoV26TensorParallelContext(
                reduce: { recorder.dtypes.append($0.dtype); return $0 }, vocabularyRows: rank.vocabularyRange)
            let dense = rank.model.model.layers[0], moe = rank.model.model.layers[1]
            #expect(dense.mlp is MiMoV26DenseMLP)
            let outputs = [
                dense.tensorParallelFeedForward(x, context),
                dense.tensorParallelFeedForward(x, context, rowLocal: true),
                moe.tensorParallelFeedForward(x, context),
            ]
            let installed = moe.tensorParallel
            moe.tensorParallel = context
            let attention = moe.attentionOutput(x, mask: .none, cache: nil)
            moe.tensorParallel = installed
            eval(outputs + [attention])
            #expect((outputs + [attention]).allSatisfy { $0.dtype == .bfloat16 })
            partials.append(try Self.routed(rank).tensorParallelPartial(x))
        }
        #expect(recorder.dtypes == [DType](repeating: .float32, count: 8))
        #expect(partials.allSatisfy { $0.dtype == .float32 })

        let wholeMoE = try Self.routed(whole)
        let route = wholeMoE.gate(x)
        let reference = MiMoV26MoE.combinePartial(wholeMoE.switchMLP.float32ExpertRows(x, route.indices), weights: route.weights)
        let rowsRounded = try (0 ..< 2).map { rank -> MLXArray in
            let rows = try Self.routed(ranks[rank]).switchMLP.float32ExpertRows(x, route.indices)
            return MiMoV26MoE.combinePartial(rows.asType(.bfloat16).asType(.float32), weights: route.weights)
        }
        let scale = abs(reference).max().item(Float.self)
        let error = abs(partials[0] + partials[1] - reference).max().item(Float.self)
        let perHalfError = abs(rowsRounded[0] + rowsRounded[1] - reference).max().item(Float.self)
        #expect(error <= scale * 0x1p-16, "FP32 reassociation only: \(error) of \(scale)")
        #expect(perHalfError > 16 * error, "per-half BF16 rows (v1) err \(perHalfError), FP32 rows \(error)")
    }
}
