import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// The share probe a dense Qwen tensor-parallel load runs on each rank before
/// its ready record (`QwenTensorParallelShareProbe`): one rank of a synthetic
/// Qwen 3.5 shard, its reduction switchable around a peer that only counts
/// what would cross. Nothing crosses while the probe runs, the shard reduces
/// through its peer again afterwards, the throwaway request's pages go back,
/// and a refusal or a failure gives no probe instead of failing. Synthetic
/// weights on one Mac: the figures are not a hardware measurement.
/// GatedDelta's recurrence is Metal-only, so the native cases need
/// QWEN_TP_SHARE_PROBE_GPU=1.
@Suite(.serialized)
struct QwenTensorParallelShareProbeTests {
    /// The pair's reduction as far as this rank can see it: every all-sum that would cross is counted.
    private final class Peer: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        private(set) var crossings = 0
        init(rank: Int) { self.rank = rank }
        func allSum(_ value: MLXArray) -> MLXArray { crossings += 1; return value }
    }

    private struct Shard {
        let model: QwenTensorParallelModel
        let reduction: QwenTensorParallelSwitchableReduction
        let peer: Peer
        let configuration: Data
    }

    private func shard(rank: Int) throws -> Shard {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 4096; root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let peer = Peer(rank: rank), reduction = QwenTensorParallelSwitchableReduction(peer)
        let model = try QwenTensorParallelModel.assemble(configurationData: configuration, role: .shard(rank: rank, size: 2),
            reduction: reduction) { _, keep in for (name, value) in fixture.tensors { try keep(name, value) } }
        return .init(model: model, reduction: reduction, peer: peer, configuration: configuration)
    }

    private let profile = try! QwenLayerStageGenerationProfile(identifier: "qwen-tp-share-probe-tiny", vocabularySize: 256,
        hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128, maximumChunkTokens: 64,
        maximumOutputTokens: 128, maximumContextTokens: 512)

    private func measure(_ shard: Shard, windowColumns: Int? = 4, deadline: UInt64 = .max,
                         admit: (Int, Int) throws -> Bool = { _, _ in true }, check: () throws -> Void = {},
                         clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws -> ClusterWorkerShareProbe? {
        try QwenTensorParallelShareProbe.measure(model: shard.model, reduction: shard.reduction,
            configuration: shard.configuration, profile: profile, shares: [1, 1], kind: .paged, windowColumns: windowColumns,
            deadline: deadline, admit: admit, check: check, clock: clock)
    }

    /// No more native memory than a few cast constants is left once the probe returned:
    /// its request's pages and its own KV host (a 64 MiB segment) are gone.
    private func released(since before: Int) -> Bool {
        Memory.cacheMemory == 0 && Memory.activeMemory - before < 16 << 20
    }

    @Test func shareInPerMilleOfTheDividedParts() {
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [2, 1], rank: 0) == 667)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [2, 1], rank: 1) == 333)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [1, 1], rank: 1) == 500)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [1, 3], rank: 1) == 750)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [2, 3], rank: 0) == 400)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [1, 0], rank: 0) == nil)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [1, 1], rank: 2) == nil)
        #expect(QwenTensorParallelShareProbe.sharePerMille(shares: [1, 2000], rank: 0) == nil)
        let plain = QwenTensorParallelShareProbe.requestShape(profile: profile, windowColumns: nil)
        let speculative = QwenTensorParallelShareProbe.requestShape(profile: profile, windowColumns: 5)
        let rounds = QwenTensorParallelShareProbe.warmupRounds + QwenTensorParallelShareProbe.timedRounds
        #expect(plain.prompt == 64 && plain.outputs == 1 + rounds && speculative.outputs == 1 + 6 * rounds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_SHARE_PROBE_GPU"] == "1"))
    func eachRankTimesItsShareAloneAndReleasesItsRequest() throws {
        try Device.withDefaultDevice(.gpu) {
            for rank in 0..<2 {
                let shard = try shard(rank: rank)
                let cacheLimit = Memory.cacheLimit
                Memory.clearCache()
                let before = Memory.activeMemory
                let probe = try #require(try measure(shard))
                print("darkbloom-test-share-probe rank=\(rank) " + QwenTensorParallelShareProbe.line(probe, rank: rank))
                #expect(shard.peer.crossings == 0, "rank \(rank): an all-sum crossed to the peer during the probe")
                #expect(probe.valid && probe.sharePerMille == 500 && probe.rounds == QwenTensorParallelShareProbe.timedRounds
                    && probe.windowColumns == 4)
                #expect((1..<1_000_000).contains(probe.plainStepMicroseconds)
                    && (1..<1_000_000).contains(probe.windowStepMicroseconds ?? 0))
                #expect(released(since: before) && Memory.cacheLimit == cacheLimit && !shard.reduction.local,
                    "rank \(rank): \(Memory.activeMemory - before) bytes and \(Memory.cacheMemory) cached left")
                // Afterwards the shard reduces through its peer again.
                let cache = try shard.model.newCache()
                let logits = shard.model.forwardForRuntime(MLXArray([Int32(3), 5, 7]).reshaped(1, 3), cache: cache)
                eval(logits)
                #expect(shard.peer.crossings > 0)
                // A load that serves no speculative head times the plain step only.
                let plain = try #require(try measure(shard, windowColumns: nil))
                #expect(plain.windowColumns == nil && plain.windowStepMicroseconds == nil && plain.valid)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_SHARE_PROBE_GPU"] == "1"))
    func aRefusalOrAFailureGivesNoProbeAndKeepsNothing() throws {
        try Device.withDefaultDevice(.gpu) {
            let shard = try shard(rank: 1)
            Memory.clearCache()
            let before = Memory.activeMemory
            struct Refused: Error {}
            #expect(try measure(shard, admit: { _, _ in false }) == nil)
            #expect(try measure(shard, admit: { _, _ in throw Refused() }) == nil)
            #expect(try measure(shard, deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) == nil)
            #expect(try measure(shard, windowColumns: 7) == nil)
            // Every round after the warm-up starts past the budget: no figure.
            var tick: UInt64 = 0
            #expect(try measure(shard, clock: { tick += QwenTensorParallelShareProbe.budgetNanoseconds; return tick }) == nil)
            // The load is cancelled midway (its check throws): the request is retired, nothing is kept.
            var calls = 0
            #expect(try measure(shard, check: { calls += 1; if calls == 6 { throw Refused() } }) == nil)
            #expect(calls == 6 && released(since: before) && !shard.reduction.local && shard.peer.crossings == 0)
            // The shard still probes after all of them.
            #expect(try measure(shard)?.valid == true)
        }
    }
}
