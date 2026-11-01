import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Exact vectors on paired tiny TP shards and paged request histories: with
/// every projection on the SDK's batch-invariant kernel
/// (`Qwen35BatchDecodeScope.exactVectors`), a verify window's every position
/// equals the plain decode step that computes the same token (logits, the
/// captured hidden row and the settled history, byte for byte, both ranks),
/// and a decode row equals itself alone. GPU-gated like the other window
/// suites (`QWEN_TP_MTP_GPU=1`).
@Suite(.serialized)
struct QwenTensorParallelExactVectorsTests {
    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var generation = 0, leaving = 0
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
            if leaving == 0 { values = [:]; shapes = [:]; result = []; generation += 1; condition.broadcast() }
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
    /// Both ranks at once, each with exact vectors on (and `arithmetic`, nil:
    /// the family's): task-local choices are set on each rank's own thread.
    private func paired(_ owners: [Owner], arithmetic: AffineQuantizedVectors.Arithmetic? = nil,
                        _ body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body)
        owners.forEach { $0.failure = nil }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
                    QwenTensorParallelBatchSession.$exactVectorsOverride.withValue(true) {
                        do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
                    }
                }
            }
        }
        for owner in owners { if let failure = owner.failure { throw failure } }
    }
    /// One owner pair whose sessions are the fixture's `rows` (each row's
    /// prompt depends only on its index), so a row can be run alone.
    private func pair(rows: [Int]) throws -> [Owner] {
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
            return try Owner(model, width: rows.count)
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-exact-vectors-fixture",
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
        return owners
    }
    private func retire(_ owners: [Owner]) throws {
        for owner in owners {
            for session in owner.sessions { try session.retire() }
            owner.outputs = []
            #expect(owner.host.isDrained)
        }
    }
    private func stateBytes(_ session: QwenTensorParallelBatchSession) throws -> [Data] {
        var roots: [MLXArray] = []
        for row in session.state.rows.compactMap({ $0 }) {
            let view = row.snapshot(); roots += [view.keys, view.values]
        }
        let recurrent = try #require(session.state.recurrent.confirmedStateSnapshot())
        for index in recurrent.keys.sorted() {
            roots += [try #require(recurrent[index]!.conv), try #require(recurrent[index]!.ssm)]
        }
        eval(roots)
        return roots.map { $0.asData(access: .copy).data }
    }
    private static func bytes(_ value: MLXArray) -> Data { eval(value); return value.asData(access: .copy).data }

    /// Rows B by window width S: the window's column c (logits and captured
    /// hidden) equals plain decode step c of the same rows, byte for byte on
    /// both ranks, and the window settled whole leaves the same history bytes
    /// as the S plain steps.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"),
          arguments: AffineQuantizedVectors.Arithmetic.allCases)
    func windowPositionsEqualPlainDecodeStepsBitwise(arithmetic: AffineQuantizedVectors.Arithmetic) throws {
        try Device.withDefaultDevice(.gpu) {
            for (width, columns) in [(1, 2), (1, 4), (1, 5), (2, 4), (3, 3)] {
                let rows = Array(0..<width)
                let inputs = rows.map { row in (0..<columns).map { (row * 23 + $0 * 11 + 7) % 256 } }
                let windowed = try pair(rows: rows), stepped = try pair(rows: rows)
                defer { try? retire(windowed); try? retire(stepped) }
                try paired(windowed, arithmetic: arithmetic) { owner in
                    let tokens = MLXArray(inputs.flatMap { $0.map(Int32.init) }).reshaped([width, columns])
                    let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: tokens)
                    eval(built.outputs + built.roots)
                    try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {})
                    eval(try QwenTensorParallelBatchSession.settleWindows(owner.sessions,
                        keeping: Array(repeating: columns, count: width)))
                    try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: {})
                    owner.outputs = built.outputs
                }
                var stepOutputs: [[(MLXArray, MLXArray)]] = [[], []]
                for column in 0..<columns {
                    try paired(stepped, arithmetic: arithmetic) { owner in
                        let result = try QwenTensorParallelBatchSession.decodeWithHidden(owner.sessions,
                            tokens: inputs.map { $0[column] }, check: {})
                        owner.outputs = [result.logits, result.hidden]
                    }
                    for rank in 0..<2 { stepOutputs[rank].append((stepped[rank].outputs[0], stepped[rank].outputs[1])) }
                }
                for rank in 0..<2 {
                    for column in 0..<columns {
                        let logits = windowed[rank].outputs[0][0..., column, 0...]
                        let hidden = windowed[rank].outputs[1][0..., column ..< column + 1, 0...]
                        #expect(Self.bytes(logits) == Self.bytes(stepOutputs[rank][column].0),
                            "B=\(width) S=\(columns) column=\(column) rank=\(rank) logits differ from the plain step")
                        #expect(Self.bytes(hidden) == Self.bytes(stepOutputs[rank][column].1),
                            "B=\(width) S=\(columns) column=\(column) rank=\(rank) hidden differs from the plain step")
                    }
                    for row in 0..<width {
                        #expect(try stateBytes(windowed[rank].sessions[row]) == stateBytes(stepped[rank].sessions[row]),
                            "B=\(width) S=\(columns) row=\(row) rank=\(rank) settled history differs from the plain steps'")
                    }
                }
                try retire(windowed); try retire(stepped)
            }
        }
    }

    /// A window settled short (the accepted prefix replayed from its
    /// captured inputs) leaves the history the same plain steps leave, byte
    /// for byte, and the next plain step of both agrees bitwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func shortSettledWindowsEqualTheirPlainStepsBitwise() throws {
        try Device.withDefaultDevice(.gpu) {
            for (columns, kept) in [(4, 2), (5, 3), (3, 1), (2, 1)] {
                let inputs = (0..<columns).map { ($0 * 37 + 5) % 256 }
                let windowed = try pair(rows: [0]), stepped = try pair(rows: [0])
                defer { try? retire(windowed); try? retire(stepped) }
                try paired(windowed) { owner in
                    let tokens = MLXArray(inputs.map(Int32.init)).reshaped([1, columns])
                    let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: tokens)
                    eval(built.outputs + built.roots)
                    try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {})
                    eval(try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: [kept]))
                    try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: {})
                }
                for column in 0..<kept {
                    try paired(stepped) { owner in
                        _ = try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: [inputs[column]], check: {})
                    }
                }
                for rank in 0..<2 {
                    #expect(try stateBytes(windowed[rank].sessions[0]) == stateBytes(stepped[rank].sessions[0]),
                        "S=\(columns) kept=\(kept) rank=\(rank) settled history differs from the plain steps'")
                }
                for owners in [windowed, stepped] {
                    try paired(owners) { owner in
                        owner.outputs = [try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: [77], check: {})]
                    }
                }
                for rank in 0..<2 {
                    #expect(Self.bytes(windowed[rank].outputs[0]) == Self.bytes(stepped[rank].outputs[0]),
                        "S=\(columns) kept=\(kept) rank=\(rank) the next step differs")
                }
                try retire(windowed); try retire(stepped)
            }
        }
    }

    /// The fused residual steps (`ResidualRMSNorm`, with the row-parallel
    /// sums' rounding deferred into them) keep every output: plain steps of a
    /// two-row cohort, then a captured window settled short, logits and hidden
    /// rows byte-equal to the unfused forward's on both ranks.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func fusedResidualStepsKeepEveryOutputBitwise() throws {
        try Device.withDefaultDevice(.gpu) {
            let rows = [0, 1]
            var outputs: [[Data]] = [[], []]
            for (side, fused) in [true, false].enumerated() {
                try ResidualRMSNorm.$enabledOverride.withValue(fused) {
                    let owners = try pair(rows: rows)
                    defer { try? retire(owners) }
                    for step in 0..<3 {
                        try paired(owners) { owner in
                            try ResidualRMSNorm.$enabledOverride.withValue(fused) {
                                let result = try QwenTensorParallelBatchSession.decodeWithHidden(owner.sessions,
                                    tokens: rows.map { ($0 * 41 + step * 13 + 9) % 256 }, check: {})
                                owner.outputs = [result.logits, result.hidden]
                            }
                        }
                        for rank in 0..<2 { outputs[side] += owners[rank].outputs.map(Self.bytes) }
                    }
                    try paired(owners) { owner in
                        try ResidualRMSNorm.$enabledOverride.withValue(fused) {
                            let tokens = MLXArray(rows.flatMap { row in (0..<4).map { Int32((row * 19 + $0 * 7 + 3) % 256) } })
                                .reshaped([2, 4])
                            let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: tokens)
                            eval(built.outputs + built.roots)
                            try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {})
                            eval(try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: [2, 3]))
                            try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: {})
                            owner.outputs = built.outputs
                        }
                    }
                    for rank in 0..<2 { outputs[side] += owners[rank].outputs.map(Self.bytes) }
                    try retire(owners)
                }
            }
            #expect(outputs[0].count == outputs[1].count && !outputs[0].isEmpty)
            for (index, pair) in zip(outputs[0], outputs[1]).enumerated() {
                #expect(pair.0 == pair.1, "output \(index) differs between the fused and unfused residual steps")
            }
        }
    }

    /// A plain decode cohort's every row equals the same row decoded alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func decodeRowsEqualTheirSoloStepsBitwise() throws {
        try Device.withDefaultDevice(.gpu) {
            let rows = Array(0..<5)
            let tokens = rows.map { ($0 * 29 + 3) % 256 }
            let batched = try pair(rows: rows)
            defer { try? retire(batched) }
            try paired(batched) { owner in
                owner.outputs = [try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: tokens, check: {})]
            }
            for row in rows {
                let alone = try pair(rows: [row])
                defer { try? retire(alone) }
                try paired(alone) { owner in
                    owner.outputs = [try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: [tokens[row]],
                        check: {})]
                }
                for rank in 0..<2 {
                    #expect(Self.bytes(batched[rank].outputs[0][row ..< row + 1]) == Self.bytes(alone[rank].outputs[0]),
                        "row \(row) rank \(rank) differs from its solo step")
                }
                try retire(alone)
            }
            try retire(batched)
        }
    }
}
