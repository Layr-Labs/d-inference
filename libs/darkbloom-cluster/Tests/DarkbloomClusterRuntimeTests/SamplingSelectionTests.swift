import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The selecting rank's sampler: the product's own `CBv2DefaultSampler`
// keyed on (seed, stream, output index). Small synthetic logits only; no
// model, collective or second process.

private let vocabulary = 64

private func samplingProfile() throws -> QwenLayerStageGenerationProfile {
    try QwenLayerStageGenerationProfile(identifier: "qwen35-sampling-fixture", vocabularySize: vocabulary,
        hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
        maximumChunkTokens: 16, maximumOutputTokens: 32, maximumContextTokens: 256)
}

private func sampling(temperature: Float = 0.8, topP: Float = 1, topK: Int = 0, seed: UInt64 = 7,
                      stream: UInt64 = 0x8000_0000_0000_0042, repetitionPenalty: Float = 1,
                      repetitionContextSize: Int = 64, frequencyPenalty: Float = 0, presencePenalty: Float = 0,
                      bias: [ClusterWorkerSampling.LogitBias] = []) -> ClusterWorkerSampling {
    .init(temperature: temperature, topP: topP, topK: topK, minP: 0, repetitionPenalty: repetitionPenalty,
          repetitionContextSize: repetitionContextSize, frequencyPenalty: frequencyPenalty,
          presencePenalty: presencePenalty, seed: seed, stream: stream, logitBias: bias)
}

private func request(_ value: ClusterWorkerSampling?, id: UUID = UUID()) throws -> QwenLayerStageGenerationRequest {
    try QwenLayerStageGenerationRequest(profile: samplingProfile(), requestID: id, promptTokenIDs: [1, 2, 3, 4],
        chunkSize: 4, outputCount: 32, stopTokenIDs: [], sampling: value)
}

/// A deterministic, fairly flat row for step `step`: every token is drawn
/// often enough that different keys give different sequences.
private func row(_ step: Int) -> [Float] {
    (0..<vocabulary).map { Float(sin(Double($0 * 7 + step * 13)) * 1.5) }
}

private func logits(_ values: [Float]) -> MLXArray {
    MLXArray(values).reshaped([1, vocabulary]).asType(.bfloat16)
}

private func select(_ request: QwenLayerStageGenerationRequest, steps: Int) throws -> [Int] {
    try (0..<steps).map { try QwenLayerStageGenerationSelection.token(logits(row($0)), request: request, check: {}) }
}

/// The product's step path rebuilt from its parts, as `CBv2DefaultSampler`
/// composes them: one pipeline + sampler configured from the row context,
/// then process, sample, commit per step.
private func productReference(_ value: ClusterWorkerSampling, prompt: [Int], steps: Int) -> [Int] {
    let params = CBv2SamplingParams(temperature: value.temperature, topP: value.topP, topK: value.topK, minP: value.minP,
        repetitionPenalty: value.repetitionPenalty, repetitionContextSize: value.repetitionContextSize,
        frequencyPenalty: value.frequencyPenalty, presencePenalty: value.presencePenalty, seed: value.seed,
        logitBias: Dictionary(uniqueKeysWithValues: value.logitBias.map { ($0.tokenID, $0.bias) }))
    let id = CBv2RequestID(value.stream)
    let pipeline = LogitsPipelineV2(vocabSize: vocabulary)
    let sampler = SamplerV2(fallbackSeed: 999)
    let rows = [CBv2SamplerRow(id: id, params: params, promptTokens: prompt)]
    pipeline.setRows(rows); sampler.setRows(rows)
    var out: [Int] = []
    for step in 0..<steps {
        let processed = pipeline.process(logits(row(step)))
        let token = sampler.sample(from: processed.sampling)
        pipeline.commit(sampledTokens: token); sampler.commit()
        eval(token)
        out.append(Int(token.reshaped([-1]).asType(.int32).item(Int32.self)))
    }
    return out
}

