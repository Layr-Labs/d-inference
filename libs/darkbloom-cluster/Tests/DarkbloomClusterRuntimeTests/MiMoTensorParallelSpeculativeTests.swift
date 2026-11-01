import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// MiMo V2.6 tensor parallel's speculative rounds on two real ranks (two
/// threads whose all-sum adds both ranks' FP32 elements): row-exact verify
/// windows against the one-token path, forced acceptance (proposals scripted
/// from the one-token path's own tokens) with rejections and exact rollback,
/// stops and cancels inside and between rounds, and exactly tied columns.
/// CPU only; synthetic weights with three random trained heads, never a model pass.
@Suite("MiMo V2.6 tensor-parallel speculative rounds", .serialized)
struct MiMoTensorParallelSpeculativeTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    /// Longer than the 8-token window, in 4-token chunks.
    private static let prompt = (0 ..< 12).map { ($0 * 37 + 11) % 512 }
    private static let outputs = 10

    private static func ranks() throws -> (directory: URL, models: Box<[MiMoTensorParallelModel]>) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-tp-mtp-\(UUID().uuidString)")
        let pair = Pair()
        let models = try Device.withDefaultDevice(.cpu) { () throws -> [MiMoTensorParallelModel] in
            try MiMoTensorParallelModel.writeSyntheticCheckpoint(directory: directory, variant: .tiny, mtp: true)
            return try (0 ..< 2).map { rank in
                let model = try MiMoTensorParallelModel.loadVerified(modelDirectory: directory, role: .shard(rank: rank),
                                                                     reduction: pair.reduction(rank: rank)).model
                try model.loadDraftHeads(modelDirectory: directory)
                return model
            }
        }
        return (directory, Box(models))
    }

    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    private static func generate(_ models: Box<[MiMoTensorParallelModel]>,
                                 _ speculative: MiMoTensorParallelModel.SpeculativeOptions?) throws
        -> [MiMoTensorParallelModel.Generation] {
        try Pair.run(device: .cpu) { rank in
            try models.value[rank].generatePaged(prompt: Self.prompt, outputCount: Self.outputs, chunk: 4, recordTop: 4,
                                                 speculative: speculative)
        }
    }

    /// Every speculative run equals the one-token path bit for bit on both
    /// ranks: tokens, top logits and log probabilities, every step's whole
    /// row and the caches. The trained (random) heads propose and are
    /// rejected; scripted proposals are all kept, or every third is moved off
    /// so rounds keep one to three tokens and roll the rest back.
    @Test func roundsEqualTheOneTokenPathBitForBit() throws {
        let (directory, models) = try Self.ranks()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = try Self.generate(models, nil)
        #expect(plain[0].tokenIDs == plain[1].tokenIDs && plain[0].tokenIDs.count == Self.outputs)
        let runs: [(String, MiMoTensorParallelModel.SpeculativeOptions)] = [
            ("heads depth 2", .init(depth: 2, proposals: .heads)),
            ("heads depth 3", .init(depth: 3, proposals: .heads)),
            ("script, all kept", .init(depth: 2, proposals: .scripted(tokens: plain[0].tokenIDs, missEvery: 0))),
            ("script, every third off", .init(depth: 3, proposals: .scripted(tokens: plain[0].tokenIDs, missEvery: 3))),
        ]
        for (label, options) in runs {
            let rounds = try Self.generate(models, options)
            for rank in 0 ..< 2 {
                #expect(rounds[rank].tokenIDs == plain[rank].tokenIDs, "\(label) rank \(rank)")
                #expect(Self.bits(rounds[rank].topLogits) == Self.bits(plain[rank].topLogits), "\(label) rank \(rank)")
                #expect(Self.bits(rounds[rank].topLogprobs) == Self.bits(plain[rank].topLogprobs), "\(label) rank \(rank)")
                #expect(rounds[rank].stepRowSHA256 == plain[rank].stepRowSHA256, "\(label) rank \(rank)")
                #expect(rounds[rank].cacheSHA256 == plain[rank].cacheSHA256, "\(label) rank \(rank)")
                #expect((rounds[rank].speculativeRounds ?? 0) > 0, "\(label) rank \(rank)")
            }
            #expect(rounds[0].acceptedByPosition == rounds[1].acceptedByPosition, "\(label)")
            if case .scripted(_, let missEvery) = options.proposals {
                let kept = rounds[0].acceptedDrafts ?? 0, examined = rounds[0].draftedTokens ?? 0
                if missEvery == 0 {
                    #expect(kept == examined && kept >= 2 * (rounds[0].speculativeRounds ?? 0) - 1, "\(label)")
                } else {
                    #expect(kept > 0 && kept < examined, "\(label): accepts and rejects")
                }
            }
        }
    }

    private struct Ran {
        let outcome: MiMoTensorParallelDecoding.Outcome
        let published: [(ordinal: Int, token: Int, logprobs: ClusterWorkerTokenLogprobs?)]
    }

    /// `script`: proposals scripted from these tokens (all kept); nil: the trained heads.
    /// `rounds` false: the one-token path.
    private static func run(_ models: Box<[MiMoTensorParallelModel]>, script: [Int]? = nil, rounds: Bool = true,
                            rule: MiMoTensorParallelSelectionRule = .greedy, stops: Set<Int> = [],
                            answer: @escaping @Sendable (Int, Int) -> Bool = { _, _ in true },
                            stopAfter: @escaping @Sendable (Int, Int) -> Bool = { _, _ in false }) throws -> [Ran] {
        try Pair.run(device: .cpu) { rank in
            let model = models.value[rank]
            let proposer: MiMoTensorParallelProposer = try script.map { .scripted(script: $0, missEvery: 0) }
                ?? .heads(try #require(model.draftHead))
            let speculation = rounds ? try MiMoTensorParallelSpeculation(depth: 2, proposer: proposer) : nil
            var published: [(ordinal: Int, token: Int, logprobs: ClusterWorkerTokenLogprobs?)] = []
            var checks = 0
            let outcome = try MiMoTensorParallelDecoding(model: model).run(
                .init(prompt: Self.prompt, outputCount: Self.outputs, chunk: 4, stopTokenIDs: stops, rule: rule,
                      sampler: nil, speculation: speculation),
                localStop: { checks += 1; return stopAfter(rank, checks) },
                publish: { ordinal, token, logprobs in
                    published.append((ordinal, token, logprobs))
                    return answer(rank, ordinal)
                })
            return Ran(outcome: outcome, published: published)
        }
    }

    /// Stops inside and between rounds end both ranks with the same tokens
    /// and finish, with forced acceptance (rounds of three tokens: indexes
    /// 1-3, 4-6, 7-9 after the first token): a stop token in the middle of a
    /// window, the owner's stop in the middle of a round, the owner's stop
    /// just before a stop token of the same round (rank 1 then adopts rank
    /// 0's count in the end agreement), a cancel on rank 1 between rounds, and
    /// greedy logprobs for every kept column. A harness whose ranks issued
    /// different collectives would trap instead of returning.
    @Test func stopsInsideAndBetweenRoundsEndBothRanksTogether() throws {
        let (directory, models) = try Self.ranks()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = try Self.generate(models, nil)[0].tokenIDs
        let script = tokens
        // Every round keeps three tokens; all are published by rank 0 only.
        let all = try Self.run(models, script: script)
        for ran in all { #expect(ran.outcome.tokens == tokens && ran.outcome.finish == .length) }
        #expect(all[0].published.map(\.token) == tokens && all[1].published.isEmpty)
        #expect(all[0].outcome.statistics?.acceptedByPosition == [3, 3])
        // A stop token in the middle of a round's window (not its first column).
        let firstAt = { (index: Int) in tokens.firstIndex(of: tokens[index]) == index }
        let inside = try #require([2, 3, 5, 6, 8, 9].first(where: firstAt))
        let eos = try Self.run(models, script: script, stops: [tokens[inside]])
        for ran in eos { #expect(ran.outcome.tokens == Array(tokens.prefix(inside + 1)) && ran.outcome.finish == .eos) }
        // The owner stops at index 4, the middle of the second round: both keep five.
        let client = try Self.run(models, script: script, answer: { rank, ordinal in !(rank == 0 && ordinal == 4) })
        for ran in client { #expect(ran.outcome.tokens == Array(tokens.prefix(5)) && ran.outcome.finish == .clientStop) }
        #expect(client[0].outcome.ownerStopped && client[0].published.map(\.token) == Array(tokens.prefix(5)))
        // The owner stops at a token whose successor in the same round is a stop token: that round
        // ends the request on rank 1, rank 0 stopped first; both end with rank 0's tokens.
        let before = try #require([1, 2, 4, 5, 7, 8].first { firstAt($0 + 1) && !tokens[...$0].contains(tokens[$0 + 1]) })
        let raced = try Self.run(models, script: script, stops: [tokens[before + 1]],
                                 answer: { rank, ordinal in !(rank == 0 && ordinal == before) })
        for ran in raced {
            #expect(ran.outcome.tokens == Array(tokens.prefix(before + 1)) && ran.outcome.finish == .clientStop)
        }
        #expect(raced[0].outcome.ownerStopped && raced[0].published.map(\.token) == Array(tokens.prefix(before + 1)))
        // Rank 1 cancels at its third check (after the first token, then each round): both keep seven.
        let local = try Self.run(models, script: script, stopAfter: { rank, checks in rank == 1 && checks == 3 })
        for ran in local { #expect(ran.outcome.tokens == Array(tokens.prefix(7)) && ran.outcome.finish == .clientStop) }
        #expect(local[1].outcome.stoppedHere && !local[0].outcome.stoppedHere)
        // Greedy logprobs for every kept column, the token first, the same tokens, and exactly the
        // logprobs the one-token path publishes.
        let logprobs = try Self.run(models, script: script, rule: .greedyLogprobs(top: 3))
        #expect(logprobs[0].outcome.tokens == tokens && logprobs[0].published.count == tokens.count)
        for entry in logprobs[0].published {
            let value = try #require(entry.logprobs)
            #expect(value.top.count == 3 && value.top[0].tokenID == entry.token && value.logprob == value.top[0].logprob)
        }
        let stepped = try Self.run(models, rounds: false, rule: .greedyLogprobs(top: 3))
        #expect(stepped[0].outcome.statistics == nil && stepped[0].published.map(\.token) == tokens)
        #expect(logprobs[0].published.map(\.logprobs) == stepped[0].published.map(\.logprobs))
        // The trained (random) heads, with the same stop token: both end there.
        let heads = try Self.run(models, stops: [tokens[inside]])
        for ran in heads { #expect(ran.outcome.tokens == Array(tokens.prefix(inside + 1)) && ran.outcome.finish == .eos) }
    }

    /// Sampled requests follow the product's rule (`admitsSpeculativeVerification`): a stateless
    /// sampler without logprobs drafts, and both ranks keep the same keyed target samples; a
    /// sampler with logprobs or with transforms that depend on its history (a logit bias)
    /// decodes one token a step, exactly as without speculation.
    @Test func sampledRequestsFollowTheProductsRule() throws {
        let (directory, models) = try Self.ranks()
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ wire: ClusterWorkerSampling, speculative: Bool) throws -> [MiMoTensorParallelDecoding.Outcome] {
            try Pair.run(device: .cpu) { rank in
                let model = models.value[rank]
                let sampler = QwenStageTokenSampler(try QwenStageSamplingState(wire, promptTokens: Self.prompt))
                let speculation = speculative
                    ? try MiMoTensorParallelSpeculation(depth: 2, proposer: .heads(try #require(model.draftHead))) : nil
                var published: [ClusterWorkerTokenLogprobs?] = []
                var outcome = try MiMoTensorParallelDecoding(model: model).run(
                    .init(prompt: Self.prompt, outputCount: Self.outputs, chunk: 4, stopTokenIDs: [],
                          rule: .rule(wire), sampler: sampler, speculation: speculation),
                    publish: { _, _, value in published.append(value); return true })
                if rank == 0 {
                    #expect(published.count == outcome.tokens.count)
                    #expect(published.allSatisfy { wire.topLogprobs == 0 ? $0 == nil : $0?.top.count == wire.topLogprobs })
                }
                outcome.caches = []
                return outcome
            }
        }
        func wire(bias: [ClusterWorkerSampling.LogitBias] = [], top: Int = 0) -> ClusterWorkerSampling {
            .init(temperature: 0.8, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1, repetitionContextSize: 0,
                  frequencyPenalty: 0, presencePenalty: 0, seed: 9, stream: 3, logitBias: bias, topLogprobs: top)
        }
        let rounds = try run(wire(), speculative: true)
        #expect(rounds[0].tokens == rounds[1].tokens && rounds[0].tokens.count == Self.outputs)
        #expect((rounds[0].statistics?.rounds ?? 0) > 0 && rounds[0].statistics == rounds[1].statistics)
        for stepped in [wire(top: 2), wire(bias: [.init(tokenID: 3, bias: 2)])] {
            let speculative = try run(stepped, speculative: true), plain = try run(stepped, speculative: false)
            #expect(speculative[0].statistics == nil && speculative[1].statistics == nil)
            #expect(speculative[0].tokens == plain[0].tokens && speculative[1].tokens == plain[1].tokens)
        }
    }

    /// The runtime charges the heads from the pipeline's head inventory over the artifact's
    /// headers (`MiMoMTPHeadInventory`: three BF16 heads beside the packed embedding): on a
    /// synthetic checkpoint it names exactly the tensors a rank loads, and their bytes.
    @Test func headInventoryNamesExactlyTheLoadedHeads() throws {
        let (directory, models) = try Self.ranks()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration,
                                                    hashingConcurrency: 2)
            let indexed = try tensorDescriptors(checkpoint: checkpoint,
                                                scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
            let headers = try indexed.map { name, tensor in
                MiMoMTPHeadInventory.Entry(name: name, shape: tensor.shape, dtype: try tensor.storedDTypeName,
                                           byteCount: tensor.byteCount)
            }
            let inventory = try MiMoMTPHeadInventory(configuration: configuration, headers: headers)
            let selected = try MiMoTensorParallelDraftHead.descriptors(checkpoint: checkpoint)
            #expect(Set(inventory.head.map(\.name)) == Set(selected.keys) && inventory.head.count == 42)
            let head = try #require(models.value[0].draftHead)
            #expect(inventory.head.reduce(0) { $0 + $1.byteCount } == head.headBytes && head.headTensors == 42)
            // The LOAD gate charges the drafter from the configuration alone: what the loaded heads declare.
            let decoded = try JSONDecoder().decode(MiMoV26Configuration.self, from: configuration)
            for (chunk, depth) in [(4, 1), (16, 2), (512, 3)] {
                let limits = CBv2MTPAllocationLimits(maximumPrefillTokens: chunk, maximumDraftTokens: depth)
                let loaded = try #require(head.assistant.boundedRequestAllocation(limits: limits))
                #expect(MiMoV26MTPAssistant.boundedRequestAllocation(configuration: decoded, limits: limits) == loaded)
            }
            // A descriptor set that is not the heads' is refused before any read.
            #expect(throws: (any Error).self) {
                _ = try MiMoTensorParallelDraftHead.load(descriptors: indexed.filter { !$0.key.hasPrefix("language_model.model.mtp.") },
                    checkpoint: checkpoint, configurationData: configuration, target: models.value[0])
            }
        }
    }

    /// A rank's speculative charge at the registered geometry (exact bounds): the drafter's
    /// bounded state is the product's own declaration (chunk 512, depth 2), and a window adds
    /// each sliding ring once more per extra row, one page per layer and its rows twice. The
    /// load agreement grows only when rounds are on.
    @Test func speculativeChargeAndAgreementAtTheRegisteredGeometry() throws {
        let data = try MiMoTensorParallelTests.fixture("configuration")
        let plan = try MiMoTensorParallelPlan(configuration: data)
        let exact: (Int) throws -> Int = { $0 }
        let window = try MiMoTensorParallelRequestBudget.speculativeWindowBytes(plan: plan, slidingWindow: 128, depth: 2,
                                                                                allocationBound: exact)
        #expect(window == 39 * 128 * 2560 * 2 + 39 * 64 * 2560 + 9 * 64 * 1280 + 3 * 152_576 * 4 * 2)
        #expect(window == 36_347_904)
        #expect(throws: (any Error).self) {
            try MiMoTensorParallelRequestBudget.speculativeWindowBytes(plan: plan, slidingWindow: 128, depth: 4,
                                                                       allocationBound: exact)
        }
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self, from: data)
        let spec = try #require(MiMoV26MTPAssistant.boundedRequestAllocation(configuration: configuration,
            limits: .init(maximumPrefillTokens: 512, maximumDraftTokens: 2)))
        let drafter = (spec.resident + spec.working).reduce(spec.hostBytes) { $0 + $1.logicalBytes * $1.allocationCount }
        #expect(drafter == 438_426_984)
        #expect(try MiMoTensorParallelDraftHead.requestBytes(configuration: configuration, chunkSize: 512, depth: 2,
                                                             bound: exact) == drafter)
        typealias Runtime = MiMoTensorParallelResidentRuntime
        let plain = Runtime.loadAgreementFields(plan: plan, chunkTokens: 512)
        #expect(Runtime.loadAgreementFields(plan: plan, chunkTokens: 512, speculative: nil) == plain)
        let two = Runtime.loadAgreementFields(plan: plan, chunkTokens: 512, speculative: try MiMoMTPTerms(depth: 2))
        let three = Runtime.loadAgreementFields(plan: plan, chunkTokens: 512, speculative: try MiMoMTPTerms(depth: 3))
        #expect(Array(two.prefix(plain.count)) == plain && two.count > plain.count && two != three)
        #expect(two.contains("depth=2") && two.contains("windows=row-exact-one-token-bits"))
    }

    /// Exactly tied maxima in a window's columns: inside one rank's half the
    /// lower ID wins, across halves rank 0's (the lower IDs); a column's
    /// logprobs lead with its agreed maximum even when a tied token leads the
    /// gather; a draft head's proposal is the whole row's argmax by the same rule.
    @Test func exactlyTiedColumnsChooseTheLowestID() throws {
        let (directory, models) = try Self.ranks()
        defer { try? FileManager.default.removeItem(at: directory) }
        let half = models.value[0].plan.vocabularySize / 2
        let chosen = try Pair.run(device: .cpu) { rank in
            var rows = [[Float]](repeating: [Float](repeating: -1, count: half), count: 3)
            if rank == 0 { rows[0][10] = 4; rows[0][20] = 4; rows[1][7] = 3; rows[2][2] = 1 }
            else { rows[0][5] = 3.5; rows[1][3] = 3; rows[2][5] = 2 }
            let logits = MLXArray(rows.flatMap { $0 }).reshaped(1, 3, half).asType(.bfloat16)
            let decoding = MiMoTensorParallelDecoding(model: models.value[rank])
            let request = MiMoTensorParallelDecoding.Request(prompt: [1], outputCount: 3, chunk: 1, stopTokenIDs: [],
                                                             rule: .greedyLogprobs(top: 1), sampler: nil)
            let round = try decoding.selectRound(logits, request: request, stop: 0, position: 0)
            let logprobs = try decoding.roundLogprobs(round, logits: logits, kept: round.targets, request: request)
            let draft = models.value[rank].model.readoutArgMax(logits[0..., 0, 0...])
            eval(draft)
            return (targets: round.targets, logprobs: logprobs.map { $0?.logprob }, proposal: Int(draft.item(Int32.self)))
        }
        #expect(chosen[0].targets == chosen[1].targets)
        #expect(chosen[0].targets == [10, 7, half + 5])
        #expect(chosen[0].proposal == 10 && chosen[1].proposal == 10)
        #expect(chosen[0].logprobs.allSatisfy { ($0 ?? 1) <= 0 } && chosen[0].logprobs == chosen[1].logprobs)
    }
}
