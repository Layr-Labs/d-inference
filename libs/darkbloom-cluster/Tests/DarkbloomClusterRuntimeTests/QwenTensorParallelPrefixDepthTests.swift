import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Prompt prefixes kept to the request's context on the 512-token grid
/// (`QwenTensorParallelBatchPrefixBudget`): a restore at a deep boundary is
/// a cold prefill on the same grid, byte for byte, on both ranks (final
/// logits, every attention row, every convolution and SSM state), for each
/// case one Mac reuses: a repeat, the next turn, a shared system prompt.
/// GatedDelta's recurrence is Metal-only, so the hybrid shards run on the GPU.
@Suite(.serialized, .boundedBufferCache)
struct QwenTensorParallelPrefixDepthTests {
    private final class Rendezvous: @unchecked Sendable {
        let condition = NSCondition()
        var step = 0, leaving = 0
        var inputs: [Int: [Float]] = [:]
        var result: [Float] = []
        func sum(_ array: MLXArray, rank: Int) -> MLXArray {
            let values = array.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            inputs[rank] = values
            if inputs.count == 2 {
                result = zip(inputs[0]!, inputs[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(120)
                while leaving == 0 && step == generation {
                    precondition(condition.wait(until: deadline), "TP rank failed to meet its peer")
                }
            }
            let output = result
            leaving -= 1
            if leaving == 0 { inputs = [:]; result = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, array.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        let shared: Rendezvous
        init(_ rank: Int, _ shared: Rendezvous) { self.rank = rank; self.shared = shared }
        func allSum(_ value: MLXArray) -> MLXArray { shared.sum(value, rank: rank) }
    }
    private struct Reservation: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64 = .max
        var laneStateBytes: Int { 1 }
        var joinable: Bool { true }
    }
    private final class Owned: @unchecked Sendable {
        let model: QwenTensorParallelModel
        let host: CBv2StageKVHost
        var executor: QwenTensorParallelNativeBatchExecutor<Reservation>?
        var lane: QwenTensorParallelNativeBatchLane?
        var output: MLXArray?
        var token = 0
        var failure: Error?
        init(_ model: QwenTensorParallelModel, maximumTokens: Int) throws {
            self.model = model
            host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                maximumTokensPerRequest: maximumTokens, maximumChunkTokens: 512)
        }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owned) throws -> Void
        init(_ body: @escaping (Owned) throws -> Void) { self.body = body }
    }
    private let ranks = TensorParallelRankThreads()
    private func parallel(_ owners: [Owned], body: @escaping (Owned) throws -> Void) throws {
        let work = Work(body)
        ranks.run { rank in
            Device.withDefaultDevice(.gpu) {
                do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let error = owner.failure { owner.failure = nil; throw error } }
    }
    private func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }

    private static let context = 33_400
    private static func allocationBound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    /// A pair of shards of one tiny hybrid checkpoint (three GatedDelta layers,
    /// one attention layer); with `caches`, each rank keeps prompt prefixes
    /// charged by the real per-request rule on its own heads. LOAD's memory
    /// plan is shorter than the requests, as the 27B's is beside its native
    /// context: boundaries still go to each request's own context.
    private func pair(_ configuration: Data, _ tensors: [(String, MLXArray)],
                      caches: [QwenTensorParallelBatchPrefixCache]?) throws -> [Owned] {
        let wire = Rendezvous()
        return try (0..<2).map { rank in
            let reduction = Rank(rank, wire)
            let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                for (name, value) in tensors { try keep(name, value) }
            }
            let owner = try Owned(model, maximumTokens: Self.context)
            let geometry = try Self.geometry(configuration, model, rank: rank)
            owner.executor = try .init(model: model, configuration: configuration, host: owner.host, group: reduction,
                prepare: { _, _ in nil }, completedDecode: { _ in }, completedPrefill: {}, releaseResources: { _ in },
                prefix: caches?[rank],
                prefixBudget: caches == nil ? nil : .init(maximumTokens: 8_192, captureBytes: 0, geometry: geometry),
                prefixScope: caches == nil ? nil : { _ in "depth-load|chunk=512|kv=paged|text" },
                allocationBound: caches == nil ? nil : { Self.allocationBound($0) })
            return owner
        }
    }

