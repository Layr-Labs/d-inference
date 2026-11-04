import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Measured peaks behind the batch ledger's shared terms, on actual paired
/// tiny shards with paged request histories (two in-process GPU ranks, so a
/// measured transient is both ranks' together). Synthetic weights: these
/// check allocation structure, not model quality, RDMA or throughput.
@Suite(.serialized)
struct QwenTensorParallelBatchMemoryTests {
    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var generation = 0, leaving = 0
        func sum(_ input: MLXArray, rank: Int) -> MLXArray {
            let value = input.asArray(Float.self)
            condition.lock()
            let deadline = Date().addingTimeInterval(60)
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
        let model: QwenTensorParallelModel, host: CBv2StageKVHost, configuration: Data
        var sessions: [QwenTensorParallelBatchSession] = []
        var failure: Error?
        init(_ model: QwenTensorParallelModel, configuration: Data, lanes: Int, context: Int) throws {
            self.model = model; self.configuration = configuration
            host = try .init(model: model.model, kind: .paged, lanes: lanes,
                maximumTokensPerRequest: context, maximumChunkTokens: 512)
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

    /// Eight layers (two full-attention, six recurrent), the suites' tiny
    /// geometry: one 256-wide key/value head per rank, like each Qwen27 rank's
    /// two, at a context long enough that a full-history gather is visible.
    private func pair(lanes: Int, context: Int) throws -> [Owner] {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 8, heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 16384; root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let wire = Wire()
        return try (0..<2).map { rank in
            let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                for (name, value) in fixture.tensors { try keep(name, value) }
            }
            return try Owner(model, configuration: configuration, lanes: lanes, context: context)
        }
    }

    private func open(_ owners: [Owner], lanes: Int, prompt: Int, context: Int) throws {
        let chunk = min(512, prompt)
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-batch-memory", vocabularySize: 256,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: prompt, maximumChunkTokens: chunk,
            maximumOutputTokens: context - prompt, maximumContextTokens: context)
        for row in 0..<lanes {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<prompt).map { ($0 * 7 + row * 13 + 3) % 256 }, chunkSize: chunk,
                outputCount: context - prompt, stopTokenIDs: [])
            for owner in owners {
                owner.sessions.append(try .init(model: owner.model, configuration: owner.configuration,
                    host: owner.host, request: request))
            }
        }
    }

    /// Both ranks' temporaries while `body` runs: the peak above the larger of
    /// the settled allocation before and after (pages and pool segments the
    /// step keeps are request state, not transient).
    private func transient(_ owners: [Owner], _ body: @escaping (Owner) throws -> Void) throws -> Int {
        Stream.gpu.synchronize(); Memory.clearCache()
        let before = Memory.activeMemory
        Memory.peakMemory = 0
        try paired(owners, body)
        Stream.gpu.synchronize()
        let peak = Memory.peakMemory
        Memory.clearCache()
        return max(0, peak - max(before, Memory.activeMemory))
    }

    /// The paged batch ledger charges one full-history gather bank for the
    /// whole owner, not one per lane: decode steps and verify windows attend
    /// each lane's pages in place (the fused paged decode kernel, one query
    /// column at a time), and the driver runs at most one prompt frame per
    /// step. Four lanes at a 7.7K history: a four-lane decode step and a
    /// four-lane, four-column verify window each allocate less than one
    /// lane's gather bank (the earlier ledger reserved four on each rank),
    /// and a late prompt frame stays within one bank plus the ledger's
    /// shared prompt transient.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"
        && ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged"))
    func fullHistoryGatherIsOnePromptFramesTransient() throws {
        try Device.withDefaultDevice(.gpu) {
            let lanes = 4, prompt = 7680, context = 7744
            let owners = try pair(lanes: lanes, context: context)
            defer { for owner in owners { for session in owner.sessions { try? session.retire() } } }
            try open(owners, lanes: lanes, prompt: prompt, context: context)
            // One rank's gather bank and prompt transient at this geometry, as
            // the ledger prices them (one key/value head per rank, two layers).
            let geometry = try QwenLongPrefillBudgetGeometry(layers: 8, fullAttentionInterval: 4, hiddenSize: 256,
                queryHeads: 2, kvHeads: 1, headDimension: 256, linearKeyHeads: 1, linearValueHeads: 2,
                linearKeyDimension: 128, linearValueDimension: 128, convolutionKernel: 4)
            let page = CBv2PagedDefaults.pageSize
            let bank = 2 * geometry.attentionLayers * ((context + page - 1) / page) * page * geometry.kvHeads * geometry.headDimension * 2
            let promptTransient = try QwenResidentPrefillTransient.bytes(geometry: geometry, stageHasAttention: true,
                chunkTokens: 512, contextTokens: context)
            var prefill = 0
            for row in 0..<lanes {
                while owners[0].sessions[row].schedule.committedPromptTokens < prompt {
                    let measured = try transient(owners) { _ = try $0.sessions[row].prefill(check: {}) }
                    prefill = max(prefill, measured)
                }
            }
            let decode = try transient(owners) { owner in
                _ = try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: (0..<lanes).map { 11 + $0 }, check: {})
            }
            let window = try transient(owners) { owner in
                try MLX.withError { error in
                    let input = MLXArray((0..<(lanes * 4)).map { Int32(($0 * 29 + 5) % 256) }).reshaped([lanes, 4])
                    let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: input)
                    eval(built.outputs + built.roots); try error.check()
                    try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: { try error.check() })
                    let roots = try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: [1, 2, 3, 4])
                    eval(roots); try error.check()
                    try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: { try error.check() })
                }
            }
            print("darkbloom-batch-gather-memory-v1 lanes=\(lanes) context=\(context) bank_per_rank=\(bank)"
                + " prompt_transient_per_rank=\(promptTransient) prefill_pair=\(prefill) decode_pair=\(decode) window_pair=\(window)")
            // Two ranks measured together: one bank each is 2 * bank.
            #expect(decode < bank, "a decode step gathered a lane's history")
            #expect(window < bank, "a verify window gathered a lane's history")
            #expect(prefill <= 2 * (bank + promptTransient + (16 << 20)), "a prompt frame exceeded one bank and its transient")
            for owner in owners {
                for session in owner.sessions { try session.retire() }
                #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
            }
        }
    }

    /// One `[B, 4]` verify window over the owner's sessions, each row keeping
    /// its own accepted prefix, evaluated and confirmed like an MTP round.
    private func window(_ owners: [Owner], keeping kept: [Int]) throws {
        try paired(owners) { owner in
            try MLX.withError { error in
                let rows = owner.sessions.count
                let input = MLXArray((0..<(rows * 4)).map { Int32(($0 * 37 + 11) % 256) }).reshaped([rows, 4])
                let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions, tokens: input)
                eval(built.outputs + built.roots); try error.check()
                try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: { try error.check() })
                let roots = try QwenTensorParallelBatchSession.settleWindows(owner.sessions, keeping: kept)
                eval(roots); try error.check()
                try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: { try error.check() })
            }
        }
    }

    /// What a session holds after a settled window: its committed conv/SSM
    /// bytes, whether each committed array owns its buffer (no larger than its
    /// own bytes plus MLX's 16 KiB contiguity slack, so no other row's state
    /// is kept alive), and the buffers its window still retains beside it.
    private func held(_ session: QwenTensorParallelBatchSession) throws
        -> (bytes: [Data], committedOwned: Bool, retainedBytes: Int) {
        let recurrent = session.state.recurrent
        let committed = try #require(recurrent.confirmedStateSnapshot())
        var arrays: [MLXArray] = []
        for layer in committed.keys.sorted() { arrays += [committed[layer]!.conv, committed[layer]!.ssm].compactMap { $0 } }
        let values = arrays.map { $0.asData(access: .copy).data }
        func allocated(_ array: MLXArray) throws -> Int {
            eval(array)
            return try #require(try array.evaluatedBufferInfo()).allocatedBytes
        }
        var owned = true
        for array in arrays {
            let own = array.size * array.dtype.size
            if try allocated(array) > ((own + 16_383) / 16_384) * 16_384 + 16_384 { owned = false }
        }
        let retained = try recurrent.retainedTransitionArrays.reduce(0) { $0 + (try allocated($1)) }
        return (values, owned, retained)
    }

    /// A settled cohort row keeps no other row's recurrent state: its
    /// committed conv/SSM arrays own their buffers (a kept state is copied out
    /// of the cohort's final states; a replayed one starts from the row's own
    /// input), for fully and partially accepted rows alike, before and after
    /// its peers retire, and its state is byte-equal to the same row run
    /// alone. What its window still retains (the small transformed inputs,
    /// views of the cohort's arrays, and its own pre-window state) stays within
    /// the per-lane charge: B x S convolution rows plus its own S state rows,
    /// not B x S state rows.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"
        && ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged"))
    func cohortSurvivorKeepsOnlyItsOwnRows() throws {
        try Device.withDefaultDevice(.gpu) {
            let keeps = [4, 2, 1, 3], columns = 4
            // The fixture's per-rank recurrent layer: one 128-wide key head and
            // two value heads, kernel 4; six recurrent layers.
            let convolution = 4 * 3 * (2 * 128 + 2 * 128), ssm = 4 * 2 * 128 * 128, layers = 6
            func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }
            let solo = try pair(lanes: 1, context: 512)
            defer { for owner in solo { for session in owner.sessions { try? session.retire() } } }
            try open(solo, lanes: 1, prompt: 96, context: 512)
            while solo[0].sessions[0].schedule.committedPromptTokens < 96 {
                try paired(solo) { _ = try $0.sessions[0].prefill(check: {}) }
            }
            try window(solo, keeping: [keeps[0]])
            let reference = try solo.map { try held($0.sessions[0]).bytes }
            for width in [2, 4, 8] {
                let owners = try pair(lanes: width, context: 512)
                defer { for owner in owners { for session in owner.sessions { try? session.retire() } } }
                try open(owners, lanes: width, prompt: 96, context: 512)
                for row in 0..<width {
                    while owners[0].sessions[row].schedule.committedPromptTokens < 96 {
                        try paired(owners) { _ = try $0.sessions[row].prefill(check: {}) }
                    }
                }
                try window(owners, keeping: (0..<width).map { keeps[$0 % keeps.count] })
                let charge = layers * (bound(width * columns * convolution) + bound(columns * ssm))
                for owner in owners {
                    for (row, session) in owner.sessions.enumerated() {
                        let value = try held(session)
                        #expect(value.committedOwned, "width \(width) row \(row) keeps a cohort state buffer")
                        #expect(value.retainedBytes <= charge, "width \(width) row \(row) retains \(value.retainedBytes) > \(charge)")
                        print("darkbloom-cohort-retention-v1 width=\(width) row=\(row) keep=\(keeps[row % keeps.count])"
                            + " retained=\(value.retainedBytes) charge=\(charge) cohort_charge=\(layers * (bound(width * columns * convolution) + bound(width * columns * ssm)))")
                    }
                }
                // Peers retire; the survivor's state is unchanged, still its own,
                // and the same bytes as that row's own window.
                for owner in owners { for session in owner.sessions.dropFirst() { try session.retire() } }
                for (rank, owner) in owners.enumerated() {
                    let survivor = try held(owner.sessions[0])
                    #expect(survivor.committedOwned)
                    // Row 0 has the solo run's prompt and window tokens.
                    #expect(survivor.bytes == reference[rank], "width \(width): survivor differs from its solo window")
                }
            }
        }
    }
}