@Suite("Sampling on the selecting rank (synthetic logits)")
struct SamplingSelectionTests {
    @Test func greedyRequestsKeepTheirFingerprintAndSamplingIsAgreed() throws {
        let id = UUID()
        let greedy = try request(nil, id: id)
        let plain = try QwenLayerStageGenerationRequest(profile: samplingProfile(), requestID: id,
            promptTokenIDs: [1, 2, 3, 4], chunkSize: 4, outputCount: 32, stopTokenIDs: [])
        #expect(greedy.fingerprint == plain.fingerprint && greedy.sampler == nil)
        let sampled = try request(sampling(), id: id)
        #expect(sampled.fingerprint != greedy.fingerprint)
        #expect(try request(sampling(), id: id).fingerprint == sampled.fingerprint)
        #expect(try request(sampling(seed: 8), id: id).fingerprint != sampled.fingerprint)
        #expect(try request(sampling(stream: 43), id: id).fingerprint != sampled.fingerprint)
        // A no-op sampling is never built; tokens outside the profile are refused.
        #expect(throws: ProbeError.self) { _ = try request(sampling(temperature: 0)) }
        #expect(throws: ProbeError.self) { _ = try request(sampling(bias: [.init(tokenID: vocabulary, bias: 1)])) }
        #expect(throws: ProbeError.self) { _ = try request(sampling(topK: vocabulary + 1)) }
    }

    @Test func seededDrawsAreTheProductsAndReproducible() throws {
        for value in [sampling(), sampling(temperature: 1.3, topP: 0.9, topK: 20),
                      sampling(temperature: 0.6, repetitionPenalty: 1.3, frequencyPenalty: 0.4, presencePenalty: 0.2)] {
            let first = try select(request(value), steps: 24)
            let second = try select(request(value), steps: 24)
            #expect(first == second)
            #expect(first == productReference(value, prompt: [1, 2, 3, 4], steps: 24))
        }
        let a = try select(request(sampling(seed: 1)), steps: 24)
        let b = try select(request(sampling(seed: 2)), steps: 24)
        let c = try select(request(sampling(seed: 1, stream: 0x8000_0000_0000_0043)), steps: 24)
        #expect(a != b && a != c)
        // Not an argmax: a flat row at temperature 0.8 does not repeat the greedy pick.
        let greedy = try select(request(nil), steps: 24)
        #expect(a != greedy)
    }

    /// A request asking for logprobs is drawn by the product's sampler (also
    /// greedy), which gathers its token's raw log-softmax and the top
    /// alternatives with the draw; the token is the plain argmax, and the
    /// values are the raw distribution's (no transform applied).
    @Test func logprobsAreTheRawDistributionsAndTravelWithTheToken() throws {
        let asks = ClusterWorkerSampling(temperature: 0, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 7,
            stream: 0x8000_0000_0000_0042, logitBias: [], topLogprobs: 3)
        let greedy = try select(request(nil), steps: 4)
        let value = try request(asks)
        let sampler = try #require(value.sampler)
        #expect(!sampler.admitsSpeculativeVerification)
        for step in 0..<4 {
            let raw = row(step)
            let drawn = sampler.sample(logits(raw))
            eval(drawn)
            let token = Int(drawn.reshaped([-1]).asType(.int32).item(Int32.self))
            let logprobs = try #require(sampler.takePendingLogprobs())
            #expect(sampler.takePendingLogprobs() == nil)
            sampler.commit(token)
            #expect(token == greedy[step])
            // Reference: log-softmax of the bf16 row the rank saw, in double.
            let seen = MLXArray(raw).asType(.bfloat16).asType(.float32).asArray(Float.self).map(Double.init)
            let peak = seen.max()!, total = seen.reduce(0) { $0 + exp($1 - peak) }
            let reference = seen.map { $0 - peak - log(total) }
            #expect(abs(Double(logprobs.logprob) - reference[token]) < 1e-3)
            #expect(logprobs.top.count == 3 && logprobs.top[0].tokenID == token)
            #expect(zip(logprobs.top, logprobs.top.dropFirst()).allSatisfy { $0.logprob >= $1.logprob })
            // The three largest values (ties in bf16 may order their tokens either way).
            let expected = reference.sorted(by: >).prefix(3)
            #expect(zip(logprobs.top, expected).allSatisfy { abs(Double($0.logprob) - $1) < 1e-3 })
            #expect(logprobs.top.allSatisfy { abs(Double($0.logprob) - reference[$0.tokenID]) < 1e-3 })
        }
        // A request without logprobs gathers none.
        let plain = try request(sampling())
        _ = plain.sampler?.sample(logits(row(0)))
        #expect(plain.sampler?.takePendingLogprobs() == nil)
    }