    /// A rank's own heads of the checkpoint's budget geometry.
    private static func geometry(_ configuration: Data, _ model: QwenTensorParallelModel, rank: Int) throws
        -> QwenLongPrefillBudgetGeometry {
        let root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
        let text = root["text_config"] as! [String: Any]
        let plan = model.plan
        return try QwenLongPrefillBudgetGeometry(layers: plan.layerCount,
            fullAttentionInterval: plan.fullAttentionInterval, hiddenSize: plan.hiddenSize,
            queryHeads: plan.attentionHeads, kvHeads: plan.kvHeads, headDimension: plan.headDim,
            linearKeyHeads: plan.linearKeyHeads, linearValueHeads: plan.linearValueHeads,
            linearKeyDimension: plan.linearKeyHeadDim, linearValueDimension: plan.linearValueHeadDim,
            convolutionKernel: text["linear_conv_kernel_dim"] as! Int).tensorParallelShard(plan: plan, rank: rank)
    }

    private func request(_ tokens: [Int], profile: QwenLayerStageGenerationProfile) throws -> QwenLayerStageGenerationRequest {
        try .init(profile: profile, requestID: UUID(), promptTokenIDs: tokens, chunkSize: 512, outputCount: 4, stopTokenIDs: [])
    }

    /// Serves `tokens` to its first token and retires cleanly, so each rank
    /// keeps what it captured; returns what each rank restored and kept.
    private func donate(_ owners: [Owned], _ request: QwenLayerStageGenerationRequest) throws -> (restored: [Int], stored: [[Int]]) {
        try parallel(owners) { $0.lane = try $0.executor!.open(.init(request: request), check: {}) }
        let restored = owners.map { $0.lane!.committedTokens }
        while owners[0].lane!.nextFrame?.phase == .prefill {
            try parallel(owners) { owner in
                let lane = owner.lane!
                if let token = try owner.executor!.prefill(lane, frame: lane.nextFrame!, check: {}) { owner.token = token }
            }
        }
        for owner in owners { try owner.executor!.retire(owner.lane!, reason: .clientStop, selected: 1, last: owner.token) }
        for owner in owners { try owner.executor!.confirmedRetirement(owner.lane!, clean: true) }
        #expect(owners[0].token == owners[1].token && owners.allSatisfy { $0.host.isDrained })
        return (restored, owners.map { $0.lane!.storedPrefixFrontiers })
    }

