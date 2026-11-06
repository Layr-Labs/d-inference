import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
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
            try Gemma4TensorParallelModel.withLayerStride(stride) {
                try model.generatePaged(prompt: Self.prompt, outputCount: 6, chunk: 16, recordTop: 4)
            }
        }
        // Strides a bench compares (`tp-check gemma run --layer-stride`), on the synthetic model's 10 layers.
        let whole = try run(0)
        for other in try [1, 2, 5, 8].map(run) {
            #expect(other.tokenIDs == whole.tokenIDs && Self.bits(other.topLogits) == Self.bits(whole.topLogits))
            #expect(other.finalLogits.map { $0.map(\.bitPattern) } == whole.finalLogits.map { $0.map(\.bitPattern) })
        }
    }

    /// A prompt chunk's work after attention in row parts
    /// (`Gemma4TensorParallelPromptParts`), each part's sums issued as soon as
    /// they are built: both ranks keep every bit of the whole chunk's tokens,
    /// top candidates, log probabilities and final row, each 16-row chunk's
    /// layers take one attention and one feed-forward collective per part, and
    /// the link carries the same rows in all.
    @Test(arguments: [2, 4]) func promptPartsKeepEveryBitAndSplitEachChunksCollectives(parts: Int) throws {
        let topK = 4, chunk = 16
        let directory = try Self.synthetic(topK: topK)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = Self.prompt
        func run(_ parts: Int) throws -> (ranks: [Gemma4TensorParallelModel.Generation], payloads: [[Int]]) {
            let pair = Pair()
            let models = Box(try (0 ..< 2).map {
                try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0),
                                                   reduction: pair.reduction(rank: $0))
            })
            let ranks = try Pair.run(device: .gpu) { rank in
                try Gemma4TensorParallelModel.withPromptParts(parts) {
                    try models.value[rank].generatePaged(prompt: prompt, outputCount: 6, chunk: chunk, recordTop: 4)
                }
            }
            return (ranks, pair.payloads)
        }
        let whole = try run(1), split = try run(parts)
        for rank in 0 ... 1 {
            let a = whole.ranks[rank], b = split.ranks[rank]
            #expect(a.tokenIDs == b.tokenIDs && a.topTokenIDs == b.topTokenIDs, "rank \(rank)")
            #expect(Self.bits(a.topLogits) == Self.bits(b.topLogits), "rank \(rank): top logits")
            #expect(Self.bits(a.topLogprobs) == Self.bits(b.topLogprobs), "rank \(rank): log probabilities")
            #expect(a.finalLogits.map { $0.map(\.bitPattern) } == b.finalLogits.map { $0.map(\.bitPattern) }, "rank \(rank)")
        }
        // Rows of hidden width a collective carries: an attention sum's [1, S, H], a feed-forward's [S * K + S, H]
        // (K: the model's `topK` experts per token).
        func rows(_ payloads: [[Int]]) -> Set<Int> { Set(payloads.filter { $0.count > 1 }.map { $0.dropLast().reduce(1, *) }) }
        let part = chunk / parts, wholeRows = rows(whole.payloads), splitRows = rows(split.payloads)
        #expect(wholeRows.isSuperset(of: [chunk, chunk * topK + chunk]), "\(wholeRows.sorted())")
        #expect(splitRows.isSuperset(of: [part, part * topK + part]), "\(parts) parts: \(splitRows.sorted())")
        #expect(splitRows.isDisjoint(with: [chunk, chunk * topK + chunk]), "\(parts) parts: \(splitRows.sorted())")
        func elements(_ payloads: [[Int]]) -> Int { payloads.reduce(0) { $0 + $1.reduce(1, *) } }
        #expect(elements(split.payloads) == elements(whole.payloads))
    }

    /// A bench's own decode layer stride holds for its body only.
    @Test func aBenchsLayerStrideHoldsForItsBodyOnly() {
        #expect(Gemma4TensorParallelModel.layerStride == nil)
        Gemma4TensorParallelModel.withLayerStride(8) { #expect(Gemma4TensorParallelModel.layerStride == 8) }
        Gemma4TensorParallelModel.withLayerStride(nil) { #expect(Gemma4TensorParallelModel.layerStride == nil) }
        #expect(Gemma4TensorParallelModel.layerStride == nil)
        // Only ranks that decode on the calling thread see it: `simulated` is refused.
        #expect(["full", "shard", "tp"].allSatisfy { Gemma4TensorParallelModel.benchLayerStrideApplies(mode: $0) })
        #expect(!["simulated", "split-sum", ""].contains { Gemma4TensorParallelModel.benchLayerStrideApplies(mode: $0) })
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
                let chosen = selection.greedyRows(logits).tokens
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
                let chosen = selection.greedyRows(batched).tokens
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

    /// Mixed lanes through the batch driver: a greedy lane, a sampled lane
    /// and a greedy lane asking for logprobs each take the tokens (and
    /// logprobs) the request loop gives that request alone. Each rank builds
    /// its own requests, as each process does.
    @Test func mixedLanesTakeTheirSoloTokensAndLogprobs() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        func sampling(_ temperature: Float, logprobs: Int = 0) -> ClusterWorkerSampling {
            ClusterWorkerSampling(temperature: temperature, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: 0x5eed, stream: 0xab,
                logitBias: [], topLogprobs: logprobs)
        }
        let samplings: [ClusterWorkerSampling?] = [nil, sampling(1.0), sampling(0, logprobs: 2)]
        // Each request alone through the request loop, rank 0's tokens and logprobs.
        let solo = try samplings.map { value in
            let result = try Self.loop(models, LoopCase(sampling: value), outputs: 6)
            return (tokens: result[0].tokens, logprobs: result[0].logprobs)
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp", vocabularySize: 512,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: 16,
            maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
        let ids = (0 ..< 3).map { UUID(uuidString: "6f0e2a4c-0000-4000-8000-00000000001\($0)")! }
        let served = try Pair.run(device: .gpu) { rank -> (tokens: [UUID: [Int]], logprobs: [UUID: [ClusterWorkerTokenLogprobs?]]) in
            let model = models.value[rank]
            let host = try model.pagedHost(lanes: 3, maximumTokens: 128, chunkTokens: 16)
            let book = ClusterBatchLaneBook<Gemma4TensorParallelLaneReservation>()
            for (index, value) in samplings.enumerated() {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: ids[index],
                    promptTokenIDs: Self.prompt, chunkSize: 16, outputCount: 6, stopTokenIDs: [], sampling: value)
                try book.reserve(ids[index], .init(request: request, deadline: .max, laneStateBytes: 1), lanes: 3)
                try book.start(ids[index])
            }
            let executor = try Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>(model: model,
                host: host, reduction: model.reduction!, agree: { _, check in try check() })
            let driver = try QwenTensorParallelBatchDriver(executor: executor, book: book, capacity: 3, vocabulary: 512)
            let lanes = LogprobLaneHost()
            var tokens: [UUID: [Int]] = [:]
            try MLX.withError { error in
                try driver.serve(host: lanes, retiredSelection: { id, selected, _ in tokens[id] = selected },
                    check: { try error.check() })
            }
            return (tokens, lanes.logprobs)
        }
        for (index, id) in ids.enumerated() {
            #expect(served[0].tokens[id] == solo[index].tokens && served[1].tokens[id] == solo[index].tokens,
                "lane \(index) took other tokens than alone")
        }
        #expect(served[0].logprobs[ids[2]] == solo[2].logprobs && solo[2].logprobs.allSatisfy { $0?.top.count == 2 })
        #expect(served[0].logprobs[ids[1]]?.count == 6 && served[0].logprobs[ids[0]]?.allSatisfy { $0 == nil } == true)
    }

    /// A batch host that records every published token's logprobs.
    private final class LogprobLaneHost: QwenBatchServingHost, @unchecked Sendable {
        var logprobs: [UUID: [ClusterWorkerTokenLogprobs?]] = [:]
        func serviceControl() throws {}
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
            try publishToken(requestID: requestID, ordinal: ordinal, tokenID: tokenID, committedTokens: committedTokens,
                             logprobs: nil)
        }
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int,
                          logprobs captured: ClusterWorkerTokenLogprobs?) throws {
            logprobs[requestID, default: []].append(captured)
        }
        func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] {
            Dictionary(uniqueKeysWithValues: requestIDs.map { ($0, true) })
        }
        func pollDecision(_ requestID: UUID) throws -> Bool? { true }
        func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
        func publishLeft(requestID: UUID) throws {}
        func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
    }

    /// The share probe times one rank's decode step with every sum local, so
    /// one rank runs it alone; it reports an equal share, retires its request
    /// and returns every page. A load deadline too close gives no probe.
    @Test func theShareProbeTimesOneRankAlone() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reduction = QwenTensorParallelSwitchableReduction(Pair().reduction(rank: 0))
        let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: 0), reduction: reduction)
        let profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp", vocabularySize: 512,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: 16,
            maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
        let far = DispatchTime.now().uptimeNanoseconds + 600_000_000_000
        let probe = try #require(try Gemma4TensorParallelShareProbe.measure(model: model, reduction: reduction,
            profile: profile, deadline: far, admit: { _, _ in true }, check: {}))
        #expect(probe.sharePerMille == 500 && probe.plainStepMicroseconds > 0 && probe.windowColumns == nil)
        #expect(probe.rounds >= QwenTensorParallelShareProbe.minimumRounds && probe.valid)
        #expect(try Gemma4TensorParallelShareProbe.measure(model: model, reduction: reduction, profile: profile,
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000, admit: { _, _ in true }, check: {}) == nil)
        #expect(try Gemma4TensorParallelShareProbe.measure(model: model, reduction: reduction, profile: profile,
            deadline: far, admit: { _, _ in false }, check: {}) == nil)
    }

    // MARK: - The request loop

    private struct LoopCase: Sendable {
        var stops: Set<Int> = []
        var sampling: ClusterWorkerSampling?
        /// Rank 0's owner answers this ordinal with stop.
        var ownerStopsAt: Int?
        /// Rank 1 stops on its own after this many committed tokens.
        var rankOneStopsAfter: Int?
        /// The loop's step order (nil: the product's, `Gemma4TensorParallelRequestLoop.pipelines`).
        var buildsAhead: Bool?
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
            let outcome = try Gemma4TensorParallelRequestLoop.$buildsAhead.withValue(value.buildsAhead) {
              try Gemma4TensorParallelRequestLoop(session: session, request: request,
                choice: Gemma4TensorParallelChoice(selection: model.selection, sampler: request.sampler, rank: rank),
                exchange: { values in
                    let summed = reduction.allSum(MLXArray(values.map(Float.init)))
                    eval(summed)
                    return summed.asArray(Float.self).map { Int32($0) }
                }, localStop: {
                    localTokens += 1
                    return rank == 1 && value.rankOneStopsAfter.map { localTokens >= $0 } == true
                }).run(channel: channel, check: {})
            }
            try session.retire()
            return LoopResult(tokens: outcome.tokens, finish: outcome.finish, clientStopped: outcome.clientStopped,
                published: published, logprobs: logprobs)
        }
    }

    /// The request loop on two ranks: plain greedy takes the oracle path's
    /// tokens; a stop token, the owner's stop (also just before a stop token)
    /// and one rank's own stop end both ranks with the same tokens after the
    /// same step; a greedy request's logprobs come from the split top-k, a
    /// sampled one's from rank 0's draw.
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
        // The owner stops just before a stop token (keyed draws, so the
        // tokens vary): rank 1 ends at that token before rank 0's flag can
        // ride a step, and rank 0 ends there too.
        let drawn = sampled[0].tokens
        let raceAt = try #require(drawn.indices.dropFirst().dropLast().first { !drawn[..<$0].contains(drawn[$0]) })
        let race = try Self.loop(models, LoopCase(stops: [drawn[raceAt]], sampling: sampling(1.0), ownerStopsAt: raceAt - 1))
        for result in race { #expect(result.tokens == Array(drawn.prefix(raceAt)) && result.finish == .clientStop) }
        #expect(race[0].clientStopped && race[0].published == Array(drawn.prefix(raceAt)))
    }

    /// Greedy and sampled requests build their steps one ahead
    /// (`TensorParallelOneTokenLoop`, GLM's order; its two-rank order and
    /// endings are the model-free TensorParallelPlanChecks'). A greedy request
    /// asking for logprobs (a top-k gather of its own, read on the host)
    /// reads each step first. The tokens are the read-then-build order's
    /// (`theRequestLoopEndsBothRanksAfterTheSameStep`,
    /// `sampledStepsBuiltAheadTakeTheReadThenBuildTokens`).
    @Test func greedyRequestsBuildTheirStepsAhead() throws {
        let selection = Gemma4TensorParallelSelection(vocabularyRange: 0 ..< 512, vocabularySize: 512, reduction: nil)
        #expect(Gemma4TensorParallelRequestLoop.pipelines(.init(selection: selection, sampler: nil, rank: 0)))
        func pipelines(temperature: Float, topLogprobs: Int) throws -> Bool {
            Gemma4TensorParallelRequestLoop.pipelines(Gemma4TensorParallelChoice(selection: selection,
                sampler: try Self.sampler(temperature: temperature, topLogprobs: topLogprobs), rank: 0))
        }
        #expect(try pipelines(temperature: 1, topLogprobs: 0))
        #expect(try pipelines(temperature: 1, topLogprobs: 2))
        #expect(try !pipelines(temperature: 0, topLogprobs: 2))
    }

    /// Sampled requests, with logprobs and with history-dependent transforms,
    /// built one ahead: on two ranks the same tokens, finish and published
    /// logprobs as the read-then-build order, plainly and when the owner
    /// stops early (keyed draws: each token is the draw at its output index).
    @Test func sampledStepsBuiltAheadTakeTheReadThenBuildTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let drawn = ClusterWorkerSampling(temperature: 1.0, topP: 0.95, topK: 0, minP: 0, repetitionPenalty: 1.2,
            repetitionContextSize: 64, frequencyPenalty: 0.3, presencePenalty: 0, seed: 0x5eed, stream: 0xab,
            logitBias: [], topLogprobs: 3)
        for ownerStopsAt in [nil, 3] as [Int?] {
            let ahead = try Self.loop(models, LoopCase(sampling: drawn, ownerStopsAt: ownerStopsAt, buildsAhead: true), outputs: 12)
            let plain = try Self.loop(models, LoopCase(sampling: drawn, ownerStopsAt: ownerStopsAt, buildsAhead: false), outputs: 12)
            for (a, b) in zip(ahead, plain) {
                #expect(a.tokens == b.tokens && a.finish == b.finish && a.published == b.published)
                #expect(a.logprobs.map { $0?.logprob } == b.logprobs.map { $0?.logprob })
            }
            #expect(ahead[0].tokens == ahead[1].tokens && !ahead[0].tokens.isEmpty)
            #expect(ahead[0].logprobs.allSatisfy { $0?.top.count == 3 })
        }
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
    /// collective, so every rank reads the whole row's argmax, its logit and
    /// both flags. Sampled: rank 0 draws from the gathered row with the
    /// product's sampler (bit for bit the draw one Mac makes from the whole
    /// row) and rank 1 reads it. Greedy logprobs: the split top-k gather's.
    @Test func eachStepsTokenAndStopFlagsAreAgreedInOneCollective() throws {
        let row = Self.logits(seed: 31)
        let argmax = Device.withDefaultDevice(.cpu) { Int(argMax(row, axis: -1).item(Int32.self)) }
        let maximum = Device.withDefaultDevice(.cpu) { row.max().item(Float.self) }
        let greedy = try Self.splitHead(row) { rank, selection, local -> [Float] in
            let choice = Gemma4TensorParallelChoice(selection: selection, sampler: nil, rank: rank)
            let built = choice.build(local, stop: rank == 1 ? 3 : 0)
            eval(built)
            return built.asArray(Float.self)
        }
        #expect(greedy == [[Float(argmax), 0, 3, maximum], [Float(argmax), 0, 3, maximum]])
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
                .logprobs(local, token: argmax, maximum: maximum, count: 5)
        }
        for value in logprobs {
            #expect(value.top.map(\.tokenID) == whole.tokenIDs && value.top.count == 5)
            #expect(zip(value.top.map(\.logprob), whole.logprobs).allSatisfy { abs($0 - $1) <= 2e-6 })
            #expect(value.logprob == value.top[0].logprob)
        }
        #expect(logprobs[0] == logprobs[1])
    }

    /// A greedy token's logit is the row's maximum, so its logprob is the
    /// split top-k gather's first even when another, exactly tied ID leads
    /// the gather (a softcapped BF16 head ties at the top; which tied IDs a
    /// rank's partition keeps is not the argmax's rule): both ranks publish
    /// the same logprobs for it, and refuse alike a gather that does not lead
    /// with the token's logit.
    @Test func greedyLogprobsSurviveAnExactlyTiedMaximum() throws {
        // IDs 10 and 20 tie at the row's maximum on rank 0; rank 1's maximum (ID 300) is lower.
        var values = [Float](repeating: -1, count: 512)
        values[10] = 4; values[20] = 4; values[300] = 3.5
        let row = MLXArray(values).reshaped(1, 512)
        let whole = try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelSelection(vocabularyRange: 0 ..< 512, vocabularySize: 512, reduction: nil).topK(row, count: 3)
        }
        for count in 1 ... 3 {
            let ranks = try Self.splitHead(row) { rank, selection, local -> [(Int, ClusterWorkerTokenLogprobs)] in
                let choice = Gemma4TensorParallelChoice(selection: selection,
                    sampler: try Self.sampler(temperature: 0, topLogprobs: count), rank: rank)
                let built = choice.build(local, stop: 0)
                eval(built)
                let agreed = try choice.read(built)
                // The agreed token, then the other tied ID, whichever of the two leads the gather.
                return try [agreed.token, 30 - agreed.token].map { token in
                    (token, try choice.logprobs(local, token: token, maximum: agreed.maximum, count: count))
                }
            }
            #expect(ranks.allSatisfy { $0.map { $0.0 } == [10, 20] }, "the split argmax takes the lowest tied ID")
            for (token, published) in ranks[0] + ranks[1] {
                #expect(published == ranks[0][0].1, "token \(token), \(count) alternatives")
                #expect(published.top.count == count && published.logprob == published.top[0].logprob)
                #expect(abs(published.logprob - whole.logprobs[0]) <= 2e-6 && whole.logprobs[0] == whole.logprobs[1])
                #expect(published.top.prefix(2).allSatisfy { [10, 20].contains($0.tokenID) && $0.logprob == published.logprob })
            }
        }
        // A maximum the gather does not lead with, a token listed below it, or no maximum (a sampled
        // step): refused on both ranks alike.
        let refused = try Self.splitHead(row) { rank, selection, local -> [Bool] in
            let choice = Gemma4TensorParallelChoice(selection: selection, sampler: try Self.sampler(temperature: 0, topLogprobs: 3),
                                                    rank: rank)
            let cases: [(token: Int, maximum: Float?)] = [(10, 3.5), (300, 4), (10, nil)]
            return cases.map { (try? choice.logprobs(local, token: $0.token, maximum: $0.maximum, count: 3)) == nil }
        }
        #expect(refused == [[true, true, true], [true, true, true]])
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
        // This build keeps prompt prefixes; a rank whose diagnosis switch turned them off refuses its peer.
        #expect(base.prefixCache && base.prefixCache == Gemma4ResidentAdapterDefinition.tensorParallelKeepsPromptPrefixes)
        var lanes = base; lanes.lanes = 2
        var prefix = base; prefix.prefixCache = false
        var packed = base; packed.kvQuantization = .k8v8
        let others = try [lanes, prefix, packed].map { try $0.fingerprint(admission: "row") }
            + [try base.fingerprint(admission: "other row")]
        #expect(Set(others + [fingerprint]).count == 5)
    }

    /// What the capability declares of each mode is what the loads run: tensor parallel binds the prompt-prefix cache
    /// into its agreement and declares it resident and on the SSD tier, as the pipeline does; both modes take the batch
    /// wire's lanes, and only tensor parallel captures logprobs. The provider's setup check plans with these values
    /// (`PlacementSetupCheck.gemmaFeatures`).
    @Test func capabilityDeclaresWhatEachModeKeeps() throws {
        let features = Gemma4ResidentAdapterDefinition.servingFeatures
        #expect(features == [
            .pipeline: .init(promptPrefixReuse: true, ssdPrefixTier: true, speculativeRounds: false, maximumLanes: 8, logprobs: false),
            .tensorParallel: .init(promptPrefixReuse: true, ssdPrefixTier: true, speculativeRounds: false, maximumLanes: 8, logprobs: true),
        ])
        #expect(Set(features.keys) == Set(Gemma4ResidentAdapterDefinition.supportedGenerationModes))
        #expect(features[.tensorParallel]?.promptPrefixReuse == Gemma4ResidentAdapterDefinition.tensorParallelKeepsPromptPrefixes
            && Gemma4TensorParallelLoadAgreement().prefixCache == Gemma4ResidentAdapterDefinition.tensorParallelKeepsPromptPrefixes
            && features[.pipeline]?.maximumLanes == QwenBatchWire.maximumLanes)
        let pipeline = try #require(features[.pipeline]), tensor = try #require(features[.tensorParallel])
        #expect(pipeline.dropped(by: tensor) == [])
        #expect(tensor.dropped(by: pipeline) == ["committed-token logprobs"])
    }

    // MARK: - Request memory

    /// A decode step is submitted layer by layer in 100-operation buffers, so
    /// several layers' temporaries are alive at once: a request is charged one
    /// decode row on every layer (each layer's scores and output row over its
    /// own 8 query heads, and its FP32 partials) wherever that exceeds its
    /// prompt chunk's, and the profile's LOAD quote is unchanged.
    @Test func aDecodeStepsRowOnEveryLayerIsCharged() throws {
        typealias G = Gemma4StageGeometry
        let bound: (Int) throws -> Int = { $0 + 16_384 }
        let heads = G.queryHeads / 2
        let kinds = (0 ..< G.layerCount).map(G.isFullAttention(globalLayerIndex:))
        func derive(_ context: Int, chunk: Int = 512, prompt: Int = 1) throws -> Gemma4TensorParallelRequestBudget {
            try Gemma4TensorParallelRequestBudget.derive(contextTokens: context, chunkTokens: chunk, promptTokens: prompt,
                keepsPrefixes: false, allocationBound: bound)
        }
        func partials(rows: Int) throws -> Int {
            let row = rows * G.hiddenSize * 4
            return try bound(row) * 2 + bound(row * G.expertsPerToken)
                + bound(rows * Gemma4TensorParallelRequestBudget.maximumPartialBytesPerToken)
        }
        for context in [2, 3, 8, 17, 18, 29, 30, 31, 64, 600] {
            let budget = try derive(context)
            let decode = kinds.reduce(0) { total, full in
                let keys = full ? context : min(context, G.slidingWindow)
                let width = full ? G.fullHeadDimension : G.slidingHeadDimension
                return total + heads * keys * 4 + heads * width * 4
            }
            let chunk = min(context, 512)
            let frame = try Gemma4PrefillTransient.bytes(fullAttention: kinds, queryHeads: heads, chunkTokens: chunk,
                                                         contextTokens: context)
            #expect(budget.transientBytes == (try bound(max(frame, decode))), "context \(context): transient")
            #expect(budget.partialBytes == (try partials(rows: max(chunk, G.layerCount))), "context \(context): partials")
        }
        // A one-token prompt with one output token: 30 decode rows, not its two-row frame.
        let shortest = try derive(2)
        #expect(shortest.transientBytes > (try bound(Gemma4PrefillTransient.bytes(fullAttention: kinds, queryHeads: heads,
            chunkTokens: 2, contextTokens: 2))))
        #expect(shortest.partialBytes > (try partials(rows: 2)))
        // The LOAD quote (65,536 tokens, 512-token chunks): a chunk covers a step, so nothing changes.
        let profile = try derive(65_536, prompt: 32_768)
        #expect(profile.transientBytes == (try bound(Gemma4PrefillTransient.bytes(fullAttention: kinds, queryHeads: heads,
            chunkTokens: 512, contextTokens: 65_536))))
        #expect(profile.partialBytes == (try partials(rows: 512)))
    }

    // MARK: - Modes and planning

    /// Gemma advertises tensor parallel, its worker routes it to this runtime,
    /// and its layout carries the plan's facts with the fastest-plan choice:
    /// under the provider's tensor-parallel-first policy two big Macs keep the
    /// pipeline on default link costs; on a measured fast link tensor parallel
    /// is predicted faster from the device index alone, so the pipeline is kept
    /// until a share probe measures each rank, which then takes it; and the
    /// developer's forced mode places it. (`PlacementChecks`' Gemma checks
    /// cover the same rule on more pairs, model-free.)
    @Test func gemmaIsPlannedInTensorParallelOnlyWherePredictedFaster() throws {
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
        // The product's own layout, with the allocator's bound: the rank's native reserve is quoted.
        let layout = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors, manifest: manifest)
        let plan = try #require(layout.tensorParallel?.family)
        #expect(plan.plan == Gemma4TensorParallelPlan.name && plan.choice == .fastest && plan.ranks == [2]
            && plan.reductionsPerLayer == 2 && plan.reductionsPerStep == 1 && plan.stateDividesByHeads)
        let reserve = try #require(plan.requestAllowance)
        #expect(reserve.reservedBytes >= Gemma4TensorParallelRequestBudget.activationFloorBytes)
        let devices = try ["mac-a", "mac-b"].map { try Self.device($0) }
        var first = ClusterPlacementPolicy()
        first.tensorParallelFirst = true; first.tensorParallelAssumesUnmeasuredLink = true
        first.promptTokens = 128; first.outputTokens = 128
        // Big Macs, default link costs: the pipeline, whatever the policy.
        for policy in [ClusterPlacementPolicy(), first] {
            let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
            #expect(result.chosen?.mode == .pipeline)
            #expect(result.tensorParallel?.verdict != .chosen)
        }
        // Measured rates on both Macs (90 tok/s, 7,000 prefill) and their device index (the M5 Ultra's measured
        // `qmm_h4096_b4_g64_x16_v1`), with a measured 5 us link: tensor parallel is predicted faster on the index
        // alone, so the pipeline is kept; with each rank's share probe (8.5 ms a half step), tensor parallel.
        let measured = devices.map { device -> ClusterPlacementDevice in
            var profile = device.profile
            profile.speedIndex = .init(chip: profile.chip, osBuild: profile.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
                prefillIndex: 2_337_768, decodeIndex: 46_409)
            return .init(label: device.label, profile: profile, speed: .init(source: .measured, absolute: true,
                rested: .init(prefillTokensPerSecond: 7_000, decodeTokensPerSecond: 90), sustained: nil, explanation: "test input"))
        }
        let fast = ClusterLinkCosts(measured: true, perChunkSeconds: 0.0025, perDecodeStepSeconds: [ClusterGenerationMode.pipeline.rawValue: 360e-6],
            handoffSecondsPerByte: 1 / 2e9, provenance: "test input",
            reduction: .init(fixedSeconds: 5e-6, secondsPerByte: 1 / 30e9, keyed: true, provenance: "test input"))
        let prior = try ClusterPlacementPlanner.plan(devices: measured, layout: layout, policy: first, link: fast)
        #expect(prior.chosen?.mode == .pipeline && prior.tensorParallel?.verdict == .predictedFasterOnPriorOnly)
        let probed = measured.map { $0.addingShareRates([$0.label: [ClusterShareRate(sharePerMille: 500, decodeTokensPerSecond: 1 / 0.0085)]]) }
        let evidenced = try ClusterPlacementPlanner.plan(devices: probed, layout: layout, policy: first, link: fast)
        #expect(evidenced.chosen?.mode == .tensorParallel && evidenced.tensorParallel?.evidence == .measured)
        #expect(try ClusterPlacementPlanner.plan(devices: measured, layout: layout, policy: first).chosen?.mode == .pipeline)
        var forced = ClusterPlacementPolicy(); forced.forcedMode = .tensorParallel
        #expect(try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: forced).chosen?.mode == .tensorParallel)
        // Each rank is charged its own heads: half the whole model's KV, the residual rows and logits whole.
        let whole = try Gemma4StateBudget.estimate(maximumTokens: 8_320, chunkSize: 512)
        let own = try Gemma4StateBudget.estimate(maximumTokens: 8_320, chunkSize: 512, ranks: 2)
        #expect(own.fullKVBytes * 2 == whole.fullKVBytes && own.ringKVBytes * 2 == whole.ringKVBytes
            && own.boundaryBytes == whole.boundaryBytes && own.logitsBytes == whole.logitsBytes)
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
