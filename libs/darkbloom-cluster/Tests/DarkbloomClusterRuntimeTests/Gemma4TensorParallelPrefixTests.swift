import DarkbloomClusterProtocol
import Darwin
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Gemma 4 tensor parallel's prompt prefixes (`Gemma4TensorParallelPrefix`)
/// on synthetic checkpoints and two in-process ranks: a restore equals the
/// cold prefill bit for bit (logits, every row of state, the sliding
/// windows), both ranks agree on every hit or miss through the sealed vote
/// and its confirmation, the memory tier evicts within its budget, and the
/// encrypted SSD tier keeps the cluster tier's rules. Never a model pass.
@Suite("Gemma 4 tensor-parallel prompt prefixes", .serialized)
struct Gemma4TensorParallelPrefixTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
    private static let longer = prompt + (0 ..< 13).map { ($0 * 53 + 5) % 512 }
    private static let other = (0 ..< 40).map { ($0 * 29 + 300) % 512 }
    private static let chunk = 16, outputs = 6, recordTop = 4

    private static func synthetic() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-tp-prefix-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, bits: 4, experts: 16, topK: 4)
        }
        return directory
    }

    private static func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }

    private static func same(_ a: Gemma4TensorParallelModel.Generation, _ b: Gemma4TensorParallelModel.Generation) -> Bool {
        a.tokenIDs == b.tokenIDs && a.topTokenIDs == b.topTokenIDs && bits(a.topLogits) == bits(b.topLogits)
            && bits(a.topLogprobs) == bits(b.topLogprobs)
            && a.finalLogits.map { $0.map(\.bitPattern) } == b.finalLogits.map { $0.map(\.bitPattern) } && a.finalLogits != nil
    }

    private static func models(_ directory: URL, _ pair: Pair) throws -> Box<[Gemma4TensorParallelModel]> {
        Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
    }

    /// One rank's prefix tiers, paged host and requests, served as the
    /// resident runtime serves them (`Gemma4TensorParallelPrefix.open`,
    /// then the kept boundaries stored after a clean end).
    private final class Rank: @unchecked Sendable {
        let model: Gemma4TensorParallelModel
        let host: CBv2StageKVHost
        var prefix: Gemma4TensorParallelPrefix
        let profile: QwenLayerStageGenerationProfile
        var captureLimit: Int?

        init(_ model: Gemma4TensorParallelModel, cache: QwenStagePrefixCache = QwenStagePrefixCache(strideTokens: chunk),
             disk: QwenStagePrefixDiskTier? = nil) throws {
            self.model = model
            host = try model.pagedHost(lanes: 1, maximumTokens: 128, chunkTokens: chunk)
            cache.disk = disk
            prefix = Gemma4TensorParallelPrefix(cache: cache, load: "gemma4-tp-prefix-tests", diskPlanScope: "gemma4-tp-prefix-tests-disk")
            profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp-prefix", vocabularySize: 512,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: chunk,
                maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
        }

        func request(_ tokens: [Int], chunk: Int = Gemma4TensorParallelPrefixTests.chunk,
                     cache: ClusterWorkerPrefixCache? = nil) throws -> QwenLayerStageGenerationRequest {
            try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                promptTokenIDs: tokens, chunkSize: chunk, outputCount: outputs, stopTokenIDs: [], prefixCache: cache)
        }

        struct Served { let generation: Gemma4TensorParallelModel.Generation; let reused: Int; let stored: [Int] }

        func serve(_ request: QwenLayerStageGenerationRequest) throws -> Served {
            let session = try MLX.withError { error -> Gemma4TensorParallelPagedSession in
                let value = try prefix.open(request, model: model, host: host, group: model.reduction!,
                    captureLimit: captureLimit ?? prefix.captureLimit(request))
                try error.check()
                return value
            }
            let generation = try model.generatePaged(session: session, host: host, prompt: request.promptTokenIDs,
                outputCount: request.outputCount, chunk: request.chunkSize, recordTop: recordTop)
            var stored: [Int] = []
            if let capture = session.prefixCapture, let scopes = prefix.scopes(request) {
                stored = prefix.store(capture, request: request, scopes: scopes, rank: model.reduction!.rank)
            }
            return Served(generation: generation, reused: session.reusedPrefixTokens, stored: stored)
        }
    }

    // MARK: - Restore equals cold

    /// A repeated prompt restores the deepest boundary both ranks hold (32 of
    /// 40 tokens on 16-token chunks) and continues on the same chunk grid:
    /// its tokens, every recorded top logit and log probability and the final
    /// row equal the cold request's bit for bit, on both ranks; a longer
    /// prompt sharing the prefix restores the same boundary and equals that
    /// prompt prefilled cold. The same ranks agree with each other bit for bit.
    @Test func aRestoredPrefixEqualsTheColdPrefillBitwiseOnBothRanks() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let ranks = try Pair.run(device: .gpu) { rank in
            let model = models.value[rank]
            let repeated = try model.generatePagedRepeatingPrefix(prompt: Self.prompt, outputCount: Self.outputs,
                chunk: Self.chunk, recordTop: Self.recordTop)
            let extended = try model.generatePagedRepeatingPrefix(prompt: Self.prompt, repeated: Self.longer,
                outputCount: Self.outputs, chunk: Self.chunk, recordTop: Self.recordTop)
            let coldLonger = try model.generatePaged(prompt: Self.longer, outputCount: Self.outputs, chunk: Self.chunk,
                recordTop: Self.recordTop)
            return (repeated, extended, coldLonger)
        }
        for (rank, value) in ranks.enumerated() {
            #expect(value.0.reusedPromptTokens == 32 && value.0.storedFrontiers == [16, 32], "rank \(rank)")
            #expect(Self.same(value.0.restored, value.0.cold), "rank \(rank): restored \(value.0.restored.tokenIDs), cold \(value.0.cold.tokenIDs)")
            #expect(value.1.reusedPromptTokens == 32 && Self.same(value.1.restored, value.2), "rank \(rank): the longer prompt")
        }
        #expect(Self.same(ranks[0].0.restored, ranks[1].0.restored) && Self.same(ranks[0].1.restored, ranks[1].1.restored))
    }

    /// The state a restore writes is the cold request's at the boundary,
    /// every layer's rows and position offsets and each sliding layer's
    /// window (`CBv2OwnedStateSnapshot`), and after the next prompt chunk the
    /// logits and every row (the windows having taken that chunk in place)
    /// still are. Both ranks, their own heads.
    @Test func aRestoredStateEqualsTheColdStateAtTheBoundaryAndAfterTheNextChunk() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [Bool] in
            let model = models.value[rank]
            let host = try model.pagedHost(lanes: 1, maximumTokens: 128, chunkTokens: Self.chunk)
            let layers = Array(0 ..< model.plan.layerCount)
            func fingerprint(_ session: Gemma4TensorParallelPagedSession) throws -> String {
                try session.state.snapshot(globalLayerIndices: layers, includeBytes: false, check: {}).fingerprint
            }
            return try MLX.withError { error -> [Bool] in
                let check: () throws -> Void = { try error.check() }
                let cold = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: Self.prompt.count,
                    outputCount: Self.outputs)
                cold.prefixCapture = .init(frontiers: [16, 32], limitBytes: Int.max, maximumFrontiers: 32)
                _ = try cold.prefill(Self.prompt, range: 0 ..< 16, check: check) { $0 }
                _ = try cold.prefill(Self.prompt, range: 16 ..< 32, check: check) { $0 }
                let coldAt32 = try fingerprint(cold)
                let coldLogits = try #require(try cold.prefill(Self.prompt, range: 32 ..< 40, check: check) { $0 }).logits
                let coldAt40 = try fingerprint(cold)
                let states = try #require(cold.prefixCapture).states()
                let deepest: QwenStagePrefixState = try #require(states.last)
                try cold.retire()
                let restored = try Gemma4TensorParallelPagedSession(model: model, host: host,
                    promptCount: Self.prompt.count, outputCount: Self.outputs, restoring: deepest)
                let restoredAt32 = try fingerprint(restored)
                let restoredLogits = try #require(try restored.prefill(Self.prompt, range: 32 ..< 40, check: check) { $0 }).logits
                let restoredAt40 = try fingerprint(restored)
                let logitsEqual = coldLogits.asArray(Float.self).map(\.bitPattern) == restoredLogits.asArray(Float.self).map(\.bitPattern)
                try restored.retire()
                return [states.map(\.committedTokens) == [16, 32], restored.reusedPrefixTokens == 32,
                        coldAt32 == restoredAt32, logitsEqual, coldAt40 == restoredAt40, host.isDrained]
            }
        }
        for (rank, checks) in results.enumerated() {
            #expect(checks == [true, true, true, true, true, true], "rank \(rank): kept, reused, state@32, logits, state@40, drained")
        }
    }

    /// The resident runtime's own request loop (`Gemma4TensorParallelRequestLoop`)
    /// on a restored session continues from the boundary: a greedy and a
    /// sampled request (keyed draws, so a differing logit would move a token)
    /// publish exactly the tokens their cold runs published, on both ranks.
    @Test func theRequestLoopContinuesARestoredPrefixWithTheColdTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let sampling = ClusterWorkerSampling(temperature: 1.0, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: 0x5eed, stream: 0xab, logitBias: [],
            topLogprobs: 0)
        let results = try Pair.run(device: .gpu) { rank -> [[Int]] in
            let fixture = try Rank(models.value[rank])
            var runs: [[Int]] = []
            for sampled in [false, true] {
                // A prompt's state does not depend on its sampler: start each pair cold.
                fixture.prefix.cache.sweep()
                for _ in 0 ..< 2 {
                    let request = try QwenLayerStageGenerationRequest(profile: fixture.profile,
                        requestID: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(sampled ? 2 : 1)")!,
                        promptTokenIDs: Self.prompt, chunkSize: Self.chunk, outputCount: 8, stopTokenIDs: [],
                        sampling: sampled ? sampling : nil)
                    let reduction = fixture.model.reduction!
                    let session = try fixture.prefix.open(request, model: fixture.model, host: fixture.host, group: reduction,
                        captureLimit: fixture.prefix.captureLimit(request))
                    var published: [Int] = []
                    let channel = ClusterCommittedTokenChannel(publishToken: { _, token, _, _ in published.append(token) },
                        answer: { true })
                    let outcome = try MLX.withError { error in
                        try Gemma4TensorParallelRequestLoop(session: session, request: request,
                            choice: Gemma4TensorParallelChoice(selection: fixture.model.selection, sampler: request.sampler, rank: rank),
                            exchange: { values in
                                let summed = reduction.allSum(MLXArray(values.map(Float.init)))
                                eval(summed)
                                return summed.asArray(Float.self).map { Int32($0) }
                            }, localStop: { false }).run(channel: channel, check: { try error.check() })
                    }
                    try session.retire()
                    if let capture = session.prefixCapture, let scopes = fixture.prefix.scopes(request) {
                        fixture.prefix.store(capture, request: request, scopes: scopes, rank: rank)
                    }
                    runs.append([session.reusedPrefixTokens] + outcome.tokens + (rank == 0 ? published : outcome.tokens))
                }
            }
            return runs
        }
        for (rank, runs) in results.enumerated() {
            #expect(runs.map { $0[0] } == [0, 32, 0, 32], "rank \(rank): cold, restored, cold, restored")
            #expect(runs[0].dropFirst() == runs[1].dropFirst() && runs[2].dropFirst() == runs[3].dropFirst(),
                    "rank \(rank): a restored request publishes its cold tokens, greedy and sampled")
        }
        #expect(results[0] == results[1])
    }

    /// The batch driver's lanes vote, restore and keep prefixes as a request
    /// served alone does: a repeated request restores in its lane, takes its
    /// cold tokens, and both report what each lane reused and stored.
    @Test func lanesRestoreAndKeepPrefixesThroughTheBatchDriver() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        final class Host: QwenBatchServingHost, @unchecked Sendable {
            var tokens: [UUID: [Int]] = [:], cache: [UUID: (reused: Int, stored: [Int])] = [:]
            func serviceControl() throws {}
            func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
                tokens[requestID, default: []].append(tokenID)
            }
            func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] { Dictionary(uniqueKeysWithValues: requestIDs.map { ($0, true) }) }
            func pollDecision(_ requestID: UUID) throws -> Bool? { true }
            func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
            func publishLeft(requestID: UUID) throws {}
            func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {
                cache[requestID] = (reusedTokens, storedFrontiers)
            }
        }
        let results = try Pair.run(device: .gpu) { rank -> [String] in
            let fixture = try Rank(models.value[rank])
            let lanesHost = try fixture.model.pagedHost(lanes: 2, maximumTokens: 128, chunkTokens: Self.chunk)
            var lines: [String] = []
            for round in 0 ..< 2 {
                let requests = try [Self.prompt, Self.other].enumerated().map { index, prompt in
                    try QwenLayerStageGenerationRequest(profile: fixture.profile,
                        requestID: UUID(uuidString: "00000000-0000-4000-8000-0000000001\(round)\(index)")!,
                        promptTokenIDs: prompt, chunkSize: Self.chunk, outputCount: Self.outputs, stopTokenIDs: [])
                }
                let book = ClusterBatchLaneBook<Gemma4TensorParallelLaneReservation>()
                for request in requests {
                    try book.reserve(request.requestID, .init(request: request, deadline: .max, laneStateBytes: 1,
                        prefixCaptureLimit: fixture.prefix.captureLimit(request)), lanes: 2)
                    try book.start(request.requestID)
                }
                let executor = try Gemma4TensorParallelBatchExecutor<Gemma4TensorParallelLaneReservation>(model: fixture.model,
                    host: lanesHost, reduction: fixture.model.reduction!, prefix: fixture.prefix, agree: { _, check in try check() })
                let driver = try QwenTensorParallelBatchDriver(executor: executor, book: book, capacity: 2, vocabulary: 512)
                let host = Host()
                var selected: [UUID: [Int]] = [:]
                try MLX.withError { error in
                    try driver.serve(host: host, retiredSelection: { id, tokens, _ in selected[id] = tokens },
                        check: { try error.check() })
                }
                for request in requests {
                    let cache = host.cache[request.requestID]
                    lines.append("\(round) reused=\(cache?.reused ?? 0) stored=\(cache?.stored ?? []) tokens=\(selected[request.requestID] ?? [])")
                }
                lines.append("drained=\(lanesHost.isDrained)")
            }
            return lines
        }
        for (rank, lines) in results.enumerated() {
            #expect(lines[0].hasPrefix("0 reused=0 stored=[16, 32]") && lines[1].hasPrefix("0 reused=0 stored=[16, 32]"), "rank \(rank): \(lines)")
            #expect(lines[3].hasPrefix("1 reused=32 stored=[]") && lines[4].hasPrefix("1 reused=32 stored=[]"), "rank \(rank): \(lines)")
            let tokens = lines.map { $0.components(separatedBy: " tokens=").last ?? "" }
            #expect(tokens[0] == tokens[3] && tokens[1] == tokens[4] && lines[2] == "drained=true" && lines[5] == "drained=true",
                    "rank \(rank): each restored lane takes its cold tokens")
        }
        #expect(results[0] == results[1])
    }

    // MARK: - Hit or miss, agreed

    /// Both ranks agree on every hit or miss before using it: a boundary only
    /// one rank holds is a miss on both (the vote sums 1); a boundary both
    /// offer whose state one rank cannot restore (it does not adopt into that
    /// rank's geometry) is declined by the confirmation on both; another
    /// chunk grid is another key; a request whose cache is off votes nothing
    /// and keeps nothing. Every case prefills from zero on both ranks with
    /// the cold request's every bit.
    @Test func bothRanksAgreeOnEveryHitOrMiss() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [String: (reused: Int, same: Bool, stored: [Int])] in
            let fixture = try Rank(models.value[rank])
            let request = try fixture.request(Self.prompt)
            let cold = try fixture.serve(request)
            var outcomes: [String: (reused: Int, same: Bool, stored: [Int])] = [:]
            func record(_ name: String, _ served: Rank.Served) {
                outcomes[name] = (served.reused, Self.same(served.generation, cold.generation), served.stored)
            }
            // Rank 1 lost what it kept; rank 0 still holds both boundaries.
            if rank == 1 { fixture.prefix.cache.sweep() }
            record("one-rank", try fixture.serve(request))
            // Both hold the boundary again (the miss kept it on rank 1); rank 1's
            // entry at 32 is replaced by one of another geometry.
            if rank == 1 {
                let scope = try #require(fixture.prefix.scopes(request)).resident
                let held = try #require(fixture.prefix.cache.state(scope: scope, tokens: Self.prompt, frontier: 32))
                let truncated = held.attention.mapValues { pair -> (keys: MLXArray, values: MLXArray) in
                    (keys: pair.keys[0..., 0..., 0 ..< 31, 0...], values: pair.values[0..., 0..., 0 ..< 31, 0...])
                }
                fixture.prefix.cache.insert(scope: scope, tokens: Self.prompt, states: [QwenStagePrefixState(committedTokens: 32,
                    attention: truncated, recurrent: held.recurrent)], sharedBytes: 0)
            }
            record("not-adoptable", try fixture.serve(request))
            record("other-grid", try fixture.serve(try fixture.request(Self.prompt, chunk: 8)))
            record("cache-off", try fixture.serve(try fixture.request(Self.prompt,
                cache: ClusterWorkerPrefixCache.partition(prefixCacheEnabled: false, cacheSalt: nil))))
            record("both", try fixture.serve(request))
            return outcomes
        }
        for (rank, outcomes) in results.enumerated() {
            #expect(outcomes["one-rank"]?.reused == 0 && outcomes["one-rank"]?.same == true, "rank \(rank): one rank held it")
            #expect(outcomes["not-adoptable"]?.reused == 0 && outcomes["not-adoptable"]?.same == true, "rank \(rank): one rank could not restore it")
            #expect(outcomes["other-grid"]?.reused == 0, "rank \(rank): another chunk grid")
            #expect(outcomes["cache-off"]?.reused == 0 && outcomes["cache-off"]?.stored == [] && outcomes["cache-off"]?.same == true,
                    "rank \(rank): a request whose cache is off")
            #expect(outcomes["both"]?.reused == 32 && outcomes["both"]?.same == true, "rank \(rank): both hold it")
        }
    }

    // MARK: - Budget and eviction

    /// The memory tier keeps what its budget holds and evicts the least
    /// recently used prompt alike on both ranks (a repeat then misses on
    /// both); a capture keeps the deepest boundary first and grid boundaries
    /// only within its limit, and nothing when even the deepest does not fit.
    @Test func theMemoryTierEvictsWithinItsBudgetAndCapturesWithinTheLimit() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [Int] in
            // Measure one capture's bytes, then hold one prompt's at most.
            let probe = try Rank(models.value[rank])
            _ = try probe.serve(try probe.request(Self.prompt))
            let one = probe.prefix.cache.bytesInUse
            // A budget of one prompt: a second prompt's entries evict the first's grid
            // boundaries, then its own, then the least recently used deepest one.
            let fixture = try Rank(models.value[rank], cache: QwenStagePrefixCache(strideTokens: Self.chunk, budgetBytes: one))
            let first = try fixture.serve(try fixture.request(Self.prompt))
            _ = try fixture.serve(try fixture.request(Self.other))
            let kept = try fixture.serve(try fixture.request(Self.other))
            let evicted = try fixture.serve(try fixture.request(Self.prompt))
            // The deepest boundary alone: its rows and one window.
            let cost = try #require(fixture.prefix.cache.captureCost)
            let tight = try Rank(models.value[rank])
            tight.captureLimit = cost.bytes(deepest: 32, frontiers: 1)
            let deepestOnly = try tight.serve(try tight.request(Self.prompt))
            let none = try Rank(models.value[rank])
            none.captureLimit = cost.bytes(deepest: 32, frontiers: 1) - 1
            let nothing = try none.serve(try none.request(Self.prompt))
            return [one > 0 ? 1 : 0, first.stored.count, kept.reused, evicted.reused, deepestOnly.stored.last ?? 0,
                    deepestOnly.stored.count, nothing.stored.count, fixture.prefix.cache.bytesInUse <= one ? 1 : 0]
        }
        for (rank, value) in results.enumerated() {
            #expect(value == [1, 2, 32, 0, 32, 1, 0, 1], "rank \(rank): measured, kept, kept hit, evicted miss, deepest only, none, budget")
        }
    }

    /// A tier the measured room leaves without budget (as on two 24 GB Macs)
    /// keeps nothing resident, but a request still captures what its own
    /// charge covers (`captureLimit(_:chargedBytes:)`): its deepest boundary
    /// reaches the SSD tier, and a repeat restores it from there on both
    /// ranks, bit for bit.
    @Test func aRequestCapturesWithinItsChargeWhenTheTierHasNoBudget() throws {
        let directory = try Self.synthetic()
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [String: Bool] in
            // The deepest boundary's cost, measured as a load's first capture measures it.
            let probe = try Rank(models.value[rank])
            let request = try probe.request(Self.prompt)
            let cold = try probe.serve(request)
            let charged = try #require(probe.prefix.cache.captureCost).bytes(deepest: 32, frontiers: 1)
            let tier = QwenStagePrefixCache(strideTokens: Self.chunk, budgetBytes: 0)
            let fixture = try Rank(models.value[rank], cache: tier, disk: try Self.tier(root, rank: rank))
            let limit = fixture.prefix.captureLimit(request, chargedBytes: charged)
            let withoutCharge = fixture.prefix.captureLimit(request)
            fixture.captureLimit = limit
            let first = try fixture.serve(request)
            let disk = try #require(fixture.prefix.disk)
            let written = disk.drain(timeoutSeconds: 60) && disk.recordCount == 1
            let repeated = try fixture.serve(request)
            disk.close(timeoutSeconds: 5)
            return ["limit": limit == charged && withoutCharge == 0, "stored": first.stored == [32],
                    "resident": tier.bytesInUse == 0 && tier.count == 0, "written": written,
                    "restored": repeated.reused == 32 && Self.same(repeated.generation, cold.generation)
                        && disk.stats.restores == 1]
        }
        for (rank, checks) in results.enumerated() {
            for name in ["limit", "stored", "resident", "written", "restored"] {
                #expect(checks[name] == true, "rank \(rank): \(name)")
            }
        }
    }

    /// What prompt prefixes charge (`Gemma4TensorParallelRequestBudget`): a
    /// request its own capture at its deepest boundary (its own full rows and
    /// one window of every sliding layer), in its reservation and, at the
    /// profile's longest prompt, in the LOAD quote; a rank nothing for its
    /// memory tier, whose budget is half the room the load measures
    /// (`QwenStagePrefixCache.budget(roomBytes:)`), never more than that room;
    /// nothing when the load keeps no prefixes.
    @Test func aRequestsCaptureIsChargedAndTheTierStaysWithinItsRoom() throws {
        let bound: (Int) throws -> Int = { $0 + 16_384 }
        let on = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512, promptTokens: 32_768,
            allocationBound: bound)
        let off = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 65_536, chunkTokens: 512, promptTokens: 32_768,
            keepsPrefixes: false, allocationBound: bound)
        let capture = 10 * (32_768 * 512 * 2 + 16_384) + 50 * (1_024 * 4 * 256 * 2 + 16_384)
        #expect(on.prefixCaptureBytes == capture && off.prefixCaptureBytes == 0)
        #expect(on.requestBytes == off.requestBytes + capture && on.rankBytes == off.rankBytes)
        #expect(on.allowance.reservedBytes == on.requestBytes + on.rankBytes)
        #expect(on.allowance.reservedBytes == off.allowance.reservedBytes + capture)
        // A short request is charged its own prompt's capture: its own rows and a short window.
        let short = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 8_320, chunkTokens: 512, promptTokens: 100,
            allocationBound: bound)
        #expect(short.prefixCaptureBytes == 10 * (100 * 512 * 2 + 16_384) + 50 * (100 * 4 * 256 * 2 + 16_384))
        // The tier's budget from the measured room: half of it in 256 MiB steps, at most the ceiling.
        let mib = 1 << 20
        for room in [0, 1, 511 * mib, 512 * mib, 1_000 * mib, 3 << 30, 1 << 40] {
            let tier = QwenStagePrefixCache.budget(roomBytes: room)
            #expect(tier <= room / 2 && tier <= QwenStagePrefixCache.maximumBudgetBytes && tier % (256 * mib) == 0, "room \(room)")
        }
        #expect(QwenStagePrefixCache.budget(roomBytes: 511 * mib) == 0 && QwenStagePrefixCache.budget(roomBytes: 1_000 * mib) == 256 * mib)
    }

    // MARK: - SSD tier

    /// A root the tier makes itself (as on a Mac whose owner never kept one).
    private static func root(create: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-tp-prefix-ssd-\(UUID().uuidString)",
            isDirectory: true)
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    private static func configuration(_ root: URL, key: UInt8 = 0x5a,
                                      _ change: (inout QwenStagePrefixDiskConfiguration) -> Void = { _ in })
        -> QwenStagePrefixDiskConfiguration {
        var value = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: key, count: 32)))
        value.minimumTokens = 1; value.minimumFreeBytes = 1
        change(&value)
        return value
    }

    private static func tier(_ root: URL, rank: Int, key: UInt8 = 0x5a,
                             _ change: (inout QwenStagePrefixDiskConfiguration) -> Void = { _ in }) throws -> QwenStagePrefixDiskTier {
        try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root, key: key, change),
            planScope: "gemma4-tp-prefix-tests-plan", rank: rank))
    }

    private static func records(_ root: URL, rank: Int) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "dbpx" && $0.deletingLastPathComponent().lastPathComponent == "rank\(rank)"
        }
    }

    private static func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0o777
    }

    /// Each rank writes its own heads' state at the deepest boundary to its
    /// encrypted SSD tier behind serving, in owner-only directories and
    /// files that hold none of the state's bytes in the clear. After both
    /// tiers reopen with empty memory (a restarted pair), the vote offers the
    /// records (3 a rank), both ranks read and restore them, the confirmation
    /// passes, and the request equals its cold prefill bit for bit; the state
    /// read is resident afterwards, so the next repeat restores from memory.
    @Test func ssdRecordsRestoreBitwiseAfterTheTiersReopenEncryptedAndOwnerOnly() throws {
        let directory = try Self.synthetic()
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [String: Bool] in
            var checks: [String: Bool] = [:]
            let first = try Rank(models.value[rank], disk: try Self.tier(root, rank: rank))
            let request = try first.request(Self.prompt)
            let cold = try first.serve(request)
            let disk = try #require(first.prefix.disk)
            checks["drained"] = disk.drain(timeoutSeconds: 60)
            checks["persisted"] = disk.stats.persisted == 1 && disk.recordCount == 1
            let files = Self.records(root, rank: rank)
            let rankDirectory = try #require(files.first).deletingLastPathComponent()
            checks["owner-only"] = files.count == 1 && files.allSatisfy { Self.mode($0) == 0o600 }
                && [root, rankDirectory.deletingLastPathComponent(), rankDirectory].allSatisfy { Self.mode($0) == 0o700 }
            // No 64-byte run of the kept rows appears in the record.
            let scope = try #require(first.prefix.scopes(request)).resident
            let kept = try #require(first.prefix.cache.state(scope: scope, tokens: Self.prompt, frontier: 32))
            let plain = kept.attention.values.map { $0.keys.asData(access: .copy).data }
                + kept.recurrent.values.map { $0.conv.asData(access: .copy).data }
            let sealed = try Data(contentsOf: files[0])
            checks["encrypted"] = !plain.isEmpty && plain.allSatisfy { data in
                Swift.stride(from: 0, to: data.count - 64, by: 64).allSatisfy { sealed.range(of: data[$0 ..< $0 + 64]) == nil }
            }
            disk.close(timeoutSeconds: 5)
            checks["closed"] = disk.stats.closeDrained
            // A restarted pair: empty memory, the same root and key.
            let second = try Rank(models.value[rank], disk: try Self.tier(root, rank: rank))
            let restored = try second.serve(request)
            checks["restored"] = restored.reused == 32 && Self.same(restored.generation, cold.generation)
            checks["read"] = try #require(second.prefix.disk).stats.restores == 1
            let again = try second.serve(request)
            checks["memory"] = again.reused == 32 && Self.same(again.generation, cold.generation)
                && second.prefix.disk!.stats.restores == 1
            second.prefix.disk?.close(timeoutSeconds: 5)
            return checks
        }
        for (rank, checks) in results.enumerated() {
            for name in ["drained", "persisted", "owner-only", "encrypted", "closed", "restored", "read", "memory"] {
                #expect(checks[name] == true, "rank \(rank): \(name)")
            }
        }
    }

    /// A record a rank cannot use is refused on both ranks, never assumed:
    /// a record past its TTL is not offered (the vote misses); a record
    /// corrupted on one rank fails to authenticate there and is deleted,
    /// and the confirmation makes both ranks prefill from zero (the other
    /// rank keeps what it read, resident); a rank whose key changed deletes
    /// what it cannot read and offers nothing. Every case equals the cold
    /// request bit for bit.
    @Test func staleCorruptedAndForeignRecordsAreRefusedOnBothRanks() throws {
        let directory = try Self.synthetic()
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [String: (reused: Int, same: Bool)] in
            var outcomes: [String: (reused: Int, same: Bool)] = [:]
            let writer = try Rank(models.value[rank], disk: try Self.tier(root, rank: rank))
            let request = try writer.request(Self.prompt)
            let cold = try writer.serve(request)
            writer.prefix.disk?.close(timeoutSeconds: 30)
            func reopen(key: UInt8 = 0x5a, now: TimeInterval? = nil) throws -> Rank {
                let tier = try Self.tier(root, rank: rank, key: key)
                if let now { tier.now = { now } }
                return try Rank(models.value[rank], disk: tier)
            }
            let stale = try reopen(now: Date().timeIntervalSince1970 + 2 * Double(QwenStagePrefixDiskConfiguration.maximumTTLSeconds))
            let expired = try stale.serve(request)
            outcomes["stale"] = (expired.reused, Self.same(expired.generation, cold.generation))
            stale.prefix.disk?.close(timeoutSeconds: 5)
            if rank == 1, let file = Self.records(root, rank: 1).first {
                // The last unit's sealed bytes: the header still opens, the rows do not.
                var bytes = try Data(contentsOf: file)
                for index in max(0, bytes.count - 64) ..< bytes.count { bytes[index] ^= 0xff }
                try bytes.write(to: file)
            }
            let corrupted = try reopen()
            let declined = try corrupted.serve(request)
            outcomes["corrupted"] = (declined.reused, Self.same(declined.generation, cold.generation))
            let stats = try #require(corrupted.prefix.disk).stats
            // Rank 1 refused its record (unreadable, deleted); rank 0 read its own and let it go.
            outcomes["refused"] = (rank == 1 ? stats.failedRestores + stats.sweptFiles : stats.restores, true)
            corrupted.prefix.disk?.close(timeoutSeconds: 5)
            let foreign = try reopen(key: rank == 0 ? 0x5a : 0x11)
            let unread = try foreign.serve(request)
            outcomes["foreign"] = (unread.reused, Self.same(unread.generation, cold.generation))
            foreign.prefix.disk?.close(timeoutSeconds: 5)
            return outcomes
        }
        for (rank, outcomes) in results.enumerated() {
            for name in ["stale", "corrupted", "foreign"] {
                #expect(outcomes[name]?.reused == 0 && outcomes[name]?.same == true, "rank \(rank): \(name)")
            }
        }
        #expect(results[0]["refused"]?.reused == 1 && (results[1]["refused"]?.reused ?? 0) >= 1,
                "the corrupted record is refused and deleted on its rank; the other rank read its own")
    }

    /// The SSD tier keeps the cluster tier's rules for Gemma tensor parallel
    /// as for every family: no directory or no key is no tier (nothing is
    /// ever written unencrypted); a root that cannot be made private is no
    /// tier; writes stop at the daily write cap and below the free-space
    /// floor, dropped rather than waited for; and closing finishes what was
    /// queued within its bound.
    @Test func theSSDTierKeepsTheCacheRules() throws {
        let directory = try Self.synthetic()
        let root = try Self.root(create: true)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x5a, count: 32)
        #expect(!QwenStagePrefixDiskConfiguration.fromEnvironment([:], key: key).enabled)
        #expect(!QwenStagePrefixDiskConfiguration.fromEnvironment([QwenStagePrefixDiskConfiguration.directoryEnvironmentName: root.path],
            key: nil).enabled)
        #expect(!QwenStagePrefixDiskConfiguration.fromEnvironment([QwenStagePrefixDiskConfiguration.directoryEnvironmentName: "relative"],
            key: key).enabled)
        let file = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        #expect(QwenStagePrefixDiskTier.open(configuration: Self.configuration(file.appendingPathComponent("cache")),
            planScope: "gemma4-tp-prefix-tests-plan", rank: 0) == nil, "a root that cannot be made is no tier")
        let pair = Pair(), models = try Self.models(directory, pair)
        let results = try Pair.run(device: .gpu) { rank -> [Int] in
            let capped = try Rank(models.value[rank], disk: try Self.tier(root.appendingPathComponent("capped"), rank: rank) {
                $0.maximumWriteBytesPerDay = 1
            })
            _ = try capped.serve(try capped.request(Self.prompt))
            let cap = try #require(capped.prefix.disk)
            _ = cap.drain(timeoutSeconds: 60)
            let full = try Rank(models.value[rank], disk: try Self.tier(root.appendingPathComponent("full"), rank: rank) {
                $0.minimumFreeBytes = Int.max / 4
            })
            _ = try full.serve(try full.request(Self.prompt))
            let floor = try #require(full.prefix.disk)
            _ = floor.drain(timeoutSeconds: 60)
            cap.close(timeoutSeconds: 5); floor.close(timeoutSeconds: 5)
            return [cap.recordCount, cap.stats.droppedPersists, floor.recordCount, floor.stats.droppedPersists,
                    cap.stats.closeDrained && floor.stats.closeDrained ? 1 : 0]
        }
        for (rank, value) in results.enumerated() {
            #expect(value == [0, 1, 0, 1, 1], "rank \(rank): daily cap, free-space floor, bounded close")
        }
    }
}
