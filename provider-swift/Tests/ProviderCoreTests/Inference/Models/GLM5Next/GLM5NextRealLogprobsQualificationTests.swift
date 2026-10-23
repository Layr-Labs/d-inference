import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Real-checkpoint logprobs qualification of the production GLM serving path:
/// the managed load, production bundle and `EngineV2Bridge` relay channel used
/// by coordinator requests (the standalone `--local` HTTP server never emits
/// logprobs). Offline and expensive: loads the full GLM artifact. Never run on
/// a live provider. Needs the `GLM5NextRealModelHarness` environment plus
/// `DARKBLOOM_TEST_GLM5_REAL_LOGPROBS=1`.
///
/// A logprob row never drafts, so it decodes one-token target steps. A plain
/// row verifies adaptive rectangular MTP windows, which round differently, so
/// its greedy stream may leave the target path at a near-tie. Each row is
/// therefore checked against a teacher-forced reference along its own tokens.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_LOGPROBS"] == "1"))
struct GLM5NextRealLogprobsQualificationTests {
    static let promptText = "Write a long, detailed essay on the history of the Roman Empire."
    /// The co-batched plain row has another prompt, so a logprob gathered from
    /// the wrong row cannot match the reference by coincidence.
    static let neighborText = "Explain in detail how photosynthesis works in plants."
    static let logprobTokens = 32
    static let plainTokens = 128
    static let topLogprobs = 5
    /// Floor, in nats, of the bound between a served logprob and the
    /// teacher-forced reference. The reference runs the same weights through
    /// the dense text cache one token at a time; the server runs the paged
    /// cache and, beside other rows or verify windows, wider kernels. Both
    /// produce bf16 logits spaced 2^-7 of their leading power of two (0.0625
    /// for logits of 8-16, 0.125 for 16-32). Two kernels may round a logit to
    /// adjacent values, which moves its log-softmax by up to two spacings of
    /// the step's largest logit, so each step's bound is the larger of this
    /// floor and those two spacings (`bound(largestLogit:)`). A wrong row,
    /// wrong position, unnormalized logits or an applied temperature instead
    /// moves the alternatives out of the reference top-8 or errs by nats. The
    /// run records the observed maxima.
    static var tolerance: Double {
        ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_TOLERANCE"]
            .flatMap(Double.init) ?? 5e-2
    }

    /// Bound, in nats, on a co-batched logprob row's alternatives. Batch width
    /// alone moves GLM's non-top logits: on an M3 Ultra the dense reference
    /// run as two identical rows differs from the one-row reference by up to
    /// 0.56 nats over its top-8 (`pairedReferenceMaxDrift`), and the served
    /// batched row's alternatives differ from its solo values by up to 0.69,
    /// while chosen values stay within `bound(largestLogit:)`. The chosen value
    /// keeps the tight bound; a wrong row or position instead moves the
    /// alternatives out of the reference top-8 or the chosen value by nats.
    static var batchedAlternativeBound: Double {
        ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_BATCHED_TOLERANCE"]
            .flatMap(Double.init) ?? 1.0
    }

    static func bound(largestLogit magnitude: Float) -> Double {
        guard magnitude.isNormal else { return tolerance }
        return max(tolerance, 2 * Double(sign: .plus, exponent: Int(magnitude.exponent) - 7, significand: 1))
    }

    struct Served: Sendable {
        var text = ""
        var generated = 0
        var errors: [String] = []
        var entries: [SSETokenLogprob] = []
    }

    static func request(_ model: String, maxTokens: Int, logprobs: Bool) -> ChatCompletionRequest {
        .init(model: model, messages: [], temperature: 0, max_tokens: maxTokens,
            logprobs: logprobs ? true : nil, top_logprobs: logprobs ? topLogprobs : nil)
    }

    /// One request through the production bridge relay path.
    static func serve(_ bridge: EngineV2Bridge, prompt: [Int], request: ChatCompletionRequest,
        id: String, onFinish: (@Sendable () -> Void)? = nil) async throws -> Served {
        let channel = request.logprobs == true ? EngineV2LogprobsChannel() : nil
        let stream = try await bridge.submitTokenized(promptTokens: prompt, request: request,
            requestId: id, cacheEnabled: false, logprobsChannel: channel, firstContentDeadline: nil)
        var served = Served()
        for await event in stream {
            switch event {
            case .chunk(let text): served.text += text
            case .info(_, let count, _, _): served.generated = count
            case .error(let reason): served.errors.append(reason)
            default: break
            }
        }
        onFinish?()
        served.entries = channel?.drain() ?? []
        return served
    }

