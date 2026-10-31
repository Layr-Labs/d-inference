import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Actual paired tiny TP shards and paged request histories. No assistant or
/// token publication is simulated. These tests qualify only the new target
/// transaction seam, not RDMA, full-model arithmetic, or throughput.
@Suite(.serialized)
struct QwenTensorParallelBatchMTPWindowTests {
    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var generation = 0, leaving = 0
        private(set) var calls = 0
        func sum(_ input: MLXArray, rank: Int) -> MLXArray {
            let value = input.asArray(Float.self)
            condition.lock()
            let deadline = Date().addingTimeInterval(30)
            while leaving > 0 { precondition(condition.wait(until: deadline)) }
            let entered = generation
            precondition(values[rank] == nil)
            values[rank] = value; shapes[rank] = input.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; condition.broadcast()
            } else {
                while leaving == 0 && generation == entered { precondition(condition.wait(until: deadline)) }
            }
            let output = result; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; result = []; generation += 1; calls += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, input.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private final class Owner: @unchecked Sendable {
        let model: QwenTensorParallelModel, host: CBv2StageKVHost
        var sessions: [QwenTensorParallelBatchSession] = []
        var outputs: [MLXArray] = [], failure: Error?
        init(_ model: QwenTensorParallelModel, width: Int) throws {
            self.model = model
            host = try .init(model: model.model, kind: .paged, lanes: width,
                maximumTokensPerRequest: 256, maximumChunkTokens: 64)
        }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }
    private func paired(_ owners: [Owner], _ body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body)
        owners.forEach { $0.failure = nil }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let failure = owner.failure { throw failure } }
    }
    private func pair(width: Int) throws -> (owners: [Owner], wire: Wire) {
        try pair(rows: Array(0..<width))
    }
    /// One owner pair whose sessions are the fixture's `rows` (each row's
    /// prompt depends only on its index), so a row can be run alone.
    private func pair(rows: [Int]) throws -> (owners: [Owner], wire: Wire) {
        let width = rows.count
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4,
            heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 256; root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let wire = Wire()
        let owners = try (0..<2).map { rank -> Owner in
            let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                for (name, value) in fixture.tensors { try keep(name, value) }
            }
            return try Owner(model, width: width)
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-captured-batch-fixture",
            vocabularySize: 256, hiddenSize: 256, activationDType: "bfloat16",
            maximumPromptTokens: 128, maximumChunkTokens: 64, maximumOutputTokens: 32, maximumContextTokens: 256)
        for (lane, row) in rows.enumerated() {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<(7 + 2 * row)).map { ($0 * 17 + row * 3 + 2) % 256 },
                chunkSize: 5, outputCount: 24, stopTokenIDs: [])
            for owner in owners {
                owner.sessions.append(try .init(model: owner.model, configuration: configuration,
                    host: owner.host, request: request))
            }
            while owners[0].sessions[lane].schedule.committedPromptTokens < request.promptCount {
                try paired(owners) { _ = try $0.sessions[lane].prefill(check: {}) }
            }
        }
        return (owners, wire)
    }
    private func retire(_ owners: [Owner]) throws {
        for owner in owners {
            for session in owner.sessions { try session.retire() }
            owner.outputs = []
            #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
            #expect(owner.sessions.allSatisfy { $0.state.isClosed && $0.state.recurrent.isReleased })
        }
    }
    private func stateBytes(_ session: QwenTensorParallelBatchSession) throws -> [Data] {
        var roots: [MLXArray] = []
        for row in session.state.rows.compactMap({ $0 }) {
            let view = row.snapshot(); roots += [view.keys, view.values]
        }
        let recurrent = try #require(session.state.recurrent.confirmedStateSnapshot())
        #expect(recurrent.count == 3)
        for index in recurrent.keys.sorted() {
            roots += [try #require(recurrent[index]!.conv), try #require(recurrent[index]!.ssm)]
        }
        eval(roots)
        return roots.map { $0.asData(access: .copy).data }
    }
    private func window(_ owners: [Owner], tokens: [[Int]], keeping kept: [Int]) throws {
        try paired(owners) { owner in
            try MLX.withError { error in
                let offsets = owner.sessions.map(\.committedTokens)
                let input = MLXArray(tokens.flatMap { $0.map(Int32.init) }).reshaped([tokens.count, tokens[0].count])
                let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: input)
                #expect(!owner.host.bank.isSerializingMTPRectangularVerification)
                eval(built.outputs + built.roots); try error.check()
                try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: { try error.check() })
                #expect(owner.sessions.map(\.committedTokens) == offsets)
                #expect(built.outputs[0].shape == [tokens.count, tokens[0].count, 128])
                #expect(all(isFinite(built.outputs[0])).item(Bool.self))
                let roots = try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: kept)
                eval(roots); try error.check()
                try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: { try error.check() })
                for (row, session) in owner.sessions.enumerated() {
                    #expect(session.committedTokens == offsets[row] + kept[row])
                    #expect(session.schedule.committedTokens == session.committedTokens)
                }
                owner.outputs = built.outputs
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func unequalHistoriesAndKeepsDiscardRejectedSuffixesAndResumeBatchDecode() throws {
        try Device.withDefaultDevice(.gpu) {
            for width in [2, 4] {
                for columns in [1, 2, 3, 5] {
                    let (first, wire) = try pair(width: width), (poisoned, _) = try pair(width: width)
                    defer { try? retire(first); try? retire(poisoned) }
                    let kept = (0..<width).map { $0 == width - 1 ? columns : min($0 + 1, columns) }
                    let inputs = (0..<width).map { row in (0..<columns).map { (row * 23 + $0 * 11 + 7) % 256 } }
                    let changed = inputs.enumerated().map { row, values in
                        values.enumerated().map { column, value in column < kept[row] ? value : (value + 101) % 256 }
                    }
                    let start = wire.calls
                    try window(first, tokens: inputs, keeping: kept)
                    #expect(wire.calls - start == 8, "One target rectangle, independent of request count")
                    try window(poisoned, tokens: changed, keeping: kept)
                    for rank in 0..<2 {
                        for row in 0..<width {
                            // Same B/S arithmetic; only rejected future tokens
                            // differ. Exact retained history may not see them.
                            let originalState = try stateBytes(first[rank].sessions[row])
                            let changedState = try stateBytes(poisoned[rank].sessions[row])
                            #expect(originalState == changedState)
                            let a = first[rank].outputs[0][row, 0..<kept[row], 0...]
                            let b = poisoned[rank].outputs[0][row, 0..<kept[row], 0...]
                            eval(a, b)
                            #expect(a.asData(access: .copy).data == b.asData(access: .copy).data)
                        }
                    }
                    // Reordering is allowed after the captured cohort closes.
                    let order = Array((0..<width).reversed())
                    for owners in [first, poisoned] {
                        try paired(owners) { owner in
                            owner.outputs = [try QwenTensorParallelBatchSession.decode(order.map { owner.sessions[$0] },
                                tokens: order.map { 19 + $0 }, check: {})]
                        }
                    }
                    for rank in 0..<2 {
                        #expect(first[rank].outputs[0].asData(access: .copy).data
                            == poisoned[rank].outputs[0].asData(access: .copy).data)
                    }
                    try retire(first); try retire(poisoned)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func capturedGreedyChoicesAndContinuationMatchOrdinaryTargetColumns() throws {
        try Device.withDefaultDevice(.gpu) {
            for width in [2, 4] {
                for columns in [1, 2, 3, 5] {
                    let (captured, _) = try pair(width: width), (ordinary, _) = try pair(width: width)
                    defer { try? retire(captured); try? retire(ordinary) }
                    let inputs = (0..<width).map { row in (0..<columns).map { (row * 23 + $0 * 11 + 7) % 256 } }
                    try window(captured, tokens: inputs, keeping: Array(repeating: columns, count: width))
                    // This is an arithmetic gate, separate from custody. A
                    // correct rollback alone cannot prove target token parity
                    // when the projection changes from [B,1] to [B,S].
                    for column in 0..<columns {
                        try paired(ordinary) { owner in
                            owner.outputs = [try QwenTensorParallelBatchSession.decode(owner.sessions,
                                tokens: inputs.map { $0[column] }, check: {})]
                        }
                        let candidate = concatenated(captured.map { $0.outputs[0][0..., column, 0...] }, axis: -1)
                        let reference = concatenated(ordinary.map { $0.outputs[0] }, axis: -1)
                        let actual = argMax(candidate, axis: -1).asType(.int32).asArray(Int32.self)
                        let expected = argMax(reference, axis: -1).asType(.int32).asArray(Int32.self)
                        #expect(actual == expected, "B=\(width) S=\(columns) column=\(column) target choices differ")
                    }
                    for owners in [captured, ordinary] {
                        try paired(owners) { owner in
                            owner.outputs = [try QwenTensorParallelBatchSession.decode(owner.sessions,
                                tokens: (0..<width).map { 31 + $0 }, check: {})]
                        }
                    }
                    let candidate = concatenated(captured.map { $0.outputs[0] }, axis: -1)
                    let reference = concatenated(ordinary.map { $0.outputs[0] }, axis: -1)
                    #expect(argMax(candidate, axis: -1).asType(.int32).asArray(Int32.self)
                        == argMax(reference, axis: -1).asType(.int32).asArray(Int32.self),
                        "B=\(width) S=\(columns) settled continuation differs")
                    try retire(captured); try retire(ordinary)
                }
            }
        }
    }

    /// The hazard itself, in MLX alone: at Qwen27's hidden width (vector
    /// limit 13 on the M5) one 15-row affine product is not the same
    /// arithmetic as the same rows taken three at a time. Without this the
    /// rectangle test below could pass only because no kernel changed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func oneProductOverManyRowsChangesQuantizedArithmetic() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            let linear = QuantizedLinear(weight: random([4096, 5120], seed: 27, scale: 0.02), bias: nil,
                groupSize: 64, bits: 4)
            let x = random([5, 3, 5120], seed: 28, scale: 1)
            let whole = linear(x)
            let rows = concatenated((0..<5).map { linear(x[$0 ..< $0 + 1]) }, axis: 0)
            eval(whole, rows)
            #expect(whole.shape == rows.shape)
            #expect(whole.asData(access: .copy).data != rows.asData(access: .copy).data,
                "15 rows in one product kept the 3-row kernel; the rectangle test would not exercise a switch")
        }
    }

    /// MLX's vector limit as mirrored for shared verify calls: the M3 Ultra
    /// (family 15, Ultra) switches to QMM at 12 rows of Qwen27's widths and
    /// the M5 Max (family 17) at 13. Off the GPU, outside affine mode and for
    /// the 64/128-wide quad kernel every window keeps its own call.
    @Test func vectorLimitMirrorsMLXPerArchitectureAndSharesOnlyOnTheGPU() throws {
        let big = (inputs: 5120, outputs: 6144), medium = (inputs: 4096, outputs: 4096), small = (inputs: 2048, outputs: 2048)
        let expected: [(String, [Int])] = [
            ("applegpu_g15d", [12, 18, 32]), ("applegpu_g17s", [13, 25, 33]), ("applegpu_g16s", [13, 15, 13]),
            ("applegpu_g14s", [6, 10, 14]), ("applegpu_g14d", [12, 18, 32]), ("applegpu_g12x", [10, 12, 18]),
            ("", [10, 12, 18])]
        for (architecture, limits) in expected {
            let got = [big, medium, small].map {
                Qwen35QuantizedVectorLimit.limit(inputs: $0.inputs, outputs: $0.outputs, architecture: architecture)
            }
            #expect(got == limits, "\(architecture)")
        }
        Device.withDefaultDevice(.cpu) {
            #expect(Qwen35QuantizedVectorLimit.sharedWindows(MLXArray.zeros([8, 3, 5120]), outputs: 6144, mode: .affine) == 1)
        }
        Device.withDefaultDevice(.gpu) {
            for columns in 2...5 {
                let shared = Qwen35QuantizedVectorLimit.sharedWindows(MLXArray.zeros([8, columns, 5120]),
                    outputs: 6144, mode: .affine)
                #expect(shared >= 1 && shared * columns < Qwen35QuantizedVectorLimit.limit(inputs: 5120, outputs: 6144))
            }
            #expect(Qwen35QuantizedVectorLimit.sharedWindows(MLXArray.zeros([8, 3, 128]), outputs: 6144, mode: .affine) == 1)
            #expect(Qwen35QuantizedVectorLimit.sharedWindows(MLXArray.zeros([8, 3, 5120]), outputs: 6144, mode: .mxfp4) == 1)
        }
        let rows = Qwen35QuantizedVectorLimit.rows(MLXArray((0..<30).map { Float($0) }, [10, 3, 1]), by: 4) { $0 * 2 }
        #expect(rows.shape == [10, 3, 1] && rows.asArray(Float.self) == (0..<30).map { Float($0 * 2) })
    }

    /// Shared verify calls at Qwen27's projection shapes (hidden into the
    /// attention, recurrent and MLP shards, those shards back to hidden, and a
    /// vocabulary shard of the head): every row of a shared call equals that
    /// row's own `[1, S, H]` call byte for byte, bf16 activations and FP32
    /// partial inputs alike, for every window width.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func sharedWindowCallsKeepEveryRowsQuantizedArithmetic() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            let shapes = [(5120, 6144), (5120, 8704), (8704, 5120), (3072, 5120), (2048, 2048), (5120, 124_160)]
            for (index, (inputs, outputs)) in shapes.enumerated() {
                let linear = QuantizedLinear(weight: random([outputs, inputs], seed: UInt64(40 + index), scale: 0.02),
                    bias: nil, groupSize: 64, bits: 4)
                eval(linear.weight, linear.scales, linear.biases!)
                for columns in 2...5 {
                    for dtype in [DType.bfloat16, .float32] {
                        let x = random([8, columns, inputs], seed: UInt64(90 + 7 * index + columns), scale: 1).asType(dtype)
                        let shared = Qwen35QuantizedVectorLimit.sharedWindows(x, outputs: outputs, mode: .affine)
                        #expect(shared * columns < Qwen35QuantizedVectorLimit.limit(inputs: inputs, outputs: outputs))
                        let together = Qwen35QuantizedVectorLimit.rows(x, by: shared) { linear($0) }
                        let alone = concatenated((0..<8).map { linear(x[$0 ..< $0 + 1]) }, axis: 0)
                        eval(together, alone)
                        #expect(together.shape == alone.shape
                                && together.asData(access: .copy).data == alone.asData(access: .copy).data,
                            "[\(inputs) -> \(outputs)] S=\(columns) \(dtype) shared=\(shared) differs from row-by-row")
                    }
                }
            }
        }
    }

    /// Each GPU family gets the layout measured faster than MLX's own calls
    /// and byte-equal there; unmeasured families keep MLX's calls.
    @Test func wideKernelLayoutFollowsTheMeasuredFamilies() {
        typealias Kernel = Qwen35WideQuantizedKernel
        let one = Kernel.Layout(rowsPerThread: 1, maximumVectors: 8), two = Kernel.Layout(rowsPerThread: 2, maximumVectors: 8)
        #expect(Kernel.layout(input: .bfloat16, architecture: "applegpu_g17s") == one)
        #expect(Kernel.layout(input: .float32, architecture: "applegpu_g17s") == one)
        #expect(Kernel.layout(input: .float32, architecture: "applegpu_g15d") == two)
        #expect(Kernel.layout(input: .bfloat16, architecture: "applegpu_g15d") == nil)
        #expect(Kernel.layout(input: .float32, architecture: "applegpu_g16s") == nil)
        #expect(Kernel.layout(input: .float32, architecture: "applegpu_g14d") == nil)
        #expect(Kernel.layout(input: .float32, architecture: "") == nil)
    }

    /// The wide verify kernel at Qwen27's projection shapes, in both layouts
    /// (one or two output rows a thread) on whatever GPU runs the check: every
    /// row of one call over a cohort's windows equals that row's own MLX call
    /// ([1, S, H], qmv_wide) byte for byte, bf16 activations and FP32 partial
    /// inputs (with bf16 scales, as the row-parallel shards use them), 1-8
    /// rows, S of 2-5.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func wideKernelRowsEqualEachRowsOwnWindowCall() throws {
        try Device.withDefaultDevice(.gpu) {
            func random(_ shape: [Int], seed: UInt64, scale: Float) -> MLXArray {
                withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
            }
            let shapes = [(5120, 6144), (5120, 8704), (8704, 5120), (3072, 5120), (2048, 2048), (5120, 124_160)]
            for (index, (inputs, outputs)) in shapes.enumerated() {
                let linear = QuantizedLinear(weight: random([outputs, inputs], seed: UInt64(140 + index), scale: 0.02),
                    bias: nil, groupSize: 64, bits: 4)
                eval(linear.weight, linear.scales, linear.biases!)
                for columns in 2...5 {
                    for rows in [1, 3, 4, 8] {
                        for dtype in [DType.bfloat16, .float32] {
                            let x = random([rows, columns, inputs], seed: UInt64(190 + 7 * index + columns + 31 * rows),
                                scale: 1).asType(dtype)
                            let alone = concatenated((0..<rows).map { linear(x[$0 ..< $0 + 1]) }, axis: 0)
                            for perThread in [1, 2] {
                                let layout = Qwen35WideQuantizedKernel.Layout(rowsPerThread: perThread, maximumVectors: 8)
                                let wide = try #require(Qwen35WideQuantizedKernel.project(x, weight: linear.weight,
                                    scales: linear.scales, biases: linear.biases, groupSize: 64, bits: 4, mode: .affine,
                                    layout: layout))
                                eval(wide, alone)
                                #expect(wide.shape == alone.shape && wide.dtype == alone.dtype
                                        && wide.asData(access: .copy).data == alone.asData(access: .copy).data,
                                    "[\(inputs) -> \(outputs)] S=\(columns) rows=\(rows) \(dtype) R=\(perThread) differs from each row's own call")
                            }
                        }
                    }
                }
            }
            // Where MLX would not use qmv_wide for one window, the kernel declines in any layout.
            let any = Qwen35WideQuantizedKernel.Layout(rowsPerThread: 1, maximumVectors: 8)
            let small = QuantizedLinear(weight: random([64, 128], seed: 7, scale: 0.02), bias: nil, groupSize: 64, bits: 4)
            #expect(Qwen35WideQuantizedKernel.project(random([2, 3, 128], seed: 8, scale: 1), weight: small.weight,
                scales: small.scales, biases: small.biases, groupSize: 64, bits: 4, mode: .affine, layout: any) == nil)
            let eight = QuantizedLinear(weight: random([64, 256], seed: 9, scale: 0.02), bias: nil, groupSize: 64, bits: 8)
            #expect(Qwen35WideQuantizedKernel.project(random([2, 3, 256], seed: 10, scale: 1), weight: eight.weight,
                scales: eight.scales, biases: eight.biases, groupSize: 64, bits: 8, mode: .affine, layout: any) == nil)
        }
    }

    /// Concurrent verification must not change a request's tokens. Installed
    /// c28 cohorts of four three-column windows (12 rows) left qmv_wide for
    /// split-K QMM on the M3 and changed near-tie tokens; here eight rows of
    /// five columns (40 rows) pass the M5's small-shape vector limit (33).
    /// Every row of the rectangle must equal its own single-request window,
    /// logits and captured hidden, on both ranks, byte for byte.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func everyRectangleRowEqualsItsOwnSingleRequestWindowBitwise() throws {
        try Device.withDefaultDevice(.gpu) {
            for (width, columns) in [(8, 5), (8, 3), (4, 3)] {
                let rows = Array(0..<width)
                let inputs = rows.map { row in (0..<columns).map { (row * 23 + $0 * 11 + 7) % 256 } }
                let (batched, _) = try pair(rows: rows)
                defer { try? retire(batched) }
                try window(batched, tokens: inputs, keeping: Array(repeating: columns, count: width))
                for row in rows {
                    let (alone, _) = try pair(rows: [row])
                    defer { try? retire(alone) }
                    try window(alone, tokens: [inputs[row]], keeping: [columns])
                    for rank in 0..<2 {
                        for output in 0..<2 {
                            let a = batched[rank].outputs[output][row ..< row + 1]
                            let b = alone[rank].outputs[output]
                            eval(a, b)
                            #expect(a.shape == b.shape && a.asData(access: .copy).data == b.asData(access: .copy).data,
                                "B=\(width) S=\(columns) row=\(row) rank=\(rank) output=\(output) differs from its own window")
                        }
                    }
                    try retire(alone)
                }
                try retire(batched)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func capturedCohortCannotBePartiallyFinalizedAndFaultRetiresAllRows() throws {
        try Device.withDefaultDevice(.gpu) {
            for fault in 0..<4 {
                let (owners, _) = try pair(width: 2)
                defer { try? retire(owners) }
                try paired(owners) { owner in
                    let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions,
                        tokens: MLXArray([Int32(7), 11, 13, 17]).reshaped([2, 2]))
                    eval(built.outputs + built.roots)
                    let offsets = owner.sessions.map(\.committedTokens)
                    switch fault {
                    case 0:
                        #expect(throws: ProbeError.self) {
                            try owner.sessions[0].state.confirmWindow(check: {})
                        }
                    case 1:
                        #expect(throws: ProbeError.self) {
                            try QwenTensorParallelBatchSession.confirmWindows(Array(owner.sessions.reversed()), check: {})
                        }
                    case 2:
                        #expect(throws: ProbeError.self) {
                            try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {
                                throw ProbeError("Injected cancellation after common target evaluation")
                            })
                        }
                    default:
                        try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {})
                        #expect(throws: ProbeError.self) {
                            _ = try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: [1, 3])
                        }
                    }
                    #expect(owner.sessions.map(\.committedTokens) == offsets)
                    #expect(throws: ProbeError.self) {
                        _ = try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: [7, 13], check: {})
                    }
                }
                try retire(owners)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func graphConstructionFailurePoisonsAllBoundRowsAndReturnsTheirStorage() throws {
        try Device.withDefaultDevice(.gpu) {
            let (owners, _) = try pair(width: 2)
            defer { try? retire(owners) }
            try paired(owners) { owner in
                let states = owner.sessions.map(\.state), before = states.map(\.committedTokens)
                #expect(throws: ProbeError.self) {
                    _ = try CBv2OwnedRequestState.beginBatchWindow(states, tokenCount: 3) { _, _ in
                        throw ProbeError("Injected failure after all recurrent rows were bound")
                    }
                }
                let allStatesFailed = states.allSatisfy(\.isFailed)
                #expect(allStatesFailed)
                #expect(states.map(\.committedTokens) == before)
                #expect(!owner.host.bank.isSerializingMTPRectangularVerification)
                for state in states { #expect(throws: ProbeError.self) { try state.requireOpen() } }
            }
            try retire(owners)
        }
    }
}
