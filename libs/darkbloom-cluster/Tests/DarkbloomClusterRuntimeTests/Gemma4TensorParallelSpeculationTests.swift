import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Gemma 4 speculative rounds on synthetic checkpoints: a verify window's
/// rows against the plain decode steps of the same positions (whole model and
/// two in-process ranks), byte for byte. Never a model pass.
@Suite("Gemma 4 speculative rounds", .serialized)
struct Gemma4TensorParallelSpeculationTests {
    private typealias Pair = Gemma4TensorParallelLocalPair
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    private static func synthetic(experts: Int = 16, topK: Int = 4) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-tp-spec-\(experts)-\(topK)-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) {
            // Seed 3: a greedy run that changes token twice in its first twelve
            // (random weights settle into repeating one token).
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, seed: 3, bits: 4,
                                                                   experts: experts, topK: topK)
        }
        return directory
    }

    private static let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
    private static let chunk = 16

    private static func bytes(_ array: MLXArray) -> [UInt32] { array.asType(.float32).asArray(Float.self).map(\.bitPattern) }

    /// Greedy choices of logits rows `[n, rows]` over every rank.
    private static func choose(_ model: Gemma4TensorParallelModel, _ logits: MLXArray) -> [Int] {
        let tokens = model.selection.greedyRows(logits).tokens
        eval(tokens)
        return tokens.asArray(Int32.self).map(Int.init)
    }

    private static func session(_ model: Gemma4TensorParallelModel, outputs: Int) throws
        -> (Gemma4TensorParallelPagedSession, CBv2StageKVHost, MLXArray) {
        let host = try model.pagedHost(lanes: 1, maximumTokens: prompt.count + outputs + 8, chunkTokens: chunk)
        let session = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: prompt.count,
            outputCount: outputs + 8)
        var offset = 0
        var last: MLXArray?
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            last = try session.prefill(prompt, range: offset ..< end, check: {}) { $0 }?.logits ?? last
            offset = end
        }
        return (session, host, last!)
    }

    /// The plain path: the prompt's row, then one decode step a token.
    private static func plain(_ model: Gemma4TensorParallelModel, steps: Int) throws -> (tokens: [Int], rows: [[UInt32]]) {
        let (session, host, first) = try session(model, outputs: steps)
        var rows = [bytes(first)], tokens = [choose(model, first)[0]]
        for _ in 1 ..< steps {
            let logits = try session.decode(tokens.last!, check: {}) { $0 }.logits
            rows.append(bytes(logits)); tokens.append(choose(model, logits)[0])
        }
        try session.retire()
        #expect(host.isDrained)
        return (tokens, rows)
    }

    /// Rounds over a fixed script: each round's drafts are the plain tokens
    /// where `correct` says so and a wrong token elsewhere; it keeps what the
    /// target's choices accept, then a decode step. Returns every committed
    /// position's logits row and token, in order.
    private static func speculative(_ model: Gemma4TensorParallelModel, steps: Int, plainTokens: [Int],
                                    script: [[Bool]]) throws -> (tokens: [Int], rows: [[UInt32]]) {
        let (session, host, first) = try session(model, outputs: steps)
        var rows = [bytes(first)], tokens = [choose(model, first)[0]]
        for correct in script {
            let at = tokens.count
            let drafts = correct.enumerated().map { index, right in
                right ? plainTokens[at + index] : (plainTokens[at + index] + 1) % 512
            }
            let input = MLXArray(([tokens.last!] + drafts).map(Int32.init)).reshaped([1, drafts.count + 1])
            let built = try session.beginWindow(input)
            eval(built.roots)
            try session.confirmWindow(check: {})
            let choices = choose(model, built.output.logits)
            var accepted = 0
            while accepted < drafts.count, drafts[accepted] == choices[accepted] { accepted += 1 }
            eval(try session.settleWindow(keeping: accepted + 1))
            try session.confirmSettled(check: {})
            for row in 0 ... accepted {
                rows.append(bytes(built.output.logits[row ..< row + 1])); tokens.append(choices[row])
            }
        }
        while tokens.count < steps {
            let logits = try session.decode(tokens.last!, check: {}) { $0 }.logits
            rows.append(bytes(logits)); tokens.append(choose(model, logits)[0])
        }
        try session.retire()
        #expect(host.isDrained)
        return (Array(tokens.prefix(steps)), Array(rows.prefix(steps)))
    }

    /// All drafts accepted, all rejected, a mix, a window of one: every
    /// committed row equals the plain step's bytes.
    private static let script: [[Bool]] = [[true, true, true], [false, true], [true, false, true], [], [true, true]]

    @Test func aWindowsRowsAreThePlainStepsOnTheWholeModel() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        let steps = 16
        let reference = try Self.plain(model, steps: steps)
        let candidate = try Self.speculative(model, steps: steps, plainTokens: reference.tokens, script: Self.script)
        #expect(candidate.tokens == reference.tokens)
        for (index, (a, b)) in zip(candidate.rows, reference.rows).enumerated() {
            #expect(a == b, "position \(index) differs from the plain step")
        }
    }

    @Test func aWindowsRowsAreThePlainStepsOnBothRanks() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steps = 16
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let results = try Pair.run(device: .gpu) { rank -> (plain: ([Int], [[UInt32]]), spec: ([Int], [[UInt32]])) in
            let reference = try Self.plain(models.value[rank], steps: steps)
            let candidate = try Self.speculative(models.value[rank], steps: steps, plainTokens: reference.tokens,
                                                 script: Self.script)
            return ((reference.tokens, reference.rows), (candidate.tokens, candidate.rows))
        }
        for rank in 0 ..< 2 {
            #expect(results[rank].spec.0 == results[rank].plain.0)
            for (index, (a, b)) in zip(results[rank].spec.1, results[rank].plain.1).enumerated() {
                #expect(a == b, "rank \(rank) position \(index) differs from the plain step")
            }
        }
        #expect(results[0].plain.0 == results[1].plain.0)
    }

    // MARK: - Rounds in the request loop

    /// A random assistant with the synthetic target's geometry (its own four
    /// layers read the target's last sliding and full layers).
    static func assistant() throws -> Gemma4AssistantDraftModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-assistant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) { try Gemma4TensorParallelModel.writeSyntheticAssistant(directory: directory) }
        return try Gemma4AssistantCheckpoint.loadModel(directory: directory)
    }

    struct LoopCase: @unchecked Sendable {
        var stops: [Int] = []
        var sampling: ClusterWorkerSampling?
        var ownerStopsAt: Int?
        var rankOneStopsAfter: Int?
        /// nil: the plain loop; else rounds of this depth.
        var depth: Int?
        /// Scripted proposals: the reference tokens, wrong at every output index
        /// `i` with `i % wrongEvery == wrongEvery - 1` (0: never wrong).
        var script: (reference: [Int], wrongEvery: Int)?
        var realAssistant = false
    }

    struct LoopResult: @unchecked Sendable {
        let tokens: [Int]
        let finish: ClusterWorkerFinishReason
        let clientStopped: Bool
        let published: [Int]
        let logprobs: [ClusterWorkerTokenLogprobs?]
        let statistics: Gemma4TensorParallelRounds.Statistics?
        /// After rounds: the drafter's capture and this rank's own rows, as bytes
        /// (full keys, full values, sliding keys, sliding values).
        var capture: [[UInt8]] = []
        var own: [[UInt8]] = []
    }

    private static func loop(_ models: Box<[Gemma4TensorParallelModel]>, _ value: LoopCase,
                             assistants: Box<[Gemma4AssistantDraftModel]>? = nil, outputs: Int = 12) throws -> [LoopResult] {
        let body: @Sendable (Int) throws -> LoopResult = { rank in
            let model = models.value[rank], reduction = model.reduction
            let profile = try QwenLayerStageGenerationProfile(identifier: "synthetic-gemma4-tp", vocabularySize: 512,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 64, maximumChunkTokens: 16,
                maximumOutputTokens: 32, maximumContextTokens: 128, logitsDType: "float32")
            let request = try QwenLayerStageGenerationRequest(profile: profile,
                requestID: UUID(uuidString: "6f0e2a4c-0000-4000-8000-000000000002")!,
                promptTokenIDs: Self.prompt, chunkSize: 16, outputCount: outputs, stopTokenIDs: Set(value.stops),
                sampling: value.sampling)
            let host = try model.pagedHost(lanes: 1, maximumTokens: 128, chunkTokens: 16)
            let session = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: Self.prompt.count,
                outputCount: outputs)
            var published: [Int] = [], logprobs: [ClusterWorkerTokenLogprobs?] = [], committed = 0
            let channel = ClusterCommittedTokenChannel(publishToken: { ordinal, token, _, captured in
                published.append(token); logprobs.append(captured); committed = ordinal + 1
            }, answer: { value.ownerStopsAt.map { committed - 1 != $0 } ?? true })
            var localTokens = 0
            let choice = Gemma4TensorParallelChoice(selection: model.selection, sampler: request.sampler, rank: rank)
            let loop = Gemma4TensorParallelRequestLoop(session: session, request: request, choice: choice,
                exchange: { values in
                    guard let reduction else { return values }
                    let summed = reduction.allSum(MLXArray(values.map(Float.init)))
                    eval(summed)
                    return summed.asArray(Float.self).map { Int32($0) }
                }, localStop: {
                    localTokens += 1
                    return rank == 1 && value.rankOneStopsAfter.map { localTokens >= $0 } == true
                })
            let outcome: Gemma4TensorParallelRequestLoop.Outcome
            var statistics: Gemma4TensorParallelRounds.Statistics?
            var captured: [[UInt8]] = [], owned: [[UInt8]] = []
            if let depth = value.depth {
                let drafter = try assistants.map { $0.value[rank] } ?? Self.assistant()
                let rounds = try Gemma4TensorParallelRounds(session: session,
                    assistant: try Gemma4TensorParallelAssistant(assistant: drafter, model: model, depth: depth),
                    choice: choice)
                if let script = value.script {
                    rounds.scriptedProposals = { index, count in
                        (index ..< index + count).map { i in
                            let token = i < script.reference.count ? script.reference[i] : 0
                            let wrong = script.wrongEvery > 0 && i % script.wrongEvery == script.wrongEvery - 1
                            return wrong ? (token + 1) % 512 : token
                        }
                    }
                }
                outcome = try loop.runRounds(rounds, channel: channel, check: {})
                statistics = rounds.statistics
                if outcome.finish == .length {
                    let capture = try rounds.currentCapture()
                    let own = try #require(rounds.ownRows())
                    func bytes(_ a: MLXArray) -> [UInt8] { eval(a); return [UInt8](a.asData(access: .copy).data) }
                    captured = [capture.fullKeys, capture.fullValues, capture.slidingKeys, capture.slidingValues].map(bytes)
                    owned = [own.full.keys, own.full.values, own.sliding.keys, own.sliding.values].map(bytes)
                }
            } else {
                outcome = try loop.run(channel: channel, check: {})
            }
            try session.retire()
            #expect(host.isDrained)
            return LoopResult(tokens: outcome.tokens, finish: outcome.finish, clientStopped: outcome.clientStopped,
                published: published, logprobs: logprobs, statistics: statistics, capture: captured, own: owned)
        }
        if models.value.count == 1 { return [try Device.withDefaultDevice(.gpu) { try body(0) }] }
        return try Pair.run(device: .gpu, body)
    }

    private static func sampling(_ temperature: Float, topLogprobs: Int = 3, penalty: Float = 1) -> ClusterWorkerSampling {
        ClusterWorkerSampling(temperature: temperature, topP: 1, topK: 0, minP: 0, repetitionPenalty: penalty,
            repetitionContextSize: penalty == 1 ? 0 : 16, frequencyPenalty: 0, presencePenalty: 0, seed: 0x5eed,
            stream: 0xab, logitBias: [], topLogprobs: topLogprobs)
    }

    private static func logprobBits(_ values: [ClusterWorkerTokenLogprobs?]) -> [[UInt32]] {
        values.map { entry in
            guard let entry else { return [] }
            return [entry.logprob.bitPattern] + entry.top.flatMap { [UInt32($0.tokenID), $0.logprob.bitPattern] }
        }
    }

    /// Greedy rounds on two ranks give the plain loop's tokens, finish and
    /// logprobs (bit for bit) whatever the proposals: all right, all wrong,
    /// mixed, the random assistant's; stops end both ranks with the plain
    /// loop's tokens.
    @Test func greedyRoundsGiveThePlainLoopsTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        let plain = try Self.loop(models, LoopCase())
        let reference = plain[0].tokens
        #expect(reference.count == 12 && plain[1].tokens == reference)
        let scripts = [0, 1, 3, 2]
        for depth in [1, 3, 4] {
            for wrong in scripts {
                let rounds = try Self.loop(models, LoopCase(depth: depth, script: (reference, wrong)))
                for result in rounds {
                    #expect(result.tokens == reference && result.finish == ClusterWorkerFinishReason.length, "depth \(depth)")
                }
                #expect(rounds[0].published == reference && rounds[1].published.isEmpty)
            }
        }
        // All proposals right: depth 3 keeps four tokens a round after the first.
        let perfect = try Self.loop(models, LoopCase(depth: 3, script: (reference, 0)))
        let statistics = try #require(perfect[0].statistics)
        #expect(statistics.accepted == statistics.proposed && statistics.proposed > 0)
        #expect(statistics.rounds <= 1 + (12 - 1 + 3) / 4 + 1)
        // The random assistant: the same tokens, and each rank's drafter reads
        // every rank's heads of the two source layers: its own rows and the
        // peer's, in rank order, byte for byte (the single-Mac capture).
        let real = try Self.loop(models, LoopCase(depth: 2, realAssistant: true))
        for result in real { #expect(result.tokens == reference) }
        for rank in 0 ..< 2 {
            for part in 0 ..< 2 {
                #expect(real[rank].capture[part] == real[0].own[part] + real[1].own[part], "full part \(part)")
            }
            // Sliding rows are each rank's retained window (the drafter's slice of it).
            for part in 2 ..< 4 {
                let joined = real[0].own[part] + real[1].own[part]
                #expect(real[rank].capture[part].count == joined.count)
                #expect(real[rank].capture[part] == joined, "sliding part \(part)")
            }
        }
        // A stop token, the owner's stop and one rank's own stop.
        let stopAt = try #require(reference.indices.first { $0 >= 3 && !reference[..<$0].contains(reference[$0]) })
        let script = (reference: reference, wrongEvery: 0)
        for result in try Self.loop(models, LoopCase(stops: [reference[stopAt]], depth: 3, script: script)) {
            #expect(result.tokens == Array(reference[...stopAt]) && result.finish == ClusterWorkerFinishReason.eos,
                    "\(result.tokens) \(result.finish) against \(reference) stop at \(stopAt)")
        }
        let ownerPlain = try Self.loop(models, LoopCase(ownerStopsAt: 4))
        for result in try Self.loop(models, LoopCase(ownerStopsAt: 4, depth: 3, script: script)) {
            #expect(result.tokens == Array(reference.prefix(5)) && result.finish == ClusterWorkerFinishReason.clientStop)
        }
        #expect(ownerPlain[0].finish == ClusterWorkerFinishReason.clientStop)
        for result in try Self.loop(models, LoopCase(rankOneStopsAfter: 2, depth: 3, script: script)) {
            #expect(result.finish == ClusterWorkerFinishReason.clientStop && reference.starts(with: result.tokens) && !result.tokens.isEmpty)
        }
        // Greedy logprobs: the plain loop's, bit for bit.
        let greedyPlain = try Self.loop(models, LoopCase(sampling: Self.sampling(0)))
        let greedyRounds = try Self.loop(models, LoopCase(sampling: Self.sampling(0), depth: 3,
                                                          script: (reference, 3)))
        #expect(greedyRounds[0].tokens == reference && greedyPlain[0].tokens == reference)
        #expect(Self.logprobBits(greedyRounds[0].logprobs) == Self.logprobBits(greedyPlain[0].logprobs))
    }

    /// Sampled rounds draw the plain loop's tokens: every committed token is
    /// rank 0's keyed draw at its own output index from the same row, for a
    /// stateless request and for one whose penalty depends on its history.
    @Test func sampledRoundsDrawThePlainLoopsTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = Pair()
        let models = Box(try (0 ..< 2).map {
            try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .shard(rank: $0), reduction: pair.reduction(rank: $0))
        })
        for sampling in [Self.sampling(1.0, topLogprobs: 0), Self.sampling(0.8, topLogprobs: 0, penalty: 1.3),
                         Self.sampling(1.0, topLogprobs: 2)] {
            let plain = try Self.loop(models, LoopCase(sampling: sampling))
            let drawn = plain[0].tokens
            #expect(plain[1].tokens == drawn && drawn.count == 12)
            for wrong in [0, 3] {
                let rounds = try Self.loop(models, LoopCase(sampling: sampling, depth: 3, script: (drawn, wrong)))
                for result in rounds { #expect(result.tokens == drawn, "temperature \(sampling.temperature)") }
                if sampling.topLogprobs > 0 { #expect(rounds[0].logprobs.allSatisfy { $0?.top.count == 2 }) }
            }
        }
    }

    /// The whole model (no reduction) runs the same rounds.
    @Test func roundsOnTheWholeModelGiveItsPlainTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = Box([try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)])
        let reference = try Self.loop(models, LoopCase())[0].tokens
        for wrong in [0, 2] {
            #expect(try Self.loop(models, LoopCase(depth: 3, script: (reference, wrong)))[0].tokens == reference)
        }
        #expect(try Self.loop(models, LoopCase(depth: 2, realAssistant: true))[0].tokens == reference)
    }

    /// The tool path (`generateRounds`, what `darkbloom-cluster-tp-check gemma
    /// run --mtp-depth` runs): the plain path's tokens, with its counts.
    @Test func theToolsRoundsGiveThePlainTokens() throws {
        let directory = try Self.synthetic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
        let plain = try model.generatePaged(prompt: Self.prompt, outputCount: 10, chunk: Self.chunk)
        let rounds = try model.generateRounds(prompt: Self.prompt, outputCount: 10, chunk: Self.chunk,
                                              assistant: Gemma4AssistantCheckpoint(try Self.assistant()), depth: 3)
        #expect(rounds.generation.tokenIDs == plain.tokenIDs)
        #expect(rounds.rounds.depth == 3 && rounds.rounds.rounds >= 1 && rounds.rounds.proposedByPosition.count == 3)
    }
}