    /// Opens `request` on both pairs, prefills both to the prompt's end and
    /// compares, rank by rank, the final logits, every attention row and
    /// every recurrent state; returns what the warm pair restored.
    private func compare(_ cold: [Owned], _ warm: [Owned], _ request: QwenLayerStageGenerationRequest,
                         label: String) throws -> [Int] {
        try parallel(cold) { $0.lane = try $0.executor!.open(.init(request: request), check: {}) }
        try parallel(warm) { $0.lane = try $0.executor!.open(.init(request: request), check: {}) }
        let restored = warm.map { $0.lane!.committedTokens }
        #expect(cold.allSatisfy { $0.lane!.committedTokens == 0 })
        for owners in [cold, warm] {
            while owners[0].lane!.nextFrame?.phase == .prefill {
                try parallel(owners) { $0.output = try $0.lane!.session.prefill(check: {}) }
            }
        }
        for rank in 0..<2 {
            let a = cold[rank].lane!.session.state, b = warm[rank].lane!.session.state
            #expect(bytes(cold[rank].output!) == bytes(warm[rank].output!), "\(label) logits rank=\(rank)")
            #expect(a.committedTokens == request.promptCount && b.committedTokens == request.promptCount)
            for (x, y) in zip(a.rows, b.rows) {
                #expect(bytes(x!.snapshot().keys) == bytes(y!.snapshot().keys), "\(label) keys rank=\(rank)")
                #expect(bytes(x!.snapshot().values) == bytes(y!.snapshot().values), "\(label) values rank=\(rank)")
            }
            let x = a.recurrent.confirmedStateSnapshot() ?? [:], y = b.recurrent.confirmedStateSnapshot() ?? [:]
            #expect(!x.isEmpty && x.keys.sorted() == y.keys.sorted())
            for index in x.keys {
                #expect(bytes(x[index]!.conv!) == bytes(y[index]!.conv!), "\(label) conv \(index) rank=\(rank)")
                #expect(bytes(x[index]!.ssm!) == bytes(y[index]!.ssm!), "\(label) ssm \(index) rank=\(rank)")
            }
        }
        for owner in cold + warm {
            try owner.executor!.retire(owner.lane!, reason: nil, selected: 0, last: nil)
            #expect(owner.host.isDrained)
        }
        return restored
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func deepRestoresEqualColdPrefillOnBothRanks() throws {
        try Device.withDefaultDevice(.gpu) {
            let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 65_536
            root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-depth-tiny", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 33_300,
                maximumChunkTokens: 512, maximumOutputTokens: 4, maximumContextTokens: Self.context)
            var seed: UInt64 = 0x5eed
            func tokens(_ count: Int) -> [Int] {
                (0..<count).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % 256 }
            }
            let caches = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 1 << 30) }
            let warm = try pair(configuration, fixture.tensors, caches: caches)
            let cold = try pair(configuration, fixture.tensors, caches: nil)
            // The donor: 33,000 tokens keep the 4,096 stripe and the deepest
            // whole chunk before the final token, within each rank's charge.
            let donor = tokens(33_000)
            let kept = QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: donor.count, chunkSize: 512)
            #expect(kept == [4_096, 8_192, 12_288, 16_384, 20_480, 24_576, 28_672, 32_768])
            let first = try donate(warm, try request(donor, profile: profile))
            #expect(first.restored == [0, 0] && first.stored == [kept, kept])
            // What each rank keeps is within the charge its request was priced at.
            for (rank, owner) in warm.enumerated() {
                let charge = try QwenTensorParallelBatchPrefixBudget.captureBytes(
                    geometry: try Self.geometry(configuration, owner.model, rank: rank), promptCount: donor.count,
                    chunkSize: 512, allocationBound: { Self.allocationBound($0) })
                #expect(caches[rank].bytesInUse > 0 && caches[rank].bytesInUse <= charge)
            }
            // (a) The repeat restores the deepest boundary, 32,768.
            #expect(try compare(cold, warm, request(donor, profile: profile), label: "repeat") == [32_768, 32_768])
            // (b) The next turn, whose template re-rendered the last 40 tokens
            // of a 32,801-token prompt: the margin boundary 32,256 below the
            // deepest, 32,768, which the turn no longer shares.
            let turn = Array(donor[0..<32_801])
            let second = try donate(warm, try request(turn, profile: profile))
            #expect(second.restored == [32_768, 32_768] && second.stored == [[], []])
            for cache in caches { cache.sweep() }
            _ = try donate(warm, try request(turn, profile: profile))
            #expect(caches.allSatisfy { $0.heldFrontiers.contains(32_256) && $0.heldFrontiers.contains(32_768) })
            let next = Array(turn[0..<32_761]) + tokens(300)
            #expect(try compare(cold, warm, request(next, profile: profile), label: "turn") == [32_256, 32_256])
            // (c) Prompts sharing only a system prompt of 16,500 or 8,300
            // tokens: the stripe boundaries 16,384 and 8,192.
            #expect(try compare(cold, warm, request(Array(donor[0..<16_500]) + tokens(700), profile: profile),
                label: "system16k") == [16_384, 16_384])
            #expect(try compare(cold, warm, request(Array(donor[0..<8_300]) + tokens(400), profile: profile),
                label: "system8k") == [8_192, 8_192])
            // One rank's loss of its tier: both ranks prefill from zero.
            caches[0].sweep()
            #expect(try compare(cold, warm, request(turn, profile: profile), label: "one-sided") == [0, 0])
            for cache in caches { cache.sweep() }
        }
    }
}
