import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in census (`GLM53_WINDOW_CENSUS=1`, GPU, the synthetic serving-policy
/// stage of `GLM5NextTensorParallelSpeculationRowsTests`, paged histories;
/// run with `MLX_QMV_BATCH_INVARIANT=1` as every cluster process does): which
/// verification-window widths T give a target row the same bits.
///
/// Each history (40, 63: a page crossing, 2,045: the dense-to-sparse DSA
/// switch inside the window, 2,061: sparse; `GLM53_WINDOW_CENSUS_LONG=1` adds
/// 16,384) is decoded over the same six tokens in windows of several widths.
/// For every position it prints which (T, column) pairs give equal logits,
/// and for every layer which schedules leave equal cache state (the first
/// layer whose state differs locates the op): `E1_CLASS` lines, for the whole
/// stage and for rank 0 of a two-rank split. Asserted with the width-invariant
/// switch (`GLM5NextTextStage.widthInvariantWindows`): T = 2, 3 and 4 at any
/// column are one class. Off, T = 4 differs (the absorbed DSA query product
/// runs `qmm` from four rows); T = 1 differs either way (one-row `qmv` and the
/// one-token kernels), which is why rounds never verify one row. Further
/// censuses print each sublayer's classes and MLX's quantized projection row
/// classes at the GLM tensor-parallel shapes for 1 through 13 rows.
@Suite(.serialized)
struct GLM5NextTensorParallelWindowCensusTests {
    typealias Rows = GLM5NextTensorParallelSpeculationRowsTests
    typealias Paged = GLM5NextTensorParallelPagedKVTests
    static let enabled = ProcessInfo.processInfo.environment["GLM53_WINDOW_CENSUS"] == "1"
    static let long = ProcessInfo.processInfo.environment["GLM53_WINDOW_CENSUS_LONG"] == "1"

    /// Window widths a schedule verifies the six tokens in, in order.
    static let schedules: [[Int]] = [
        [1, 1, 1, 1, 1, 1], [2, 2, 2], [3, 3], [2, 3, 1], [3, 2, 1], [4, 2], [2, 4], [1, 3, 2], [1, 4, 1],
    ]

    struct Position: Hashable { let width: Int; let column: Int }

    /// Every schedule's per-position logits and hidden bytes, keyed by (T, column), and its final layer states.
    static func run(stage: GLM5NextTextStage, base: GLM5NextTextStageCache, account: GLM5NextDSAPageBook.Account?,
                    tokens: [Int], schedule: [Int]) throws
        -> (rows: [(position: Position, logits: Data, hidden: Data)], states: [[Data]]) {
        let cache = base.copy()
        cache.bindPages(to: account)
        var rows: [(position: Position, logits: Data, hidden: Data)] = []
        var at = 0
        for width in schedule {
            let window = MLXArray(tokens[at ..< at + width].map(Int32.init), [1, width])
            let candidate = try stage.prepareVerification(tokens: window, cache: cache)
            guard case .final(let output) = candidate.output else { throw ProbeError("no logits") }
            try candidate.commit(afterEvaluating: Rows.fence)
            for column in 0 ..< width {
                rows.append((Position(width: width, column: column),
                    Rows.bytes(output.logits[0..., column, 0...]), Rows.bytes(output.hidden[0..., column, 0...])))
            }
            at += width
        }
        try Rows.fence(cache.layers.flatMap(\.state))
        return (rows, cache.layers.map { $0.state.map(Rows.bytes) })
    }

    /// Whether every window of `schedule` up to the one holding `position` has
    /// two to four rows (a later position's history is that of such windows).
    static func wideThrough(_ schedule: [Int], position: Int) -> Bool {
        var start = 0
        for width in schedule where start <= position {
            guard (2...4).contains(width) else { return false }
            start += width
        }
        return true
    }

    /// `values` grouped by equal bytes, as class letters in input order.
    static func classes(_ values: [Data]) -> [Character] {
        var seen: [Data] = []
        return values.map { value in
            if let index = seen.firstIndex(of: value) { return Character(UnicodeScalar(65 + index)!) }
            seen.append(value)
            return Character(UnicodeScalar(64 + seen.count)!)
        }
    }

    /// The synthetic serving stage whole, or rank 0 of a two-rank tensor-parallel
    /// split (the real rank's local widths: half the heads and expert channels;
    /// no sum is installed, so each layer continues from its own partial).
    static func stage(sharded: Bool) throws -> GLM5NextTextStage {
        let declared = try Rows.configuration()
        let inventory = try GLM5NextWeightInventory.validate(configuration: declared,
            tensors: GLM5NextWeightInventory.expectedTensors(configuration: declared, storage: .nvfp4Hybrid,
                shard: "rows.safetensors"), storage: .nvfp4Hybrid)
        let resolve: (String) throws -> MLXArray = { name in
            guard let entry = inventory.entries[name] else { throw ProbeError("missing \(name)") }
            return Rows.tensor(entry)
        }
        let text = declared.textConfig
        return try GLM5NextTextStage(plan: .init(configuration: text, layers: 0 ..< text.hiddenLayers,
                shard: sharded ? GLM5NextTensorShard(rank: 0, size: 2) : nil),
            inventory: inventory, tensor: resolve, materializeExpertStack: { eval($0) },
            releaseSourceTensors: { _ in }, executionPolicy: .serving, materializeFusedProjections: { eval($0) })
    }

    @Test(.enabled(if: enabled), arguments: [false, true])
    func windowWidthCensus(sharded: Bool) throws {
        try Device.withDefaultDevice(.gpu) {
            let stage = try Self.stage(sharded: sharded)
            let text = stage.plan.configuration
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            let layerKinds = stage.plan.layers.map { text.layerTypes[$0] == .linearAttention ? "kda" : "dsa" }
            for history in [40, 63, 2_045, 2_061] + (Self.long ? [16_384] : []) {
                let prompt = (0..<history).map { (($0 + 7) * 7919 + history * 31) % text.vocabularySize }
                let tokens = (0..<6).map { (($0 + 1) * 104_729 + history) % text.vocabularySize }
                let pages = GLM5NextPageReservation(pool: pool, account: try pool.reserve(pages:
                    GLM5NextTensorParallelResidentRuntime.historyPages(pool: pool, configuration: text,
                        contextTokens: history + 64, speculative: false) * (Self.schedules.count + 1)))
                let saved = stage.dsaPagePool
                stage.dsaPagePool = pool
                defer { stage.dsaPagePool = saved }
                let base = stage.newCache(account: pages.account)
                for begin in stride(from: 0, to: history, by: 2_048) {
                    let end = min(history, begin + 2_048)
                    let candidate = try stage.prepareForward(tokens: MLXArray(prompt[begin ..< end].map(Int32.init),
                        [1, end - begin]), cache: base, readout: .none)
                    try candidate.commit(afterEvaluating: Rows.fence)
                }
                // Today's arithmetic (printed), then the width-invariant switch (printed and asserted).
                for invariant in [false, true] {
                    stage.widthInvariantWindows = invariant
                    defer { stage.widthInvariantWindows = false }
                    let label = "\(sharded ? "rank0of2" : "whole") history=\(history) width_invariant=\(invariant ? 1 : 0)"
                    let runs = try Self.schedules.map {
                        try Self.run(stage: stage, base: base, account: pages.account, tokens: tokens, schedule: $0)
                    }
                    // Per position: every schedule's (T, column) and its logits class.
                    for position in 0 ..< tokens.count {
                        let entries = runs.map { $0.rows[position] }
                        let logits = Self.classes(entries.map(\.logits)), hidden = Self.classes(entries.map(\.hidden))
                        let line = zip(entries, zip(logits, hidden)).map { entry, value in
                            "T\(entry.position.width)c\(entry.position.column)=\(value.0)"
                                + (value.0 == value.1 ? "" : "/h\(value.1)")
                        }
                        print("E1_CLASS \(label) position=\(position) logits " + line.joined(separator: " "))
                        // T = 2, 3 or 4, any column, after only such windows: one class.
                        let wide = Self.schedules.indices.filter { Self.wideThrough(Self.schedules[$0], position: position) }
                        if invariant {
                            #expect(Set(wide.map { entries[$0].logits }).count <= 1, "\(label) position \(position) T2-T4")
                        }
                    }
                    // Per layer: which schedules leave the same state.
                    for layer in layerKinds.indices {
                        let states = runs.map { Data($0.states[layer].joined()) }
                        let line = zip(Self.schedules, Self.classes(states)).map {
                            $0.0.map(String.init).joined(separator: "+") + "=\($0.1)"
                        }
                        print("E1_CLASS \(label) layer=\(layer) \(layerKinds[layer]) state " + line.joined(separator: " "))
                        // [2,2,2], [3,3], [4,2] and [2,4] verify only windows of two to four rows.
                        if invariant {
                            #expect(Set([states[1], states[2], states[5], states[6]]).count == 1,
                                "\(label) layer \(layer) T2-T4 state")
                        }
                    }
                }
            }
        }
    }

    /// Each sublayer alone at the synthetic stage's widths, over the history
    /// of a 2,061-token prompt (sparse DSA) and of a 40-token one (dense):
    /// the routed MoE (layers 3, 4) and dense MLP (layer 0) row by row (row r
    /// of an M-row call against row r of a two-row call `=`, alone `1`, else
    /// `x`), and the KDA (layer 4) and DSA (layer 3) attention over the
    /// window schedules (classes per position, as `windowWidthCensus`).
    @Test(.enabled(if: enabled))
    func sublayerCensus() throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, _) = try Paged.model()
            let text = stage.plan.configuration
            let routed = GLM5NextExecutionPolicy.serving.routedExperts
            let inputs = (MLXRandom.normal([1, 8, text.hiddenSize], key: MLXRandom.key(5)) * 0.5).asType(.bfloat16)
            try Rows.fence([inputs])
            let rowWise: [(String, (MLXArray) throws -> MLXArray)] = [
                ("moe3", { try (stage.layers[3].mlp as! GLM5NextMoE)($0, routedExperts: routed) }),
                ("moe4", { try (stage.layers[4].mlp as! GLM5NextMoE)($0, routedExperts: routed) }),
                ("dense0", { try (stage.layers[0].mlp as! GLM5NextMLP)($0, routedExperts: routed) }),
            ]
            for (name, apply) in rowWise {
                let alone = try (0 ..< 8).map { Rows.bytes(try apply(inputs[0..., $0 ..< $0 + 1])) }
                let pair = try (0 ..< 8).map { r in
                    Rows.bytes(r < 7 ? try apply(inputs[0..., r ..< r + 2])[0..., 0 ..< 1]
                        : try apply(inputs[0..., 6 ..< 8])[0..., 1 ..< 2])
                }
                let line = try (1...8).map { rows -> String in
                    let value = try apply(inputs[0..., 0 ..< rows])
                    try Rows.fence([value])
                    return "M\(rows):" + (0 ..< rows).map { r in
                        let bytes = Rows.bytes(value[0..., r ..< r + 1])
                        return bytes == pair[r] ? "=" : bytes == alone[r] ? "1" : "x"
                    }.joined()
                }
                print("E1_CLASS sublayer=\(name) " + line.joined(separator: " "))
            }
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            let saved = stage.dsaPagePool
            stage.dsaPagePool = pool
            defer { stage.dsaPagePool = saved }
            let windows = (MLXRandom.normal([1, 6, text.hiddenSize], key: MLXRandom.key(9)) * 0.5).asType(.bfloat16)
            for history in [40, 2_061] {
                let prompt = (0..<history).map { (($0 + 7) * 7919 + history * 31) % text.vocabularySize }
                let pages = GLM5NextPageReservation(pool: pool, account: try pool.reserve(pages:
                    GLM5NextTensorParallelResidentRuntime.historyPages(pool: pool, configuration: text,
                        contextTokens: history + 64, speculative: false) * (Self.schedules.count + 1)))
                let base = stage.newCache(account: pages.account)
                let candidate = try stage.prepareForward(tokens: MLXArray(prompt.map(Int32.init), [1, history]),
                    cache: base, readout: .none)
                try candidate.commit(afterEvaluating: Rows.fence)
                for (name, layer) in [("kda4", 4), ("dsa3", 3)] {
                    let rows = try Self.schedules.map { schedule -> [Data] in
                        let cache = base.copy()
                        cache.bindPages(to: pages.account)
                        var values: [Data] = [], at = 0
                        for width in schedule {
                            let x = windows[0..., at ..< at + width]
                            let validity = MLXArray.ones([1, width], dtype: .bool)
                            let output: MLXArray
                            if let kda = stage.layers[layer].attention as? GLM5NextKDASublayer,
                               let state = cache.layers[layer] as? GLM5NextKDACache {
                                output = try kda.forward(x, cache: state, validity: validity, captureWindow: true)
                            } else if let dsa = stage.layers[layer].attention as? GLM5NextDSAAttention,
                                      let state = cache.layers[layer] as? GLM5NextDSACache {
                                output = try dsa.forward(x, cache: state, validity: validity)
                            } else { throw ProbeError("census layer kind") }
                            try Rows.fence([output])
                            values += (0 ..< width).map { Rows.bytes(output[0..., $0 ..< $0 + 1]) }
                            at += width
                        }
                        return values
                    }
                    for position in 0 ..< 6 {
                        let classes = Self.classes(rows.map { $0[position] })
                        let line = zip(Self.schedules, classes).map { schedule, value -> String in
                            var start = 0, width = 0
                            for w in schedule where start <= position { width = w; start += w }
                            return "T\(width)c\(position - (start - width))=\(value)"
                        }
                        print("E1_CLASS sublayer=\(name) history=\(history) position=\(position) "
                            + line.joined(separator: " "))
                    }
                }
            }
        }
    }

    /// MLX's quantized `x @ w.T` at the GLM tensor-parallel rank shapes:
    /// row r of an M-row product against row r of the two-row (`qmv_wide`)
    /// product (`=`) or the one-row (`qmv`, `1`), else `x`. Rows 2 through the
    /// vector limit less one are one class under `MLX_QMV_BATCH_INVARIANT=1`.
    @Test(.enabled(if: enabled))
    func projectionRowCensus() throws {
        try Device.withDefaultDevice(.gpu) {
            // (name, input, output, mode): KDA fused inputs and output, DSA q_b
            // and output, dense gate/up and down, the head's vocabulary half.
            let shapes: [(String, Int, Int, QuantizationMode)] = [
                ("kda.in", 4096, 12_576, .affine), ("kda.o", 4096, 4096, .affine), ("dsa.q_b", 1536, 8192, .affine),
                ("dsa.o", 8192, 4096, .affine), ("dense.gate_up", 4096, 12_288, .nvfp4), ("dense.down", 6144, 4096, .nvfp4),
                ("head.half", 4096, 77_440, .affine),
            ]
            let key = MLXRandom.key(17)
            for (name, input, output, mode) in shapes {
                let weight = (MLXRandom.normal([output, input], key: key) * 0.02).asType(.bfloat16)
                let groupSize = mode == .nvfp4 ? 16 : 64
                let q = quantized(weight, groupSize: groupSize, bits: 4, mode: mode)
                let x = MLXRandom.normal([13, input], key: MLXRandom.key(UInt64(input))).asType(.bfloat16)
                func product(_ rows: Range<Int>) -> MLXArray {
                    quantizedMM(x[rows], q.wq, scales: q.scales, biases: q.biases, transpose: true,
                        groupSize: groupSize, bits: 4, mode: mode)
                }
                // Row r alone (`qmv`) and among two rows (`qmv_wide`).
                let alone = (0 ..< 13).map { Rows.bytes(product($0 ..< $0 + 1)) }
                let wide = (0 ..< 13).map { r in
                    Rows.bytes(r < 12 ? product(r ..< r + 2)[0 ..< 1] : product(11 ..< 13)[1 ..< 2])
                }
                var line: [String] = []
                for rows in 1...13 {
                    let value = product(0 ..< rows)
                    try Rows.fence([value])
                    let marks = (0 ..< rows).map { r -> String in
                        let bytes = Rows.bytes(value[r ..< r + 1])
                        return bytes == wide[r] ? "=" : bytes == alone[r] ? "1" : "x"
                    }
                    line.append("M\(rows):" + marks.joined())
                }
                print("E1_CLASS projection=\(name) \(input)x\(output) " + line.joined(separator: " "))
            }
        }
    }
}
