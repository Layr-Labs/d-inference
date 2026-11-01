import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// MiMo V2.6 tensor parallel's resident path: the verified load (the manifest
/// first, then only this rank's byte runs), the paged request engine (per-rank
/// paged KV, the per-step agreement sum, stops, the selection rules and
/// logprobs) on two real ranks (two threads whose all-sum adds both ranks'
/// FP32 elements), the load agreement, the request budget and the text-only
/// launch. CPU only; synthetic weights, never a model pass.
@Suite("MiMo V2.6 tensor-parallel resident path", .serialized)
struct MiMoTensorParallelResidentTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static func synthetic() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-tp-resident-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try MiMoTensorParallelModel.writeSyntheticCheckpoint(directory: directory, variant: .tiny)
        }
        return directory
    }

    /// Longer than the 8-token window, in 4-token chunks.
    private static let prompt = (0 ..< 12).map { ($0 * 37 + 11) % 512 }

    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    private static func ranks(_ directory: URL, pair: Pair) throws -> Box<[MiMoTensorParallelModel]> {
        Box(try (0 ..< 2).map { rank in
            try Device.withDefaultDevice(.cpu) {
                try MiMoTensorParallelModel.loadVerified(modelDirectory: directory, role: .shard(rank: rank),
                                                         reduction: pair.reduction(rank: rank)).model
            }
        })
    }

    // MARK: - Verified load

    /// Each rank reads exactly its shard's bytes (half of every divided
    /// tensor, all of every replicated one, nothing of an excluded component)
    /// and holds what the whole-tensor path cuts, bit for bit.
    @Test func verifiedLoadReadsOnlyThisRanksByteRuns() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration,
                                                    hashingConcurrency: 2)
            let plan = try MiMoTensorParallelPlan(configuration: configuration)
            let stored = try tensorDescriptors(checkpoint: checkpoint,
                                               scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
            let pair = Pair()
            for rank in 0 ..< 2 {
                var reads: [String: Int] = [:]
                let loaded = try MiMoTensorParallelVerifiedLoad.load(checkpoint: checkpoint,
                    configurationData: configuration, role: .shard(rank: rank), reduction: pair.reduction(rank: rank),
                    beforeRead: { reads[$0] = $1 })
                let receipt = loaded.receipt
                #expect(receipt.excludedTensors == 2 && receipt.textTensors == reads.count && receipt.rank == rank)
                #expect(receipt.readBytes == reads.values.reduce(0, +))
                #expect(receipt.readBytes == loaded.model.loadedParameterBytes && receipt.readBytes < receipt.textBytes)
                #expect(receipt.verifiedAggregateSHA256 == checkpoint.aggregate && receipt.planFingerprint == plan.fingerprint)
                for (name, bytes) in reads {
                    let whole = try #require(stored[name]).byteCount
                    switch try plan.disposition(of: name) {
                    case .divided: #expect(bytes * 2 == whole, "\(name)")
                    case .replicated: #expect(bytes == whole, "\(name)")
                    case .excluded: Issue.record("\(name) belongs to an excluded component and was read")
                    }
                }
                let direct = try MiMoTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                              reduction: pair.reduction(rank: rank))
                let expected = Dictionary(uniqueKeysWithValues: direct.model.parameters().flattened())
                let actual = Dictionary(uniqueKeysWithValues: loaded.model.model.parameters().flattened())
                #expect(Set(expected.keys) == Set(actual.keys))
                for (key, value) in expected {
                    let part = try #require(actual[key])
                    #expect(part.shape == value.shape && part.dtype == value.dtype
                        && arrayEqual(part, value).item(Bool.self), "\(key) rank \(rank)")
                }
            }
        }
    }

    /// A byte changed after the manifest is refused by the whole-artifact
    /// hash; a text tensor of another shape, or a name the plan does not
    /// know, is refused under a manifest that matches it.
    @Test func verifiedLoadRefusesTamperedAndForeignCheckpoints() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let weights = directory.appendingPathComponent("model.safetensors")
            let original = try loadArrays(url: weights)
            var changed = try Data(contentsOf: weights)
            changed[changed.count / 2] ^= 1
            try changed.write(to: weights)
            #expect(throws: (any Error).self) {
                _ = try MiMoTensorParallelModel.loadVerified(modelDirectory: directory, role: .full, reduction: nil)
            }
            let edits: [(String, (inout [String: MLXArray]) -> Void)] = [
                ("a sink bias of another shape", {
                    $0["language_model.model.layers.1.self_attn.attention_sink_bias"] = MLXArray.zeros([6], dtype: .bfloat16)
                }),
                ("an unknown text tensor", {
                    $0["language_model.model.layers.0.self_attn.rotary.weight"] = MLXArray.zeros([4], dtype: .bfloat16)
                }),
            ]
            for (label, edit) in edits {
                var arrays = original
                edit(&arrays)
                try save(arrays: arrays, url: weights)
                let index: [String: Any] = ["metadata": [:] as [String: Any],
                    "weight_map": Dictionary(uniqueKeysWithValues: arrays.keys.map { ($0, "model.safetensors") })]
                try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
                try MiMoTensorParallelModel.writeSyntheticManifest(directory: directory,
                    files: ["config.json", "model.safetensors", "model.safetensors.index.json"])
                #expect(throws: (any Error).self, "\(label)") {
                    _ = try MiMoTensorParallelModel.loadVerified(modelDirectory: directory, role: .shard(rank: 1),
                                                                 reduction: Pair().reduction(rank: 1))
                }
            }
        }
    }

    // MARK: - The paged request engine

    /// Two ranks on paged KV agree bit for bit, and each equals its own run
    /// on the ordinary caches: tokens, top logits and log probabilities,
    /// every step's row and the cache digests. Each step takes one agreement
    /// sum (two ranks x [value, token, stop, position]); the request ends
    /// with one more. Each rank's pages hold its KV heads at key and value
    /// widths and keep the sliding layers' window.
    @Test func pagedRanksAgreeAndEqualTheOrdinaryCaches() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = try Self.ranks(directory, pair: pair)
        let steps = 6
        let paged = try Pair.run(device: .cpu) { rank in
            try models.value[rank].generatePaged(prompt: Self.prompt, outputCount: steps, chunk: 4, recordTop: 4)
        }
        let payloads = pair.payloads
        let ordinary = try Pair.run(device: .cpu) { rank in
            try models.value[rank].generate(prompt: Self.prompt, outputCount: steps, chunk: 4, recordTop: 4)
        }
        for rank in 0 ..< 2 {
            #expect(paged[rank].tokenIDs == ordinary[rank].tokenIDs)
            #expect(Self.bits(paged[rank].topLogits) == Self.bits(ordinary[rank].topLogits))
            #expect(Self.bits(paged[rank].topLogprobs) == Self.bits(ordinary[rank].topLogprobs))
            #expect(paged[rank].stepRowSHA256 == ordinary[rank].stepRowSHA256 && paged[rank].stepRowSHA256.count == steps)
            #expect(paged[rank].cacheSHA256 == ordinary[rank].cacheSHA256)
        }
        #expect(paged[0].tokenIDs == paged[1].tokenIDs && paged[0].stepRowSHA256 == paged[1].stepRowSHA256)
        let plan = models.value[0].plan
        let forwards = (Self.prompt.count + 3) / 4 + steps - 1
        #expect(payloads.count == forwards * plan.reductionsPerForward + steps * 3 + 1)
        #expect(payloads.filter { $0 == [2 * MiMoTensorParallelDecoding.agreementSlots] }.count == steps)
        #expect(payloads.last == [4])
        let geometry = try Pair.run(device: .cpu) { rank -> [[Int]] in
            let model = models.value[rank], caches = try model.model.makeIndependentHistoryCaches()
            eval(try MiMoTensorParallelDecoding(model: model).prefill(Self.prompt, chunk: 4, caches: caches))
            return caches.map { [$0.state[0].dim(1), $0.state[0].dim(2), $0.state[0].dim(3), $0.state[1].dim(3)] }
        }
        for rank in 0 ..< 2 {
            for layer in 0 ..< plan.layerCount {
                // A sliding layer keeps its window less one plus the last chunk.
                let rows = plan.slidingLayers[layer] ? 7 + 4 : Self.prompt.count
                #expect(geometry[rank][layer] == [plan.kvHeadsPerRank[layer], rows, plan.headDim(layer: layer),
                                                  plan.valueHeadDim(layer: layer)], "rank \(rank) layer \(layer)")
            }
        }
        // The batched independent decode takes no cross-rank sums: a rank refuses two rows.
        try Device.withDefaultDevice(.cpu) {
            let model = models.value[0].model
            #expect(throws: (any Error).self) {
                _ = try model.decodeIndependentHistories(inputIDs: MLXArray([Int32(1), 2]).reshaped(2, 1),
                    caches: [try model.makeIndependentHistoryCaches(), try model.makeIndependentHistoryCaches()])
            }
        }
    }

    @Test func selectionRuleFollowsTheRequest() {
        func sampling(temperature: Float = 0, bias: [ClusterWorkerSampling.LogitBias] = [], top: Int = 0) -> ClusterWorkerSampling {
            .init(temperature: temperature, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1, repetitionContextSize: 0,
                  frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2, logitBias: bias, topLogprobs: top)
        }
        typealias Rule = MiMoTensorParallelSelectionRule
        #expect(Rule.rule(nil) == .greedy)
        #expect(Rule.rule(sampling()) == .greedy)
        #expect(Rule.rule(sampling(top: 5)) == .greedyLogprobs(top: 5))
        #expect(Rule.rule(sampling(temperature: 0.7)) == .gatheredRow)
        #expect(Rule.rule(sampling(temperature: 0.7, top: 3)) == .gatheredRow)
        #expect(Rule.rule(sampling(bias: [.init(tokenID: 3, bias: 2)], top: 2)) == .gatheredRow)
    }

    private struct Ran {
        let outcome: MiMoTensorParallelDecoding.Outcome
        let published: [(ordinal: Int, token: Int, logprobs: ClusterWorkerTokenLogprobs?)]
    }

    private static func run(_ models: Box<[MiMoTensorParallelModel]>, rule: MiMoTensorParallelSelectionRule,
                            sampling: ClusterWorkerSampling? = nil, stops: Set<Int> = [],
                            answer: @escaping @Sendable (Int, Int) -> Bool = { _, _ in true },
                            stopAfter: @escaping @Sendable (Int, Int) -> Bool = { _, _ in false }) throws -> [Ran] {
        try Pair.run(device: .cpu) { rank in
            let model = models.value[rank]
            let sampler = try sampling.map { QwenStageTokenSampler(try QwenStageSamplingState($0, promptTokens: Self.prompt)) }
            var published: [(ordinal: Int, token: Int, logprobs: ClusterWorkerTokenLogprobs?)] = []
            var commits = 0
            let outcome = try MiMoTensorParallelDecoding(model: model).run(
                .init(prompt: Self.prompt, outputCount: 6, chunk: 4, stopTokenIDs: stops, rule: rule, sampler: sampler),
                localStop: { commits += 1; return stopAfter(rank, commits) },
                publish: { ordinal, token, logprobs in
                    published.append((ordinal, token, logprobs))
                    return answer(rank, ordinal)
                })
            return Ran(outcome: outcome, published: published)
        }
    }

    /// Logprobs, sampling and every kind of stop end both ranks after the
    /// same step with the same tokens; only rank 0 publishes.
    @Test func pagedRequestsPublishLogprobsAndStopTogether() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try Self.ranks(directory, pair: Pair())
        // A greedy row with logprobs: the split top-k gather's candidates, the token first.
        let greedy = try Self.run(models, rule: .greedyLogprobs(top: 3))
        #expect(greedy[0].outcome.tokens == greedy[1].outcome.tokens && greedy[0].outcome.tokens.count == 6)
        #expect(greedy[1].published.isEmpty && greedy[0].published.map { $0.token } == greedy[0].outcome.tokens)
        for entry in greedy[0].published {
            let logprobs = try #require(entry.logprobs)
            #expect(logprobs.top.count == 3 && logprobs.top[0].tokenID == entry.token && logprobs.logprob == logprobs.top[0].logprob)
            #expect(logprobs.logprob <= 0 && zip(logprobs.top, logprobs.top.dropFirst()).allSatisfy { $0.logprob >= $1.logprob })
        }
        // The same tokens as plain greedy, which publishes no logprobs.
        let plain = try Self.run(models, rule: .greedy)
        #expect(plain[0].outcome.tokens == greedy[0].outcome.tokens && plain[0].published.allSatisfy { $0.logprobs == nil })
        // Sampled with logprobs: rank 0 draws from the gathered row with the product's sampler.
        let wire = ClusterWorkerSampling(temperature: 0.8, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: 9, stream: 3, logitBias: [],
            topLogprobs: 2)
        let sampled = try Self.run(models, rule: .rule(wire), sampling: wire)
        #expect(sampled[0].outcome.tokens == sampled[1].outcome.tokens && sampled[0].outcome.tokens.count == 6)
        #expect(sampled[0].published.allSatisfy { $0.logprobs?.top.count == 2 })
        // A stop token ends both at its first occurrence.
        let tokens = plain[0].outcome.tokens
        let stop = tokens[2], at = tokens.firstIndex(of: stop)!
        let eos = try Self.run(models, rule: .greedy, stops: [stop])
        for ran in eos { #expect(ran.outcome.tokens == Array(tokens.prefix(at + 1)) && ran.outcome.finish == .eos) }
        // The owner's stop answer to rank 0's second token: both keep two tokens.
        let client = try Self.run(models, rule: .greedy, answer: { rank, ordinal in !(rank == 0 && ordinal == 1) })
        for ran in client { #expect(ran.outcome.tokens == Array(tokens.prefix(2)) && ran.outcome.finish == .clientStop) }
        #expect(client[0].outcome.ownerStopped && !client[1].outcome.ownerStopped)
        // Rank 1 stops itself (cancel, deadline, memory) after its third commit: both keep three.
        let local = try Self.run(models, rule: .greedy, stopAfter: { rank, commits in rank == 1 && commits == 3 })
        for ran in local { #expect(ran.outcome.tokens == Array(tokens.prefix(3)) && ran.outcome.finish == .clientStop) }
        #expect(local[1].outcome.stoppedHere && !local[0].outcome.stoppedHere && !local[0].outcome.ownerStopped)
    }

    /// Ranks given different requests both learn it before any forward.
    @Test func requestAgreementComparesBothRanks() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try Self.ranks(directory, pair: Pair())
        let same = try Pair.run(device: .cpu) { rank in
            try MiMoTensorParallelDecoding(model: models.value[rank]).requestAgreed(0x1234_5678_9abc_def0)
        }
        let different = try Pair.run(device: .cpu) { rank in
            try MiMoTensorParallelDecoding(model: models.value[rank]).requestAgreed(rank == 0 ? 7 : 7 | 1 << 40)
        }
        #expect(same == [true, true] && different == [false, false])
    }

    // MARK: - Load agreement, budget and launch

    @Test func loadAgreementBindsThePlanAndTheServingContract() throws {
        let registered = try MiMoTensorParallelPlan(configuration: MiMoTensorParallelTests.fixture("configuration"))
        let synthetic = try MiMoTensorParallelPlan(configuration: JSONSerialization.data(
            withJSONObject: MiMoTensorParallelModel.syntheticConfiguration(.kernel), options: [.sortedKeys]))
        typealias Runtime = MiMoTensorParallelResidentRuntime
        let fields = Runtime.loadAgreementFields(plan: registered, chunkTokens: 512)
        #expect(fields.contains(registered.fingerprint) && fields.contains(MiMoTensorParallelPlan.name))
        #expect(MiMoTensorParallelPlan.arithmeticAgreementFields.allSatisfy(fields.contains))
        #expect(fields.contains(QwenTensorParallelLinkProbe.loadAgreementField))
        #expect(ClusterGenerationMode.tensorParallel.loadAgreementFields.allSatisfy(fields.contains))
        #expect(fields.contains("lanes=1") && fields.contains("prefix=off") && fields.contains("chunk=512"))
        #expect(fields != Runtime.loadAgreementFields(plan: synthetic, chunkTokens: 512))
        #expect(fields != Runtime.loadAgreementFields(plan: registered, chunkTokens: 256))
    }

    /// The registered plan's per-rank paged history: full layers grow by
    /// 9 x 2 KV heads x (192 + 128) x 2 B = 11,520 B a token, a page at a
    /// time; sliding layers stop at the window plus a chunk.
    @Test func requestBudgetChargesThisRanksPagedHistory() throws {
        let plan = try MiMoTensorParallelPlan(configuration: MiMoTensorParallelTests.fixture("configuration"))
        let budget = try MiMoTensorParallelRequestBudget(plan: plan, slidingWindow: 128)
        let exact: (Int) throws -> Int = { $0 }
        let at4096 = try budget.historyBytes(contextTokens: 4096, chunk: 512, allocationBound: exact)
        // 39 sliding layers x 10 pages x 64 x 2,560 B, twice; 9 full layers x 64 pages x 64 x 1,280 B;
        // the widest gathered layer (a full one), twice.
        #expect(at4096 == 39 * 10 * 64 * 2560 * 2 + 9 * 64 * 64 * 1280 + 4096 * 1280 * 2)
        let at4160 = try budget.historyBytes(contextTokens: 4160, chunk: 512, allocationBound: exact)
        #expect(at4160 - at4096 == 64 * 11_520 + 64 * 1280 * 2)
        #expect(try budget.bytes(contextTokens: 8320, chunk: 512) > (try budget.bytes(contextTokens: 4096, chunk: 512)))
        #expect(throws: (any Error).self) { try MiMoTensorParallelRequestBudget(plan: plan, slidingWindow: 0) }
    }

    @Test func textLaunchRefusesTheImageCandidateLanesAndLookahead() throws {
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "registered_mimo_v26_flash_mopd",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
        func launch(profile: String? = nil, schedule: ClusterPrefillSchedule = .serial) -> QwenResidentLoadConfiguration {
            QwenResidentLoadConfiguration(identity: identity, modelDirectory: URL(fileURLWithPath: "/tmp"), rank: 0,
                stageCut: 24, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 60_000_000_000,
                prefillSchedule: schedule, runtimeProfile: profile)
        }
        typealias Runtime = MiMoTensorParallelResidentRuntime
        try Runtime.requireTextLaunch(launch(), environment: [:])
        try Runtime.requireTextLaunch(launch(), environment: ["DARKBLOOM_CLUSTER_BATCH_LANES": "1"])
        #expect(throws: (any Error).self) {
            try Runtime.requireTextLaunch(launch(profile: ClusterMiMoImageCandidate.profileID), environment: [:])
        }
        #expect(throws: (any Error).self) {
            try Runtime.requireTextLaunch(launch(), environment: ["DARKBLOOM_CLUSTER_BATCH_LANES": "2"])
        }
        #expect(throws: (any Error).self) {
            try Runtime.requireTextLaunch(launch(schedule: .oneChunkLookahead), environment: [:])
        }
    }
}