    /// A logprob request in an MTP round (owner: MTP always on): each
    /// committed token's logprobs come from the verify window row whose draw
    /// it is, gathered as the one-token step gathers its row; the round's
    /// draws are the step path's (logprob requests verify by replay). Run on
    /// the CPU device: no GPU needed.
    @Test func roundLogprobsAreEachWindowRowsStepGather() throws {
        try Device.withDefaultDevice(.cpu) {
            let asks = ClusterWorkerSampling(temperature: 0.7, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 7,
                stream: 0x8000_0000_0000_0042, logitBias: [], topLogprobs: 3)
            let speculating = try request(asks), stepping = try request(asks)
            let round = try #require(speculating.sampler), step = try #require(stepping.sampler)
            let rows = (3..<6).map { row($0) }
            var expected: [(token: Int, logprobs: ClusterWorkerTokenLogprobs)] = []
            for values in rows {
                let drawn = step.sample(logits(values))
                eval(drawn)
                let token = Int(drawn.reshaped([-1]).asType(.int32).item(Int32.self))
                expected.append((token, try #require(step.takePendingLogprobs())))
                step.commit(token)
            }
            // Proposals from the same rows are the step path's draws: all kept.
            let proposals = (0..<2).map {
                round.propose(MLXArray(rows[$0]).reshaped([1, 1, vocabulary]).asType(.bfloat16), step: $0)
            }
            let window = MLXArray(rows.flatMap { $0 }).reshaped([1, 3, vocabulary]).asType(.bfloat16)
            let draws = round.verifyRound(window)
            eval([draws] + proposals)
            let tokens = draws.asArray(Int32.self).map(Int.init)
            #expect(tokens == expected.map(\.token))
            let gathered = round.takeRoundLogprobs(tokens: tokens)
            #expect(gathered.count == 3)
            for (value, reference) in zip(gathered, expected.map(\.logprobs)) {
                #expect(abs(value.logprob - reference.logprob) <= 1e-5)
                #expect(value.top.map(\.tokenID) == reference.top.map(\.tokenID))
                #expect(zip(value.top, reference.top).allSatisfy { abs($0.logprob - $1.logprob) <= 1e-5 })
            }
            // Once per round; a round that kept fewer tokens reads only their rows.
            #expect(round.takeRoundLogprobs(tokens: tokens).isEmpty)
            round.commitRound(tokens)
            _ = round.propose(MLXArray(row(6)).reshaped([1, 1, vocabulary]).asType(.bfloat16), step: 0)
            let next = round.verifyRound(MLXArray(row(6) + row(7)).reshaped([1, 2, vocabulary]).asType(.bfloat16))
            eval(next)
            let first = Int(next.asArray(Int32.self)[0])
            #expect(round.takeRoundLogprobs(tokens: [first]).map(\.top.count) == [3])
            // A request without logprobs keeps no window.
            let plain = try #require(try request(sampling()).sampler)
            _ = plain.verifyRound(window)
            #expect(plain.takeRoundLogprobs(tokens: tokens).isEmpty)
        }
    }

    @Test func greedyWithLogitBiasStillAppliesTheBias() throws {
        let biased = try request(sampling(temperature: 0, bias: [.init(tokenID: 5, bias: 100)]))
        #expect(try select(biased, steps: 8) == Array(repeating: 5, count: 8))
        let banned = try request(sampling(temperature: 0, bias: [.init(tokenID: try select(request(nil), steps: 1)[0], bias: -100)]))
        #expect(try select(banned, steps: 1) != (try select(request(nil), steps: 1)))
        // top_k 1 at any temperature is the argmax.
        #expect(try select(request(sampling(temperature: 2, topK: 1)), steps: 12) == (try select(request(nil), steps: 12)))
    }

    /// Target-prefix verification: column j of a window is the draw the
    /// ordinary step path makes at output index base + j for the same row, so
    /// a speculative round commits exactly the plain path's tokens.
    @Test func verifyColumnsAreTheOrdinaryDrawsAtTheirOutputIndex() throws {
        let value = sampling(temperature: 0.9, topP: 0.95)
        let sequential = try request(value)
        let prefix = try select(sequential, steps: 3)
        let plain = try (3..<8).map { try QwenLayerStageGenerationSelection.token(logits(row($0)), request: sequential, check: {}) }
        let speculative = try request(value)
        #expect(try select(speculative, steps: 3) == prefix)
        let window = MLXArray((3..<8).flatMap { row($0) }).reshaped([1, 5, vocabulary]).asType(.bfloat16)
        let verify = try #require(speculative.sampler?.verify(window))
        eval(verify)
        let columns = verify.reshaped([-1]).asType(.int32).asArray(Int32.self).map(Int.init)
        #expect(columns == plain)
        speculative.sampler?.commitRound(columns)
        // After a round the step path continues at the next output index.
        let next = try QwenLayerStageGenerationSelection.token(logits(row(8)), request: speculative, check: {})
        let nextPlain = try QwenLayerStageGenerationSelection.token(logits(row(8)), request: sequential, check: {})
        #expect(next == nextPlain && speculative.sampler?.nextOutputIndex == 9)
        // History-dependent transforms are never verified speculatively.
        let penalised = try request(sampling(repetitionPenalty: 1.2))
        #expect(penalised.sampler?.verify(window) == nil)
        #expect(try request(sampling(temperature: 0, bias: [.init(tokenID: 1, bias: 1)])).sampler?.admitsSpeculativeVerification == false)
    }

    /// Coupled proposals: a draft row raced with the target's temperature and
    /// the keyed noise of the output index it proposes for. From the target's
    /// own distribution it is the target's draw (with top-k / top-p, unless
    /// the race's winner is filtered out: then the row's mode); the argmax is not.
    @Test func coupledDraftsOfTheTargetsDistributionAreItsDraws() throws {
        let window = MLXArray((3..<8).flatMap { row($0) }).reshaped([1, 5, vocabulary]).asType(.bfloat16)
        func ints(_ a: MLXArray) -> [Int32] { a.reshaped([-1]).asType(.int32).asArray(Int32.self) }
        func proposals(_ sampler: QwenStageTokenSampler, offset: (Int) -> Int = { $0 }) throws -> [Int32] {
            let drafts = try (0..<5).map {
                try #require(sampler.draft(window[0..., $0 ..< ($0 + 1)], offset: offset($0)))
            }
            eval(drafts)
            return drafts.flatMap(ints)
        }
        let unfiltered = try request(sampling(temperature: 1))
        _ = try select(unfiltered, steps: 3)
        let sampler = try #require(unfiltered.sampler)
        let columns = ints(try #require(sampler.verify(window)))
        #expect(try proposals(sampler) == columns)
        // Two rows at one index share its noise; the same rows at the next index do not.
        let pair = try #require(sampler.draft(concatenated([window[0..., ..<1], window[0..., ..<1]], axis: 0), offset: 0))
        #expect(ints(pair) == [columns[0], columns[0]])
        #expect(try proposals(sampler, offset: { $0 + 1 }) != columns)
        // The argmax is the draw only where the draw happens to be the mode.
        let modes = ints(argMax(window[0].asType(.float32), axis: -1))
        #expect(modes != columns)
        // Drafting reads the history only through the output index: the next
        // round's base moves with the committed tokens.
        sampler.commitRound(Array(columns.prefix(2)).map(Int.init))
        let moved = try #require(sampler.draft(window[0..., 2 ..< 3], offset: 0))
        #expect(ints(moved) == [columns[2]])

        // Filtered: the draw or, where the race's winner is filtered out, the mode.
        let filtered = try request(sampling(temperature: 1, topP: 0.8, topK: 12))
        _ = try select(filtered, steps: 3)
        let filteredSampler = try #require(filtered.sampler)
        let draws = ints(try #require(filteredSampler.verify(window)))
        let filteredProposals = try proposals(filteredSampler)
        #expect(zip(filteredProposals, zip(draws, modes)).allSatisfy { $0 == $1.0 || $0 == $1.1 })
        #expect(zip(filteredProposals, draws).contains { $0 == $1 })
        // top_k 1 draws the mode, and so proposes it.
        let mode = try request(sampling(temperature: 1, topK: 1))
        _ = try select(mode, steps: 3)
        #expect(try proposals(try #require(mode.sampler)) == modes)
        // History-dependent transforms never draft here (they replay: `propose`).
        #expect(try request(sampling(repetitionPenalty: 1.2)).sampler?.draft(window[0..., ..<1], offset: 0) == nil)
    }

    /// The committed sequence of speculative rounds with sampled verification
    /// is the one-token sampled path's, whatever the proposals: argmax or
    /// coupled, from the target's own distribution or a skewed draft, with
    /// stateless transforms or replayed penalties and bias. Only how many
    /// proposals are kept differs.
    @Test(arguments: [1, 2, 3])
    func speculativeRoundsCommitThePlainDrawsWithAnyProposals(depth: Int) throws {
        // With each, whether a coupled draft from the target's own distribution
        // is always kept: replayed requests draw proposals exactly as their
        // target does; stateless ones race over the whole row (`draft`).
        let values: [(ClusterWorkerSampling, alwaysKept: Bool)] = [
            (sampling(temperature: 1), true),
            (sampling(temperature: 1, topP: 0.95), false),
            (sampling(temperature: 0.9, topP: 0.95, repetitionPenalty: 1.3, frequencyPenalty: 0.4, presencePenalty: 0.2), true),
            // A repetition window shorter than a round: proposals evict tokens from it.
            (sampling(temperature: 1, repetitionPenalty: 2, repetitionContextSize: 2), true),
            (sampling(temperature: 1, topK: 12, bias: [.init(tokenID: 5, bias: 2), .init(tokenID: 9, bias: -3)]), true),
            (sampling(temperature: 0, repetitionPenalty: 1.5, bias: [.init(tokenID: 5, bias: 1)]), true),
        ]
        let steps = 28
        for (index, (value, alwaysKept)) in values.enumerated() {
            let plain = try plainDecode(value, steps: steps)
            var kept: [String: (proposed: Int, accepted: Int)] = [:]
            for skew: Float in [0, 0.8] {
                for coupled in [false, true] {
                    let run = try speculativeDecode(value, steps: steps, depth: depth, skew: skew, coupled: coupled)
                    #expect(run.tokens == plain, "sampling \(index) skew \(skew) coupled \(coupled)")
                    kept["\(skew)-\(coupled)"] = (run.proposed, run.accepted)
                }
            }
            // The target's own distribution, coupled: every proposal is its draw
            // (stateless with filters: unless the race's winner was filtered out).
            let exact = try #require(kept["0.0-true"])
            #expect(exact.proposed > 0 && (exact.accepted == exact.proposed || !alwaysKept), "sampling \(index)")
            guard value.isStochastic else { continue }
            // Its argmax is kept only when the draw is the mode.
            let greedy = try #require(kept["0.0-false"])
            #expect(greedy.accepted < greedy.proposed, "sampling \(index)")
            #expect(greedy.accepted * exact.proposed < exact.accepted * greedy.proposed, "sampling \(index)")
        }
    }

    /// History-dependent transforms are replayed, not refused: a round over a
    /// penalised request proposes and verifies at its own output indexes.
    @Test func penalisedRoundsReplayTheStepPathOverTheProposals() throws {
        let value = sampling(temperature: 0.9, repetitionPenalty: 1.3, frequencyPenalty: 0.4)
        let sampled = try request(value)
        let mine = try select(sampled, steps: 3)
        let sampler = try #require(sampled.sampler)
        #expect(!sampler.admitsSpeculativeVerification && sampler.verify(logits(row(3)).reshaped([1, 1, vocabulary])) == nil)
        // Proposals equal to the plain path's next draws are all kept.
        let reference = try request(value)
        let prefix = try select(reference, steps: 3)
        let next = try (3..<6).map { try QwenLayerStageGenerationSelection.token(logits(row($0)), request: reference, check: {}) }
        let proposals = (3..<5).enumerated().map { step, index in
            sampler.propose(MLXArray(row(index)).reshaped([1, 1, vocabulary]).asType(.bfloat16), step: step)
        }
        let window = MLXArray((3..<6).flatMap { row($0) }).reshaped([1, 3, vocabulary]).asType(.bfloat16)
        let draws = sampler.verifyRound(window)
        eval([draws] + proposals)
        #expect(mine == prefix)
        #expect(proposals.map { Int($0.item(Int32.self)) } == Array(next.prefix(2)))
        #expect(draws.shape == [1, 3] && draws.asArray(Int32.self).map(Int.init) == next)
    }

    /// Lanes verified in one batched forward (`GLM5NextTensorParallelSpeculation
    /// .rounds`): every lane proposes first, then every lane draws, then each
    /// commits. Each lane's sampler keeps its own round, so each commits its
    /// own one-token sampled sequence, coupled or replayed.
    @Test func batchedLanesKeepEachSamplersOwnRound() throws {
        let values = [
            sampling(temperature: 1, topP: 0.95),
            sampling(temperature: 0.9, stream: 0x8000_0000_0000_0043, repetitionPenalty: 1.3, frequencyPenalty: 0.4),
            sampling(temperature: 1, topK: 12, stream: 0x8000_0000_0000_0044, bias: [.init(tokenID: 5, bias: 2)]),
        ]
        let steps = 24, depth = 2
        let plain = try values.map { try plainDecode($0, steps: steps) }
        let requests = try values.map { try request($0) }
        let samplers = try requests.map { try #require($0.sampler) }
        var tokens = try requests.map {
            [try QwenLayerStageGenerationSelection.token(logits(prefixRow(syntheticPrompt)), request: $0, check: {})]
        }
        while tokens.contains(where: { $0.count < steps }) {
            let lanes = tokens.indices.filter { tokens[$0].count < steps }
            let windows = lanes.map { min(depth, steps - tokens[$0].count - 1) }
            var drafts: [[Int]] = []
            for (lane, window) in zip(lanes, windows) {
                var proposed: [Int] = []
                for step in 0..<max(1, window) {
                    let row = MLXArray(prefixRow(syntheticPrompt + tokens[lane] + proposed, skew: 0.5))
                        .reshaped([1, 1, vocabulary]).asType(.bfloat16)
                    proposed.append(Int(samplers[lane].propose(row, step: step).item(Int32.self)))
                }
                drafts.append(Array(proposed.prefix(window)))
            }
            let draws = zip(lanes, zip(windows, drafts)).map { lane, item in
                let columns = (0...item.0).flatMap { prefixRow(syntheticPrompt + tokens[lane] + item.1.prefix($0)) }
                return samplers[lane].verifyRound(
                    MLXArray(columns).reshaped([1, item.0 + 1, vocabulary]).asType(.bfloat16))
            }
            for (index, lane) in lanes.enumerated() {
                let slot = draws[index].reshaped([-1]).asType(.float32).asArray(Float.self)
                    + drafts[index].map(Float.init) + [0]
                let decided = try GLM5NextTensorParallelSpeculation.decide(slot, ranks: 1, window: windows[index],
                    sampled: true)
                samplers[lane].commitRound(decided.tokens)
                tokens[lane] += decided.tokens
            }
        }
        for lane in values.indices { #expect(Array(tokens[lane].prefix(steps)) == plain[lane], "lane \(lane)") }
    }

    @Test func draftProbeScoresTheArgmaxAndEachCoupledSharpness() throws {
        let sampled = try request(sampling(temperature: 1, topP: 0.95))
        let sampler = try #require(sampled.sampler)
        let probe = GLM5NextTensorParallelResidentRuntime.draftProbe(sampler)
        #expect(probe.names == ["argmax", "c1.0", "c1.5", "c2.0", "c3.0"])
        let draft = MLXArray(row(4)).reshaped([1, 1, vocabulary]).asType(.bfloat16)
        let scored = probe.rules(draft)
        let greedy = argMax(draft[0..., -1, 0...].asType(.float32), axis: -1)
        let coupled = try #require(sampler.draft(draft, offset: 0))
        // A very sharp draft is its argmax.
        let sharpest = try #require(sampler.draft(draft.asType(.float32) * 1000, offset: 0))
        eval(scored, greedy, coupled, sharpest)
        let values = scored.asArray(Int32.self)
        #expect(values.count == 5 && scored.dtype == .int32)
        #expect(values[0] == greedy.asType(.int32).item(Int32.self))
        #expect(values[1] == coupled.reshaped([-1]).asType(.int32).item(Int32.self))
        #expect(sharpest.reshaped([-1]).asType(.int32).item(Int32.self) == values[0])
    }
}

/// A synthetic target whose next-token logits are a function of the whole
/// prefix, as a model's are; `skew` perturbs a draft head's copy of them.
private func prefixRow(_ prefix: [Int], skew: Float = 0) -> [Float] {
    let key = prefix.reduce(17) { ($0 &* 31 &+ $1) % 1_000_003 }
    return (0..<vocabulary).map { token in
        Float(sin(Double(key % 997) * 0.37 + Double(token) * 1.3)) * 2
            + skew * Float(cos(Double(key % 991) * 0.71 + Double(token) * 2.9))
    }
}

private let syntheticPrompt = [1, 2, 3, 4]

/// The one-token sampled path: every token drawn at its own output index.
private func plainDecode(_ value: ClusterWorkerSampling, steps: Int) throws -> [Int] {
    let sampled = try request(value)
    var tokens: [Int] = []
    for _ in 0..<steps {
        tokens.append(try QwenLayerStageGenerationSelection.token(logits(prefixRow(syntheticPrompt + tokens)),
                                                                  request: sampled, check: {}))
    }
    return tokens
}

/// The tensor-parallel round loop on one rank, with synthetic logits: the
/// first token as a plain step, then rounds of `depth` proposals (argmax or
/// coupled), verified by the target's keyed draws
/// (`QwenStageTokenSampler.propose`, `verifyRound`) and decided by
/// `GLM5NextTensorParallelSpeculation.decide`.
private func speculativeDecode(_ value: ClusterWorkerSampling, steps: Int, depth: Int, skew: Float,
                               coupled: Bool) throws -> (tokens: [Int], proposed: Int, accepted: Int) {
    let sampled = try request(value)
    guard let sampler = sampled.sampler else { throw ProbeError("synthetic request has no sampler") }
    var tokens = [try QwenLayerStageGenerationSelection.token(logits(prefixRow(syntheticPrompt)),
                                                              request: sampled, check: {})]
    var proposed = 0, accepted = 0
    while tokens.count < steps {
        let window = min(depth, steps - tokens.count - 1)
        var drafts: [Int] = []
        for step in 0..<max(1, window) {
            let row = MLXArray(prefixRow(syntheticPrompt + tokens + drafts, skew: skew))
                .reshaped([1, 1, vocabulary]).asType(.bfloat16)
            let proposal = sampler.propose(row, step: step, sharpness: coupled ? 1 : .infinity)
            drafts.append(Int(proposal.item(Int32.self)))
        }
        drafts = Array(drafts.prefix(window))
        let columns = (0...window).flatMap { prefixRow(syntheticPrompt + tokens + drafts.prefix($0)) }
        let draws = sampler.verifyRound(MLXArray(columns).reshaped([1, window + 1, vocabulary]).asType(.bfloat16))
        let slot = draws.reshaped([-1]).asType(.float32).asArray(Float.self) + drafts.map(Float.init) + [0]
        let decided = try GLM5NextTensorParallelSpeculation.decide(slot, ranks: 1, window: window, sampled: true)
        sampler.commitRound(decided.tokens)
        tokens += decided.tokens
        proposed += window; accepted += decided.tokens.count - 1
    }
    return (tokens, proposed, accepted)
}
