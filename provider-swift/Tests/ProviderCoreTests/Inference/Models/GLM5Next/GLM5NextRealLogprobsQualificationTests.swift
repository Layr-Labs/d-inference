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
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_LOGPROBS"] == "1"))
struct GLM5NextRealLogprobsQualificationTests {
    static let promptText = "Write a long, detailed essay on the history of the Roman Empire."
    static let logprobTokens = 32
    static let plainTokens = 128
    static let topLogprobs = 5
    /// Absolute bound, in nats, between a served logprob and the
    /// teacher-forced reference. The reference runs the same weights through
    /// the dense text cache one token at a time; the server runs the paged
    /// cache and its batched kernels. Both produce bf16 logits whose last
    /// mantissa bit is worth 2^-8 of their magnitude (about 0.03-0.1 nats for
    /// logits of 8-30), and the two paths reduce bf16 activations in a
    /// different order. So 1e-3 holds only for identical kernels; 5e-2 is
    /// above that rounding floor yet far below any real defect (wrong row,
    /// wrong position, unnormalized logits, temperature applied: errors of
    /// 0.5 nats or more). The run records the observed maximum.
    static var tolerance: Double {
        ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_TOLERANCE"]
            .flatMap(Double.init) ?? 5e-2
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
        let chosen: Double
        let top: [(token: String, logprob: Double)]
    }

