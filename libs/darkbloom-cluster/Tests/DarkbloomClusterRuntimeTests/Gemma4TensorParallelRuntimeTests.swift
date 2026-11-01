import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// The Gemma 4 tensor-parallel resident runtime's own pieces on synthetic
/// checkpoints: each rank's paged request state (its own heads of every
/// layer), the request path both ranks run (`Gemma4TensorParallelPagedSession`
/// and `Gemma4TensorParallelChoice`: two in-process ranks bit for bit equal,
/// the whole model's tokens, one collective a step), the verified load's cut
/// of every text tensor, the load agreement, and the planner, which never
/// places a Gemma pair in tensor parallel while its layout has no
/// tensor-parallel facts. Never a model pass or a hardware result.
@Suite("Gemma 4 tensor-parallel resident runtime", .serialized)
struct Gemma4TensorParallelRuntimeTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static func synthetic(bits: Int = 4, experts: Int = 16, topK: Int = 4) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-tp-runtime-\(bits)-\(experts)-\(topK)-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, bits: bits, experts: experts, topK: topK)
        }
        return directory
    }

    private static let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    // MARK: - Paged request state

    /// A shard's request state keeps its own KV heads of every layer (the
    /// synthetic model's 8 sliding and 2 full split 4 and 1, as the 26B's),
    /// its host pages exactly half the whole model's bytes per request, and a
    /// whole-model geometry refuses a shard's layers.
    @Test func eachRankPagesItsOwnHeadsOfEveryLayer() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let shard = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: 1),
                                                       reduction: pair.reduction(rank: 1))
        let whole = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        let plan = shard.plan
        let local = try shard.requestGeometry(maximumTokens: 256), all = try whole.requestGeometry(maximumTokens: 256)
        #expect(local.kinds.count == plan.layerCount && all.kinds.count == plan.layerCount)
        for (layer, (mine, every)) in zip(local.kinds, all.kinds).enumerated() {
            #expect(mine.kvHeads == plan.kvHeadsPerRank[layer] && mine.kvHeads * 2 == every.kvHeads)
            #expect(mine.queryHeads == plan.queryHeadsPerRank && mine.headDim == plan.headDim(layer: layer))
            #expect(mine.modelLayerIndex == layer && mine.attention == every.attention)
        }
        #expect(plan.kvHeadsPerRank == [4, 4, 1, 4, 4, 1])
        let shardHost = try shard.pagedHost(lanes: 1, maximumTokens: 256, chunkTokens: 16)
        let wholeHost = try whole.pagedHost(lanes: 1, maximumTokens: 256, chunkTokens: 16)
        #expect(shardHost.requestPageBytes * 2 == wholeHost.requestPageBytes)
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(gemma4TensorParallelKinds: local.kinds, plan: plan, ranks: 1,
                slidingWindow: 16, kvDType: .bfloat16, maximumTokens: 256)
        }
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(gemma4TensorParallelKinds: Array(local.kinds.dropLast()), plan: plan, ranks: 2,
                slidingWindow: 16, kvDType: .bfloat16, maximumTokens: 256)
        }
    }

    /// Two in-process ranks (`Gemma4TensorParallelLocalPair`) run the
    /// runtime's request path on their paged hosts: bit for bit the same
    /// tokens, top candidates and final row on both, the whole model's paged
    /// tokens (every expert taken, so no route can flip), and exactly two
    /// collectives a layer and one a step (the token and both stop flags).
    @Test func pagedRanksAgreeBitwiseAndTakeTheWholeModelsTokens() throws {
        let directory = try Self.synthetic(experts: 4, topK: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let steps = 8, recordTop = 4
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let ranks = try Pair.run(device: .gpu) { rank in
            try models.value[rank].generatePaged(prompt: Self.prompt, outputCount: steps, chunk: 16, recordTop: recordTop)
        }
        let whole = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
            .generatePaged(prompt: Self.prompt, outputCount: steps, chunk: 16, recordTop: recordTop)
        #expect(ranks[0].tokenIDs == ranks[1].tokenIDs && ranks[0].topTokenIDs == ranks[1].topTokenIDs)
        #expect(Self.bits(ranks[0].topLogits) == Self.bits(ranks[1].topLogits))
        #expect(Self.bits(ranks[0].topLogprobs) == Self.bits(ranks[1].topLogprobs))
        #expect(ranks[0].finalLogits.map { $0.map(\.bitPattern) } == ranks[1].finalLogits.map { $0.map(\.bitPattern) })
        #expect(ranks[0].tokenIDs == whole.tokenIDs, "paged tensor parallel \(ranks[0].tokenIDs) against whole \(whole.tokenIDs)")
        #expect(ranks[0].finalLogits?.count == 512 && ranks[0].tokenIDs.count == steps)
        // Prompt chunks of 16: three forwards, then one a decode step after the first token.
        let forwards = 3 + steps - 1, layers = models.value[0].plan.layerCount
        #expect(pair.payloads.count == forwards * 2 * layers + steps + steps + 1)
        #expect(pair.payloads.filter { $0 == [6] }.count == steps, "each step's choice: max, ID and stop flag a rank")
    }

    /// Submitting each decode step layer by layer as it is built
    /// (`Gemma4LayerSubmission`) changes only when work is queued: tokens,
    /// top candidates and the final row keep every bit of the step evaluated whole.
    @Test func layerSubmissionKeepsEveryBit() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        func run(_ stride: Int) throws -> Gemma4TensorParallelModel.Generation {
            try Gemma4TensorParallelModel.$layerStride.withValue(stride) {
                try model.generatePaged(prompt: Self.prompt, outputCount: 6, chunk: 16, recordTop: 4)
            }
        }
        let whole = try run(0), layered = try run(1), pairs = try run(2)
        for other in [layered, pairs] {
            #expect(other.tokenIDs == whole.tokenIDs && Self.bits(other.topLogits) == Self.bits(whole.topLogits))
            #expect(other.finalLogits.map { $0.map(\.bitPattern) } == whole.finalLogits.map { $0.map(\.bitPattern) })
        }
    }

    /// Batch lanes: three requests of different lengths decode together on
    /// each rank's three-lane host (two open, the third joins two steps later,
    /// each leaves at its own end). Every row of every step equals that
    /// request's row decoding alone, bit for bit, on both ranks, and the
    /// batched split argmax chooses each row's solo token.
    @Test func lanesGiveEachRequestItsSoloRowsBitwise() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let prompts = [Self.prompt, (0 ..< 23).map { ($0 * 101 + 7) % 512 }, (0 ..< 57).map { ($0 * 13 + 400) % 512 }]
        let outputs = 6
        typealias Rows = [[[UInt32]]]
        let results = try Pair.run(device: .gpu) { rank -> (solo: [[Int]], soloRows: Rows, lanes: [[Int]], laneRows: Rows, batched: Bool) in
            let model = models.value[rank], selection = model.selection
            let host = try model.pagedHost(lanes: 3, maximumTokens: 128, chunkTokens: 16)
            func open(_ prompt: [Int]) throws -> (Gemma4TensorParallelPagedSession, MLXArray) {
                let session = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: prompt.count,
                    outputCount: outputs)
                var offset = 0, last: MLXArray?
                while offset < prompt.count {
                    let end = min(prompt.count, offset + 16)
                    last = try session.prefill(prompt, range: offset ..< end, check: {}) { $0 }?.logits ?? last
                    offset = end
                }
                return (session, last!)
            }
            func token(_ logits: MLXArray) -> Int {
                let chosen = selection.greedyRows(logits)
                eval(chosen)
                return Int(chosen.item(Int32.self))
            }
            func bits(_ logits: MLXArray) -> [UInt32] { logits.asArray(Float.self).map(\.bitPattern) }
            var solo: [[Int]] = [], soloRows: Rows = []
            for prompt in prompts {
                var (session, logits) = try open(prompt)
                var tokens: [Int] = [], rows: [[UInt32]] = []
                while tokens.count < outputs {
                    rows.append(bits(logits)); tokens.append(token(logits))
                    if tokens.count < outputs {
                        logits = try Gemma4TensorParallelPagedSession.decode([session], tokens: [tokens.last!], check: {})
                    }
                }
                try session.retire()
                solo.append(tokens); soloRows.append(rows)
            }
            var sessions: [Gemma4TensorParallelPagedSession?] = [nil, nil, nil], current: [MLXArray?] = [nil, nil, nil]
            var tokens = [[Int]](repeating: [], count: 3), rows = Rows(repeating: [], count: 3)
            var batchedMatches = true
            func join(_ lane: Int) throws { let opened = try open(prompts[lane]); sessions[lane] = opened.0; current[lane] = opened.1 }
            try join(0); try join(1)
            var step = 0
            while sessions.contains(where: { $0 != nil }) || step < 2 {
                if step == 2 { try join(2) }
                var decoding: [Int] = []
                for lane in 0 ..< 3 {
                    guard let logits = current[lane] else { continue }
                    rows[lane].append(bits(logits)); tokens[lane].append(token(logits))
                    if tokens[lane].count == outputs {
                        try sessions[lane]!.retire(); sessions[lane] = nil; current[lane] = nil
                    } else { decoding.append(lane) }
                }
                step += 1
                guard !decoding.isEmpty else { continue }
                let batched = try Gemma4TensorParallelPagedSession.decode(decoding.map { sessions[$0]! },
                    tokens: decoding.map { tokens[$0].last! }, check: {})
                let chosen = selection.greedyRows(batched)
                eval(chosen)
                let rowTokens = chosen.asArray(Int32.self).map(Int.init)
                for (row, lane) in decoding.enumerated() {
                    current[lane] = batched[row ..< row + 1]
                    batchedMatches = batchedMatches && rowTokens[row] == token(batched[row ..< row + 1])
                }
            }
            return (solo, soloRows, tokens, rows, batchedMatches && host.isDrained)
        }
        for rank in 0 ..< 2 {
            #expect(results[rank].lanes == results[rank].solo, "rank \(rank) lane tokens differ from solo")
            #expect(results[rank].laneRows == results[rank].soloRows, "rank \(rank) lane rows differ from solo")
            #expect(results[rank].batched, "rank \(rank): batched argmax or drained host")
        }
        #expect(results[0].lanes == results[1].lanes && results[0].solo.allSatisfy { $0.count == outputs })
    }

    /// The worker's batch host, recording what each rank publishes.
    private final class LaneHost: QwenBatchServingHost, @unchecked Sendable {
        var tokens: [UUID: [Int]] = [:], finished: [UUID: ClusterWorkerFinishReason] = [:]
        func serviceControl() throws {}
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
            guard ordinal == tokens[requestID, default: []].count else { throw ProbeError("Lane token out of order") }
            tokens[requestID, default: []].append(tokenID)
        }
        func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] {
            Dictionary(uniqueKeysWithValues: requestIDs.map { ($0, true) })
        }
        func pollDecision(_ requestID: UUID) throws -> Bool? { true }
        func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws { finished[requestID] = reason }
        func publishLeft(requestID: UUID) throws {}
        func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
    }

    /// The batch driver (`QwenTensorParallelBatchDriver`) serves three
    /// requests on both ranks through the Gemma executor: each request's
    /// published tokens are its solo tokens, every lane finishes at its
    /// length, and every page goes back.
    @Test func theBatchDriverServesEachLaneItsSoloTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let prompts = [Self.prompt, (0 ..< 23).map { ($0 * 101 + 7) % 512 }, (0 ..< 57).map { ($0 * 13 + 400) % 512 }]
        let outputs = [6, 9, 4]
        let solo = try prompts.indices.map { index in
            try Pair.run(device: .gpu) { rank in
                try models.value[rank].generatePaged(prompt: prompts[index], outputCount: outputs[index], chunk: 16).tokenIDs
            }[0]
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp", vocabularySize: 512,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: 16,
            maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
        let requests = Box(try prompts.indices.map {
            try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(), promptTokenIDs: prompts[$0],
                chunkSize: 16, outputCount: outputs[$0], stopTokenIDs: [])
        })
        let served = try Pair.run(device: .gpu) { rank -> (tokens: [UUID: [Int]], finished: [UUID: ClusterWorkerFinishReason], drained: Bool) in
            let model = models.value[rank]
            let host = try model.pagedHost(lanes: 3, maximumTokens: 128, chunkTokens: 16)
            let book = ClusterBatchLaneBook<Gemma4TensorParallelLaneReservation>()
            for request in requests.value {
                try book.reserve(request.requestID, .init(request: request, deadline: .max, laneStateBytes: 1), lanes: 3)
                try book.start(request.requestID)
            }
            let executor = try Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>(model: model,
                host: host, reduction: model.reduction!, agree: { _, check in try check() })
            let driver = try QwenTensorParallelBatchDriver(executor: executor, book: book, capacity: 3, vocabulary: 512)
            let lanes = LaneHost()
            try MLX.withError { error in try driver.serve(host: lanes, check: { try error.check() }) }
            return (lanes.tokens, lanes.finished, host.isDrained && book.isEmpty)
        }
        for (index, request) in requests.value.enumerated() {
            #expect(served[0].tokens[request.requestID] == solo[index], "lane \(index) published other tokens than alone")
            #expect(served.allSatisfy { $0.finished[request.requestID] == .length })
        }
        #expect(served[1].tokens.isEmpty && served.allSatisfy(\.drained))
    }

    // MARK: - The request loop

    private struct LoopCase: Sendable {
        var stops: Set<Int> = []
        var sampling: ClusterWorkerSampling?
        /// Rank 0's owner answers this ordinal with stop.
        var ownerStopsAt: Int?
        /// Rank 1 stops on its own after this many committed tokens.
        var rankOneStopsAfter: Int?
    }

    private struct LoopResult: Sendable {
        let tokens: [Int]
        let finish: ClusterWorkerFinishReason
        let clientStopped: Bool
        let published: [Int]
        let logprobs: [ClusterWorkerTokenLogprobs?]
    }

    /// Both ranks run the runtime's own request loop on their paged hosts
    /// (`Gemma4TensorParallelRequestLoop`), each with its own request, as two
    /// processes would.
    private static func loop(_ models: Box<[Gemma4TensorParallelModel]>, _ value: LoopCase,
                             outputs: Int = 8) throws -> [LoopResult] {
        let reductions = Box(models.value.map { $0.reduction! })
        return try Pair.run(device: .gpu) { rank in
            let model = models.value[rank], reduction = reductions.value[rank]
            let profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp", vocabularySize: 512,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: 16,
                maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(uuidString: "6f0e2a4c-0000-4000-8000-000000000001")!,
                promptTokenIDs: Self.prompt, chunkSize: 16, outputCount: outputs, stopTokenIDs: value.stops, sampling: value.sampling)
            let host = try model.pagedHost(lanes: 1, maximumTokens: 128, chunkTokens: 16)
            let session = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: Self.prompt.count,
                outputCount: outputs)
            var published: [Int] = [], logprobs: [ClusterWorkerTokenLogprobs?] = [], committed = 0
            let channel = ClusterCommittedTokenChannel(publishToken: { ordinal, token, _, captured in
                published.append(token); logprobs.append(captured); committed = ordinal + 1
            }, answer: { value.ownerStopsAt.map { committed - 1 != $0 } ?? true })
            var localTokens = 0
            let outcome = try Gemma4TensorParallelRequestLoop(session: session, request: request,
                choice: Gemma4TensorParallelChoice(selection: model.selection, sampler: request.sampler, rank: rank),
                exchange: { values in
                    let summed = reduction.allSum(MLXArray(values.map(Float.init)))
                    eval(summed)
                    return summed.asArray(Float.self).map { Int32($0) }
                }, localStop: {
                    localTokens += 1
                    return rank == 1 && value.rankOneStopsAfter.map { localTokens >= $0 } == true
                }).run(channel: channel, check: {})
            try session.retire()
            return LoopResult(tokens: outcome.tokens, finish: outcome.finish, clientStopped: outcome.clientStopped,
                published: published, logprobs: logprobs)
        }
    }

    /// The request loop on two ranks: plain greedy takes the oracle path's
    /// tokens; a stop token, the owner's stop and one rank's own stop end both
    /// ranks with the same tokens after the same step; a greedy request's
    /// logprobs come from the split top-k, a sampled one's from rank 0's draw.
    @Test func theRequestLoopEndsBothRanksAfterTheSameStep() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let reference = try Pair.run(device: .gpu) { rank in
            try models.value[rank].generatePaged(prompt: Self.prompt, outputCount: 8, chunk: 16).tokenIDs
        }[0]
        let plain = try Self.loop(models, LoopCase())
        for result in plain { #expect(result.tokens == reference && result.finish == .length) }
        #expect(plain[0].published == reference && plain[1].published.isEmpty)
        // A stop token ends both ranks at its first occurrence.
        let stopAt = reference.indices.first { $0 >= 1 && !reference[..<$0].contains(reference[$0]) } ?? 0
        for result in try Self.loop(models, LoopCase(stops: [reference[stopAt]])) {
            #expect(result.tokens == Array(reference[...stopAt]) && result.finish == .eos)
        }
        // The owner stops at ordinal 2: read a step later, both keep three tokens.
        for result in try Self.loop(models, LoopCase(ownerStopsAt: 2)) {
            #expect(result.tokens == Array(reference.prefix(3)) && result.finish == .clientStop)
        }
        // Rank 1 stops on its own after four tokens: its flag ends both.
        let alone = try Self.loop(models, LoopCase(rankOneStopsAfter: 4))
        for result in alone { #expect(result.tokens == Array(reference.prefix(4)) && result.finish == .clientStop) }
        #expect(!alone[0].clientStopped)
        // Greedy with logprobs: the same tokens, rank 0 publishes each one's split top-k.
        func sampling(_ temperature: Float) -> ClusterWorkerSampling {
            ClusterWorkerSampling(temperature: temperature, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: 0x5eed, stream: 0xab,
                logitBias: [], topLogprobs: 3)
        }
        let greedy = try Self.loop(models, LoopCase(sampling: sampling(0)))
        #expect(greedy.allSatisfy { $0.tokens == reference })
        #expect(greedy[0].logprobs.count == 8 && zip(greedy[0].logprobs, reference).allSatisfy {
            $0?.top.count == 3 && $0?.top.first?.tokenID == $1 && $0?.logprob == $0?.top.first?.logprob
        })
        // Sampled with logprobs: both ranks take rank 0's draws; rank 0 publishes the draws' logprobs.
        let sampled = try Self.loop(models, LoopCase(sampling: sampling(1.0)))
        #expect(sampled[0].tokens == sampled[1].tokens && sampled[0].tokens.count == 8)
        #expect(sampled[0].published == sampled[0].tokens && sampled[0].logprobs.allSatisfy { $0?.top.count == 3 })
    }

    // MARK: - The step's choice

    /// Runs `body` on two rank threads over each rank's half of `logits`.
    private static func splitHead<T>(_ logits: MLXArray,
                                     _ body: @escaping (Int, Gemma4TensorParallelSelection, MLXArray) throws -> T) throws -> [T] {
        let pair = Pair()
        eval(logits)
        let shared = Box((logits, body))
        return try Pair.run(device: .cpu) { rank in
            let range = (rank * 256) ..< ((rank + 1) * 256)
            let selection = Gemma4TensorParallelSelection(vocabularyRange: range, vocabularySize: 512,
                                                          reduction: pair.reduction(rank: rank))
            return try shared.value.1(rank, selection, shared.value.0[0..., range])
        }
    }

    private static func logits(seed: UInt64) -> MLXArray {
        Device.withDefaultDevice(.cpu) { withRandomState(MLXRandom.RandomState(seed: seed)) { MLXRandom.normal([1, 512]) * 3 } }
    }

    private static func sampler(temperature: Float, topLogprobs: Int = 0) throws -> QwenStageTokenSampler {
        QwenStageTokenSampler(try QwenStageSamplingState(ClusterWorkerSampling(temperature: temperature, topP: 1, topK: 0,
            minP: 0, repetitionPenalty: 1, repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0,
            seed: 0x5eed, stream: 0xab, logitBias: [], topLogprobs: topLogprobs), promptTokens: prompt))
    }

    /// Greedy: the split argmax carries each rank's stop flag in its one
    /// collective, so every rank reads the whole row's argmax and both flags.
    /// Sampled: rank 0 draws from the gathered row with the product's sampler
    /// (bit for bit the draw one Mac makes from the whole row) and rank 1
    /// reads it. Greedy logprobs: the split top-k gather's.
    @Test func eachStepsTokenAndStopFlagsAreAgreedInOneCollective() throws {
        let row = Self.logits(seed: 31)
        let argmax = Device.withDefaultDevice(.cpu) { Int(argMax(row, axis: -1).item(Int32.self)) }
        let greedy = try Self.splitHead(row) { rank, selection, local -> [Float] in
            let choice = Gemma4TensorParallelChoice(selection: selection, sampler: nil, rank: rank)
            let built = choice.build(local, stop: rank == 1 ? 3 : 0)
            eval(built)
            return built.asArray(Float.self)
        }
        #expect(greedy == [[Float(argmax), 0, 3], [Float(argmax), 0, 3]])
        for temperature in [Float(0.7), 1.0, 1.4] {
            let reference = try Device.withDefaultDevice(.cpu) {
                Int(try Self.sampler(temperature: temperature).sample(row).item(Int32.self))
            }
            let sampled = try Self.splitHead(row) { rank, selection, local -> [Float] in
                let choice = Gemma4TensorParallelChoice(selection: selection, sampler: try Self.sampler(temperature: temperature),
                                                        rank: rank)
                let built = choice.build(local, stop: rank == 0 ? 2 : 0)
                eval(built)
                return [choice.gathersRow ? 1 : 0] + built.asArray(Float.self)
            }
            #expect(sampled == [[1, Float(reference), 2, 0], [1, Float(reference), 2, 0]], "temperature \(temperature)")
        }
        let whole = try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelSelection(vocabularyRange: 0 ..< 512, vocabularySize: 512, reduction: nil).topK(row, count: 5)
        }
        let logprobs = try Self.splitHead(row) { rank, selection, local in
            try Gemma4TensorParallelChoice(selection: selection, sampler: try Self.sampler(temperature: 0, topLogprobs: 5), rank: rank)
                .logprobs(local, token: argmax, count: 5)
        }
        for value in logprobs {
            #expect(value.top.map(\.tokenID) == whole.tokenIDs && value.top.count == 5)
            #expect(zip(value.top.map(\.logprob), whole.logprobs).allSatisfy { abs($0 - $1) <= 2e-6 })
            #expect(value.logprob == value.top[0].logprob)
        }
        #expect(logprobs[0] == logprobs[1])
    }

    // MARK: - Verified load

    /// The stored tensors of a synthetic checkpoint as the verified source
    /// describes them (name, shape, stored dtype, bytes).
    private static func sourceTensors(_ directory: URL) throws -> [QwenStageSourceTensor] {
        let data = try Data(contentsOf: directory.appendingPathComponent("model.safetensors"))
        let length = data.prefix(8).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        let header = try #require(try JSONSerialization.jsonObject(with: data.subdata(in: 8 ..< 8 + length)) as? [String: Any])
        let names = ["U32": "uint32", "BF16": "bfloat16", "F32": "float32"]
        return try header.keys.filter { $0 != "__metadata__" }.map { name in
            let entry = try #require(header[name] as? [String: Any])
            let offsets = try #require(entry["data_offsets"] as? [Int])
            let stored = try #require(entry["dtype"] as? String)
            let dtype = try #require(names[stored])
            return QwenStageSourceTensor(sourceName: name, canonicalPartName: name, file: "model.safetensors",
                offset: offsets[0], shape: try #require(entry["shape"] as? [Int]), sourceDType: dtype, loadedDType: dtype,
                byteCount: offsets[1] - offsets[0])
        }
    }

    /// Every text tensor is read once and cut to exactly the bytes each
    /// rank's assembled shard holds; a tensor whose shape is not the plan's, a
    /// vision or unknown tensor, or a name given twice refuses the load.
    @Test func verifiedShardEntriesCutEveryTextTensorExactly() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tensors = try Self.sourceTensors(directory)
        let configuration = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any])
        let plan = try Gemma4TensorParallelPlan(configuration: configuration)
        for rank in 0 ..< 2 {
            let shard = try Gemma4TensorParallelVerifiedLoad.shardEntries(tensors, plan: plan, rank: rank)
            #expect(shard.entries.map(\.sourceName) == tensors.map(\.sourceName).sorted())
            let model = try Device.withDefaultDevice(.cpu) {
                try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank),
                                                   reduction: QwenTensorParallelLocalReduction(rank: rank, size: 2))
            }
            #expect(shard.bytes.reduce(0, +) == model.loadedParameterBytes, "rank \(rank)")
            #expect(shard.bytes.reduce(0, +) < tensors.map(\.byteCount).reduce(0, +))
        }
        let first = try #require(tensors.first { $0.sourceName.hasSuffix("self_attn.q_proj.weight") })
        func with(_ name: String, shape: [Int]? = nil) -> QwenStageSourceTensor {
            .init(sourceName: name, canonicalPartName: name, file: first.file, offset: 0, shape: shape ?? first.shape,
                  sourceDType: first.sourceDType, loadedDType: first.loadedDType, byteCount: first.byteCount)
        }
        let refused: [[QwenStageSourceTensor]] = [
            tensors.filter { $0.sourceName != first.sourceName } + [with(first.sourceName, shape: [first.shape[0] / 2, first.shape[1]])],
            tensors + [with("vision_tower.encoder.layers.0.weight")],
            tensors + [with("language_model.model.layers.0.unknown_proj.weight")],
            tensors + [first],
        ]
        for value in refused {
            #expect(throws: (any Error).self) { _ = try Gemma4TensorParallelVerifiedLoad.shardEntries(value, plan: plan, rank: 0) }
        }
    }

    // MARK: - Load agreement

    /// The agreement binds the mode's and the plan's terms, the prompt
    /// policy, the selection, the lanes, the KV storage and the prefix cache:
    /// any difference is another fingerprint, so the pair refuses to load.
    @Test func loadAgreementBindsTermsPolicySelectionLanesAndStorage() throws {
        let base = Gemma4TensorParallelLoadAgreement()
        for group in [Gemma4TensorParallelLoadAgreement.termsFields, Gemma4TensorParallelLoadAgreement.promptPolicyFields,
                      Gemma4TensorParallelLoadAgreement.selectionFields, ClusterTensorParallelTerms.current.loadAgreementFields,
                      Gemma4TensorParallelPlan.arithmeticAgreementFields] {
            #expect(group.allSatisfy(base.fields.contains))
        }
        let fingerprint = try base.fingerprint(admission: "row")
        #expect(try Gemma4TensorParallelLoadAgreement().fingerprint(admission: "row") == fingerprint)
        var lanes = base; lanes.lanes = 2
        var prefix = base; prefix.prefixCache = true
        var packed = base; packed.kvQuantization = .k8v8
        let others = try [lanes, prefix, packed].map { try $0.fingerprint(admission: "row") }
            + [try base.fingerprint(admission: "other row")]
        #expect(Set(others + [fingerprint]).count == 5)
    }

    // MARK: - Modes and planning

    /// Gemma advertises tensor parallel and its worker routes it to this
    /// runtime, but its layout carries no tensor-parallel facts yet: the
    /// planner never places it in tensor parallel, not even first-choice or
    /// with a measured fast link, and forcing it is refused.
    @Test func gemmaAdvertisesTensorParallelButIsNeverPlannedInIt() throws {
        #expect(Gemma4ResidentAdapterDefinition.supportedGenerationModes == [.pipeline, .tensorParallel])
        let entries = ClusterResidentModelCatalog.all.filter { Gemma4TensorParallelResidentRuntime.serves(runtimeModelID: $0.runtimeModelID) }
        #expect(entries.count == 3 && entries.allSatisfy {
            $0.family == .qwenDense && $0.family.tensorParallelSumsAreFencedInputs && $0.supportedGenerationModes.contains(.tensorParallel)
        })
        #expect(!Gemma4TensorParallelResidentRuntime.serves(runtimeModelID: "registered_qwen35_9b"))
        let inputs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs")
        let configuration = try Data(contentsOf: inputs.appendingPathComponent("config.json"))
        let manifest = try Data(contentsOf: inputs.appendingPathComponent("manifest.json"))
        let capability = try Gemma4ResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
            runtimeBinarySHA256: String(repeating: "a", count: 64))
        #expect(capability.supportedGenerationModes == [.pipeline, .tensorParallel])
        let family = try Gemma4PlacementFamily(configuration: configuration, manifest: manifest)
        #expect(family.generationModes.contains(.tensorParallel) && family.tensorParallelPlan == nil)
        var tensors: [ClusterPlacementStoredTensor] = []
        for index in 1 ... 3 {
            let header = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: inputs.appendingPathComponent(
                "model-0000\(index)-of-00003.safetensors.header.json"))) as? [String: Any])
            for (name, value) in header where name != "__metadata__" {
                let entry = try #require(value as? [String: Any])
                let shape = try #require(entry["shape"] as? [Int]), dtype = try #require(entry["dtype"] as? String)
                let size = ["U32": 4, "F32": 4, "BF16": 2, "F16": 2][dtype] ?? 1
                tensors.append(.init(name: name, byteCount: shape.reduce(size, *), dtype: dtype, shape: shape))
            }
        }
        let layout = try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
            artifactSHA256: family.specification.artifactSHA256, configurationSHA256: sha256(configuration))
        #expect(layout.generationModes.contains(.tensorParallel) && layout.tensorParallel == nil)
        let devices = try ["mac-a", "mac-b"].map { try Self.device($0) }
        var first = ClusterPlacementPolicy()
        first.tensorParallelFirst = true; first.tensorParallelAssumesUnmeasuredLink = true
        for policy in [ClusterPlacementPolicy(), first] {
            let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
            let chosen: ClusterGenerationMode? = result.chosen?.mode
            #expect(chosen == .pipeline)
            let options: [ClusterShardOption] = result.shards?.options ?? []
            let tensor = options.first { $0.kind == .tensorParallel }
            #expect(tensor?.verdict == ClusterShardOption.Verdict.adapterHasNoTensorParallel)
        }
        var only = ClusterPlacementPolicy(); only.modes = [.tensorParallel]
        #expect((try? ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: only))?.chosen == nil)
        var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
        #expect(throws: (any Error).self) { _ = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: forced) }
    }

    /// An idle 256 GB Mac, equal assumed speed: room for every placement.
    private static func device(_ name: String) throws -> ClusterPlacementDevice {
        let physical = 256 << 30, available = 220 << 30, wired = physical / 16
        let memory = ClusterDeviceMemory(gatePolicy: "placement-test", sampledUTC: "2026-11-01T00:00:00Z",
            judged: true, unjudgedReason: nil, physicalMemoryBytes: physical,
            actualFreeBytes: available, countedFileCacheBytes: 0, admissibleNowBytes: available,
            fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0,
            anonymousBytes: physical - wired - available, wiredBytes: wired, compressorBytes: 0,
            pageableBytes: physical - wired, pressureLevel: 1, swapUsedBytes: 0,
            minimumAdmissibleBytes: 6 << 30, minimumTrulyFreeBytes: 16 << 20,
            loadingHeadroomBytes: 4 << 30, allocatorHeadroomBytes: 2 << 30,
            loadScratchBytes: 8 << 20, pageSizeBytes: 16_384)
        let profile = try ClusterDeviceProfile(chip: "Apple M5 Ultra", performanceCores: 24, efficiencyCores: 8,
            gpuCores: 80, osVersion: "27.0", osBuild: "test", physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: physical * 8 / 10, gpuMaximumBufferBytes: physical / 2,
            allocatorLimitBytes: physical * 9 / 10, memory: memory,
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        return .init(label: name, profile: profile,
            speed: .init(source: .assumedEqual, absolute: false,
                rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1),
                sustained: nil, explanation: "equal-speed test; no measured performance claim"))
    }
}