    struct ReferenceStep {
        /// Reference logprob of the token the row emitted at this step.
        let chosen: Double
        /// Reference logprob of `alternatives[step]`, another path's token.
        let alternative: Double?
        let top: [(token: String, logprob: Double)]
        let bound: Double
        var best: Double { top.first?.logprob ?? -.infinity }
    }

    /// Teacher-forced log-softmax of the managed GLM root on the same prefix:
    /// the prompt in bounded chunks, then each generated token one at a time.
    /// Step i scores the distribution that sampled `generated[i]`.
    static func reference(_ harness: GLM5NextRealModelHarness, prompt: [Int], generated: [Int],
        alternatives: [Int] = [], rows batch: Int = 1) async throws -> [ReferenceStep] {
        let container = try #require(harness.container)
        let activity = harness.budget.serviceBudget.beginUnboundedActivity()
        defer { activity.finish() }
        let rows: [(values: [Float], largest: Float)] = try await container.perform { context in
            let root = try #require(context.model as? GLM5NextModel)
            return try MLX.withError { errors in
                let cache = root.newTextCache()
                func logProbabilities(_ tokens: [Int]) throws -> (values: [Float], largest: Float) {
                    let output = try root.textTower.forward(
                        tokens: MLXArray(Array(repeating: tokens.map(Int32.init), count: batch).flatMap { $0 })
                            .reshaped([batch, tokens.count]), cache: cache)
                    let logits = output.logits[0, -1, 0...].asType(.float32)
                    let values = logits - logSumExp(logits, axis: -1, keepDims: true)
                    let largest = MLX.abs(logits).max()
                    eval(values, largest); try errors.check()
                    let row = values.asArray(Float.self); try errors.check()
                    return (row, largest.item(Float.self))
                }
                var rows: [(values: [Float], largest: Float)] = []
                var last: (values: [Float], largest: Float) = ([], 0)
                for start in stride(from: 0, to: prompt.count, by: 128) {
                    last = try logProbabilities(Array(prompt[start..<min(start + 128, prompt.count)]))
                }
                rows.append(last)
                for token in generated.dropLast() { rows.append(try logProbabilities([token])) }
                return rows
            }
        }
        var steps: [ReferenceStep] = []
        for (index, (row, token)) in zip(rows, generated).enumerated() {
            let values = row.values
            let order = values.indices.sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1] }
                .prefix(8)
            var top: [(token: String, logprob: Double)] = []
            for id in order { top.append((try await harness.decode([id]), Double(values[id]))) }
            steps.append(ReferenceStep(chosen: Double(values[token]),
                alternative: index < alternatives.count ? Double(values[alternatives[index]]) : nil,
                top: top, bound: bound(largestLogit: row.largest)))
        }
        return steps
    }

    struct Agreement {
        var failures: [String] = []
        var maxChosen = 0.0
        var maxTop = 0.0
        var maxBound = 0.0
    }

    /// Served entries against the reference along the same tokens. Near-ties
    /// may reorder within the bound; every served alternative must be a
    /// reference candidate at the same value, and each reference top-5 entry
    /// clearly above the served fifth must be served. `alternativeBound`
    /// widens the bound on alternatives, never on the chosen value.
    static func compare(_ entries: [SSETokenLogprob], _ reference: [ReferenceStep], label: String,
        alternativeBound: Double = 0) -> Agreement {
        var result = Agreement()
        for (index, (entry, step)) in zip(entries, reference).enumerated() {
            result.maxBound = max(result.maxBound, step.bound)
            let alternatives = max(step.bound, alternativeBound)
            if entry.topLogprobs.count != topLogprobs || entry.topLogprobs.first?.logprob != entry.logprob {
                result.failures.append("\(label) step \(index) is not a greedy top-\(topLogprobs) entry")
            }
            let chosen = abs(Double(entry.logprob) - step.chosen)
            result.maxChosen = max(result.maxChosen, chosen)
            if chosen > step.bound { result.failures.append("\(label) step \(index) chosen Δ=\(chosen)") }
            for (rank, alternative) in entry.topLogprobs.enumerated() {
                let match = step.top.filter { $0.token == alternative.token }
                    .map { abs($0.logprob - Double(alternative.logprob)) }.min()
                guard let match else {
                    result.failures.append("\(label) step \(index) rank \(rank) not in reference top-8")
                    continue
                }
                result.maxTop = max(result.maxTop, match)
                if match > alternatives { result.failures.append("\(label) step \(index) rank \(rank) Δ=\(match)") }
            }
            let floor = Double(entry.topLogprobs.last?.logprob ?? 0) + alternatives
            for candidate in step.top.prefix(topLogprobs) where candidate.logprob > floor
                && !entry.topLogprobs.contains(where: { $0.token == candidate.token }) {
                result.failures.append("\(label) step \(index) reference \(candidate.token.debugDescription) missing")
            }
        }
        return result
    }

    @Test func realLogprobsMatchTeacherForcedReferenceAlongTheirOwnTokens() async throws {
        try await GLM5NextRealModelHarness.withLoaded(concurrency: 2) { harness in
            let session = try #require(harness.session)
            let engine = session.rawEngine
            let bridge = try #require(harness.bundle).bridge
            let model = harness.plan.weights.catalog.id
            let prompt = try await harness.prompt(Self.promptText)
            #expect(engine.acceptsLogprobRows)

            // (1) MTP greedy without logprobs: the row must speculate.
            let mtp = try await harness.run(prompt, id: 1, output: Self.logprobTokens)
            try #require(mtp.reason == .length && mtp.tokens.count == Self.logprobTokens,
                "the prompt must not stop early: \(String(describing: mtp.reason)) \(mtp.tokens.count)")
            #expect(try #require(mtp.mtp).proposed > 0, "the baseline row must speculate")

            // (2) The logprob row on the raw engine: the target path's token ids.
            let target = try await harness.run(prompt, id: 2, output: Self.logprobTokens,
                topLogprobs: Self.topLogprobs)
            try #require(target.reason == .length && target.tokens.count == Self.logprobTokens)
            #expect(try #require(target.mtp).proposed == 0, "a logprobs row must never speculate")
            #expect(target.logprobs.map(\.token) == target.tokens)

            // (3) The same row through the relay channel runs the same
            // one-token steps, so its tokens, text and values are identical.
            var before = try #require(engine.mtpMetricsSnapshot())
            let solo = try await Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.logprobTokens, logprobs: true), id: "glm-real-logprobs")
            let soloDrafted = try #require(engine.mtpMetricsSnapshot()).draftedTokens - before.draftedTokens
            #expect(solo.errors.isEmpty, "logprobs request errors: \(solo.errors)")
            #expect(solo.generated == Self.logprobTokens && solo.entries.count == Self.logprobTokens)
            #expect(soloDrafted == 0, "a logprobs row must never speculate")
            let decoded = try await target.tokens.asyncMap { try await harness.decode([$0]) }
            #expect(solo.entries.map(\.token) == decoded, "the relay changed the target-path tokens")
            #expect(solo.text == target.text, "the relay changed the target-path text")
            #expect(solo.entries.map(\.logprob) == target.logprobs.map(\.logprob), "the relay changed the logprobs")

            // (4) Values along the served tokens. The MTP stream may leave
            // them only where the reference has a near-tie.
            let reference = try await Self.reference(harness, prompt: prompt, generated: target.tokens,
                alternatives: mtp.tokens)
            let agreement = Self.compare(solo.entries, reference, label: "solo")
            #expect(agreement.failures.isEmpty, "\(agreement.failures)")
            let mtpParting = target.tokens.indices.first { mtp.tokens[$0] != target.tokens[$0] }
            var mtpPartingGap: Double?
            if let mtpParting {
                let step = reference[mtpParting]
                let gap = abs(step.chosen - (step.alternative ?? -.infinity))
                mtpPartingGap = gap
                #expect(gap <= 2 * step.bound, "MTP left the target path at step \(mtpParting) without a near-tie: Δ=\(gap)")
            }

            // (5) A logprob row beside a plain row with another prompt.
            let neighbor = try await harness.prompt(Self.neighborText)
            before = try #require(engine.mtpMetricsSnapshot())
            let atLogprobsFinish = SnapshotBox()
            async let plain = harness.run(neighbor, id: 3, output: Self.plainTokens, suppressEOS: true,
                attributeMTP: false)
            async let logprobs = Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.logprobTokens, logprobs: true), id: "glm-real-logprobs-batched",
                onFinish: { atLogprobsFinish.set(engine.mtpMetricsSnapshot()?.draftedTokens) })
            let (batchedPlain, batchedLogprobs) = try await (plain, logprobs)
            let after = try #require(engine.mtpMetricsSnapshot()).draftedTokens
            let atFinish = try #require(atLogprobsFinish.value)
            #expect(batchedLogprobs.errors.isEmpty && batchedLogprobs.entries.count == Self.logprobTokens)
            #expect(batchedPlain.reason == .length && batchedPlain.tokens.count == Self.plainTokens)
            #expect(after > atFinish, "the plain row must speculate again after the logprobs row finishes")

            // The batched logprob row keeps the solo stream unless a near-tie
            // rounds the other way; the values match on the common prefix.
            let batchedTokens = batchedLogprobs.entries.map(\.token)
            let batchedParting = (0..<min(batchedTokens.count, decoded.count))
                .first { batchedTokens[$0] != decoded[$0] }
            let shared = Array(batchedLogprobs.entries.prefix(batchedParting ?? batchedLogprobs.entries.count))
            let batched = Self.compare(shared, reference, label: "batched",
                alternativeBound: Self.batchedAlternativeBound)
            #expect(batched.failures.isEmpty, "\(batched.failures)")
            if let batchedParting {
                let step = reference[batchedParting]
                let emitted = step.top.first { $0.token == batchedTokens[batchedParting] }
                #expect(emitted.map { step.best - $0.logprob <= 2 * step.bound } == true,
                    "the batched logprob row left the solo stream at step \(batchedParting) without a near-tie")
            }
            let batchedDrift = zip(shared, solo.entries).map { abs(Double($0.logprob - $1.logprob)) }.max() ?? 0
            // Diagnostic: the same reference run as a batch of two identical
            // rows, so only the kernels' batch width differs from the solo
            // reference.
            let paired = try await Self.reference(harness, prompt: prompt, generated: target.tokens, rows: 2)
            let pairedDrift = zip(reference, paired).flatMap { single, double in
                single.top.compactMap { entry in
                    double.top.first { $0.token == entry.token }.map { abs($0.logprob - entry.logprob) }
                }
            }.max() ?? 0
            let batchedVsPaired = Self.compare(shared, paired, label: "batched-vs-paired",
                alternativeBound: Self.batchedAlternativeBound)
            let batchedTopDrift = zip(shared, solo.entries).flatMap { batchedEntry, soloEntry in
                batchedEntry.topLogprobs.compactMap { alternative in
                    soloEntry.topLogprobs.first { $0.token == alternative.token }
                        .map { abs(Double($0.logprob - alternative.logprob)) }
                }
            }.max() ?? 0

            // Every plain token is the reference argmax up to a near-tie, which
            // a wrong row's logits or a corrupted cache would not be.
            let plainReference = try await Self.reference(harness, prompt: neighbor, generated: batchedPlain.tokens)
            let plainGaps = plainReference.map { $0.best - $0.chosen }
            let plainFailures = zip(plainGaps, plainReference).enumerated()
                .filter { $0.element.0 > 2 * $0.element.1.bound }
                .map { "plain step \($0.offset) argmax Δ=\($0.element.0)" }
            #expect(plainFailures.isEmpty, "\(plainFailures)")

            // (6) No retained native faults.
            #expect(engine.nativeCompletionFault == nil)
            #expect(await bridge.canSubmitWithNativeOwner())
            // Drafts counted before the snapshot include rounds of the plain
            // row outside the logprob row's decode steps: before its prefill
            // finished, and after its last step but before its consumer ended.
            try harness.write("logprobs-qualification", ["schema": 3, "tolerance": Self.tolerance,
                "batchedAlternativeBound": Self.batchedAlternativeBound,
                "promptTokens": prompt.count, "promptSHA256": GLM5NextRealModelHarness.tokenHash(prompt),
                "generatedSHA256": GLM5NextRealModelHarness.tokenHash(target.tokens),
                "mtpSHA256": GLM5NextRealModelHarness.tokenHash(mtp.tokens),
                "mtpParting": mtpParting ?? NSNull(), "mtpPartingGap": mtpPartingGap ?? NSNull(),
                "maxChosenDelta": agreement.maxChosen, "maxTopDelta": agreement.maxTop,
                "maxBound": agreement.maxBound, "batchedParting": batchedParting ?? NSNull(),
                "batchedLogprobDrift": batchedDrift, "batchedMaxChosenDelta": batched.maxChosen,
                "batchedMaxTopDelta": batched.maxTop, "batchedTopDriftFromSolo": batchedTopDrift,
                "pairedReferenceMaxDrift": pairedDrift, "batchedVsPairedMaxTop": batchedVsPaired.maxTop,
                "batchedVsPairedMaxChosen": batchedVsPaired.maxChosen,
                "batchedVsPairedFailures": batchedVsPaired.failures,
                "plainMaxArgmaxGap": plainGaps.max() ?? 0,
                "baselineMTP": try #require(mtp.mtp).record, "soloLogprobsDrafted": soloDrafted,
                "batchedDraftedBeforeLogprobsFinish": atFinish - before.draftedTokens,
                "batchedDraftedAfterLogprobsFinish": after - atFinish,
                "failures": agreement.failures + batched.failures + plainFailures])
        }
        #expect(!GLM5NextLoadFaultState.isRetained, "native faults were retained")
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.withLock { stored } }
    func set(_ value: Int?) { lock.withLock { stored = value } }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