    /// Teacher-forced log-softmax of the managed GLM root on the same prefix:
    /// the prompt in bounded chunks, then each generated token one at a time.
    /// Step i scores the distribution that sampled `generated[i]`.
    static func reference(_ harness: GLM5NextRealModelHarness, prompt: [Int], generated: [Int])
        async throws -> [ReferenceStep] {
        let container = try #require(harness.container)
        let activity = harness.budget.serviceBudget.beginUnboundedActivity()
        defer { activity.finish() }
        let rows: [[Float]] = try await container.perform { context in
            let root = try #require(context.model as? GLM5NextModel)
            return try MLX.withError { errors in
                let cache = root.newTextCache()
                func logProbabilities(_ tokens: [Int]) throws -> [Float] {
                    let output = try root.textTower.forward(
                        tokens: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]), cache: cache)
                    let logits = output.logits[0, -1, 0...].asType(.float32)
                    let values = logits - logSumExp(logits, axis: -1, keepDims: true)
                    eval(values); try errors.check()
                    let row = values.asArray(Float.self); try errors.check()
                    return row
                }
                var rows: [[Float]] = []
                var last: [Float] = []
                for start in stride(from: 0, to: prompt.count, by: 128) {
                    last = try logProbabilities(Array(prompt[start..<min(start + 128, prompt.count)]))
                }
                rows.append(last)
                for token in generated.dropLast() { rows.append(try logProbabilities([token])) }
                return rows
            }
        }
        var steps: [ReferenceStep] = []
        for (row, token) in zip(rows, generated) {
            let order = row.indices.sorted { row[$0] == row[$1] ? $0 < $1 : row[$0] > row[$1] }.prefix(8)
            var top: [(token: String, logprob: Double)] = []
            for id in order { top.append((try await harness.decode([id]), Double(row[id]))) }
            steps.append(ReferenceStep(chosen: Double(row[token]), top: top))
        }
        return steps
    }

    @Test func realLogprobsMatchTeacherForcedReferenceAndKeepMTPGreedy() async throws {
        try await GLM5NextRealModelHarness.withLoaded(concurrency: 2) { harness in
            let session = try #require(harness.session)
            let engine = session.rawEngine
            let bridge = try #require(harness.bundle).bridge
            let model = harness.plan.weights.catalog.id
            let prompt = try await harness.prompt(Self.promptText)
            #expect(engine.acceptsLogprobRows)

            // (2) MTP greedy without logprobs: the token-id baseline.
            let mtp = try await harness.run(prompt, id: 1, output: Self.logprobTokens)
            try #require(mtp.reason == .length && mtp.tokens.count == Self.logprobTokens,
                "the prompt must not stop early: \(String(describing: mtp.reason)) \(mtp.tokens.count)")
            #expect(try #require(mtp.mtp).proposed > 0, "the baseline row must speculate")

            // (1) Logprobs row through the production relay channel.
            var before = try #require(engine.mtpMetricsSnapshot())
            let solo = try await Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.logprobTokens, logprobs: true), id: "glm-real-logprobs")
            let soloDrafted = try #require(engine.mtpMetricsSnapshot()).draftedTokens - before.draftedTokens
            #expect(solo.errors.isEmpty, "logprobs request errors: \(solo.errors)")
            #expect(solo.generated == Self.logprobTokens && solo.entries.count == Self.logprobTokens)
            #expect(soloDrafted == 0, "a logprobs row must never speculate")
            let decoded = try await mtp.tokens.asyncMap { try await harness.decode([$0]) }
            #expect(solo.entries.map(\.token) == decoded, "logprobs greedy tokens differ from the MTP greedy tokens")
            #expect(solo.text == mtp.text, "logprobs text differs from the MTP greedy text")

            let reference = try await Self.reference(harness, prompt: prompt, generated: mtp.tokens)
            var maxChosen = 0.0, maxTop = 0.0
            var failures: [String] = []
            for (index, (entry, step)) in zip(solo.entries, reference).enumerated() {
                #expect(entry.topLogprobs.count == Self.topLogprobs)
                #expect(entry.topLogprobs.first?.logprob == entry.logprob)
                let chosen = abs(Double(entry.logprob) - step.chosen)
                maxChosen = max(maxChosen, chosen)
                if chosen > Self.tolerance { failures.append("step \(index) chosen Δ=\(chosen)") }
                // Near-ties may reorder within the tolerance; every served
                // alternative must be a reference candidate at the same value,
                // and each reference top-5 entry clearly above the served
                // fifth must be served.
                for (rank, alternative) in entry.topLogprobs.enumerated() {
                    let match = step.top.filter { $0.token == alternative.token }
                        .map { abs($0.logprob - Double(alternative.logprob)) }.min()
                    guard let match else { failures.append("step \(index) rank \(rank) not in reference top-8"); continue }
                    maxTop = max(maxTop, match)
                    if match > Self.tolerance { failures.append("step \(index) rank \(rank) Δ=\(match)") }
                }
                let floor = Double(entry.topLogprobs.last?.logprob ?? 0) + Self.tolerance
                for candidate in step.top.prefix(Self.topLogprobs) where candidate.logprob > floor
                    && !entry.topLogprobs.contains(where: { $0.token == candidate.token }) {
                    failures.append("step \(index) reference \(candidate.token.debugDescription) missing")
                }
            }
            #expect(failures.isEmpty, "\(failures)")

            // (3) A logprobs row batched with a plain row.
            let plainSolo = try await Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.plainTokens, logprobs: false), id: "glm-real-plain-solo")
            #expect(plainSolo.errors.isEmpty && plainSolo.generated == Self.plainTokens)
            before = try #require(engine.mtpMetricsSnapshot())
            let atLogprobsFinish = SnapshotBox()
            async let plain = Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.plainTokens, logprobs: false), id: "glm-real-plain-batched")
            async let logprobs = Self.serve(bridge, prompt: prompt,
                request: Self.request(model, maxTokens: Self.logprobTokens, logprobs: true), id: "glm-real-logprobs-batched",
                onFinish: { atLogprobsFinish.set(engine.mtpMetricsSnapshot()?.draftedTokens) })
            let (batchedPlain, batchedLogprobs) = try await (plain, logprobs)
            let after = try #require(engine.mtpMetricsSnapshot()).draftedTokens
            let atFinish = try #require(atLogprobsFinish.value)
            #expect(batchedPlain.errors.isEmpty && batchedLogprobs.errors.isEmpty)
            #expect(batchedPlain.text == plainSolo.text, "batched plain row changed its greedy output")
            #expect(batchedLogprobs.text == solo.text, "batched logprobs row changed its greedy output")
            #expect(batchedLogprobs.entries.map(\.token) == solo.entries.map(\.token))
            let batchedDrift = zip(batchedLogprobs.entries, solo.entries)
                .map { abs(Double($0.logprob - $1.logprob)) }.max() ?? 0
            #expect(batchedDrift <= Self.tolerance)
            #expect(after > atFinish, "the plain row must speculate again after the logprobs row finishes")

            // (4) No retained native faults.
            #expect(engine.nativeCompletionFault == nil)
            #expect(await bridge.canSubmitWithNativeOwner())
            try harness.write("logprobs-qualification", ["schema": 1, "tolerance": Self.tolerance,
                "promptTokens": prompt.count, "promptSHA256": GLM5NextRealModelHarness.tokenHash(prompt),
                "generatedSHA256": GLM5NextRealModelHarness.tokenHash(mtp.tokens),
                "maxChosenDelta": maxChosen, "maxTopDelta": maxTop, "batchedLogprobDrift": batchedDrift,
                "baselineMTP": try #require(mtp.mtp).record, "soloLogprobsDrafted": soloDrafted,
                "batchedDraftedBeforeLogprobsFinish": atFinish - before.draftedTokens,
                "batchedDraftedAfterLogprobsFinish": after - atFinish, "failures": failures])
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
