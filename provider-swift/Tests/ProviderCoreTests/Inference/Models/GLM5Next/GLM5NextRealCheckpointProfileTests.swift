import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Real-checkpoint qualification of GLM's checkpoint profile, one storage arm
/// per process (`DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_PROFILE` = `native` or
/// `balanced`) through the production bundle and an isolated ephemeral-key
/// store. For each prompt length it records the cold, donor, restored and
/// repeated runs (answer, TTFT, restored tokens), the bytes the donor wrote,
/// another tenant's miss, and logprob rows: cold and restored rows against the
/// dense teacher-forced reference along their own tokens (the existing GLM
/// bounds), plus restored against cold on their common prefix. The prompt asks
/// for a fact placed early in a long document, inside the profile's coded rows.
/// "State" is the profile's reconstruction error on the actual latent rows of
/// the reference prefill. Offline and expensive: needs the
/// `GLM5NextRealModelHarness` environment and exclusive GPU use.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_PROFILE"] != nil))
struct GLM5NextRealCheckpointProfileTests {
    typealias Logprobs = GLM5NextRealLogprobsQualificationTests

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var lengths: [Int] {
        (environment["DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_LENGTHS"] ?? "2048,8192,32768")
            .split(separator: ",").compactMap { Int($0) }
    }
    /// Longest prompt for which the dense reference is computed.
    static var referenceLimit: Int {
        Int(environment["DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_REFERENCE_MAX"] ?? "") ?? 40_000
    }
    static let colors = ["red", "green", "blue", "amber", "violet", "teal", "ochre", "silver"]
    static let logprobTokens = 32
    /// Room for low-effort reasoning before the answer; a run cut at this
    /// length is not a complete answer.
    static let answerTokens = 512

    private final class BundleLocator {}

    /// The metallib staged beside this test bundle, bound before any GPU work
    /// so the complete store can name its runtime identity.
    static func bindTestRuntimeMetallib() throws {
        if let bound = runtimeMetallibBindingInfo(), bound.digest == metallibHash() { return }
        let resources = try #require(Bundle(for: BundleLocator.self).resourceURL)
        let library = resources
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
            .standardizedFileURL.resolvingSymlinksInPath()
        let expected = try #require(hashFile(atPath: library.path))
        try #require(bindRuntimeMetallibForMLX(from: library) == expected && metallibHash() == expected)
    }

    static func fact(_ item: Int) -> (color: String, weight: Int) {
        (colors[(item * 7 + item / 5) % colors.count], (item * 13) % 97 + 3)
    }

    /// A fact document of about `tokens` rendered tokens; the question asks
    /// for a fact at a fifth of the document.
    static func prompt(_ harness: GLM5NextRealModelHarness, tokens: Int) async throws
        -> (tokens: [Int], target: Int)
    {
        var count = max(40, tokens / 18)
        var best: ([Int], Int)?
        for _ in 0 ..< 4 {
            let target = max(3, count / 5)
            let document = (1 ... count).map { item -> String in
                let value = fact(item)
                return "Fact \(item): item \(item) is \(value.color) and weighs \(value.weight) kg."
            }.joined(separator: " ")
            // The catalog line makes each length's document its own prefix, so
            // no length restores another's checkpoint.
            let text = "Reference catalog \(tokens).\n" + document
                + "\n\nQuestion: what color is item \(target), and how much does it weigh? "
                + "Answer in one short sentence."
            let rendered = try await harness.prompt(text, effort: "low")
            best = (rendered, target)
            let ratio = Double(tokens) / Double(rendered.count)
            if abs(1 - ratio) < 0.01 { break }
            count = max(40, Int((Double(count) * ratio).rounded()))
        }
        let (rendered, target) = try #require(best)
        return (rendered, target)
    }

    /// Sizes of the store's checkpoint files, by name.
    static func checkpointFiles(_ root: URL) -> [String: Int] {
        var files: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == SSDBlockStore.fileExtension else { continue }
            files[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return files
    }

    /// A complete answer (the model stopped by itself) naming the fact.
    static func answered(_ run: GLM5NextRealRun, target: Int) -> Bool {
        let value = fact(target)
        let answer = run.text.components(separatedBy: "</think>").last ?? run.text
        return run.reason == .stop && answer.lowercased().contains(value.color)
            && answer.contains("\(value.weight)")
    }

    struct RunRecord {
        let run: GLM5NextRealRun
        let answered: Bool
        var record: [String: Any] {
            ["ttftSeconds": run.ttftSeconds ?? -1, "wallSeconds": run.wallSeconds,
             "completionTokens": run.tokens.count, "finish": String(describing: run.reason),
             "stage": run.stageDisposition, "answered": answered,
             "prefillTokensSaved": run.usage?.prefixCachePrefillTokensSaved ?? 0,
             "answer": String((run.text.components(separatedBy: "</think>").last ?? run.text).prefix(160))]
        }
    }

    /// Restored against cold logprob rows on their common prefix, where both
    /// decode the same contexts with the same kernels.
    static func direct(_ restored: [CBv2TokenLogprob], _ cold: [CBv2TokenLogprob]) -> [String: Any] {
        var parting: Int?
        var chosen: [Double] = []
        var top: [Double] = []
        for (index, (a, b)) in zip(restored, cold).enumerated() {
            guard a.token == b.token else { parting = index; break }
            chosen.append(abs(Double(a.logprob - b.logprob)))
            for alternative in a.topLogprobs {
                if let match = b.topLogprobs.first(where: { $0.token == alternative.token }) {
                    top.append(abs(Double(alternative.logprob - match.logprob)))
                }
            }
        }
        let sorted = chosen.sorted()
        return ["commonSteps": chosen.count, "parting": parting ?? NSNull(),
                "maxChosenDelta": sorted.last ?? 0, "medianChosenDelta": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                "meanChosenDelta": chosen.isEmpty ? 0 : chosen.reduce(0, +) / Double(chosen.count),
                "maxTopDelta": top.max() ?? 0]
    }

    /// Dense teacher-forced reference (`Logprobs.reference`), plus the
    /// profile's reconstruction error on the latent rows of the same prefill.
    static func referenceAndState(
        _ harness: GLM5NextRealModelHarness, prompt: [Int], rows: [[Int]],
        profile: PagedKVQuantizationConfig
    ) async throws -> (references: [[Logprobs.ReferenceStep]], state: [String: Any]) {
        var references: [[Logprobs.ReferenceStep]] = []
        for generated in rows {
            references.append(try await Logprobs.reference(harness, prompt: prompt, generated: generated))
        }
        let container = try #require(harness.container)
        let activity = harness.budget.serviceBudget.beginUnboundedActivity()
        defer { activity.finish() }
        let errors: [Double] = try await container.perform { context in
            let root = try #require(context.model as? GLM5NextModel)
            return try MLX.withError { faults in
                let cache = root.newTextCache()
                for start in stride(from: 0, to: prompt.count, by: 128) {
                    let chunk = Array(prompt[start ..< min(start + 128, prompt.count)])
                    let output = try root.textTower.forward(
                        tokens: MLXArray(chunk.map(Int32.init)).reshaped([1, chunk.count]), cache: cache)
                    eval(output.logits); try faults.check()
                }
                var result: [Double] = []
                // Every coded row (all but the last band) of every DSA layer,
                // sampled at most 2,048 rows per layer.
                for layer in cache.layers {
                    guard let dsa = layer as? GLM5NextDSACache, let latents = dsa.latents else { continue }
                    let rows = latents.dim(1) - profile.recentTokenCount
                    guard rows > 0 else { continue }
                    let width = latents.dim(2)
                    let stride = max(1, rows / 2_048)
                    let values = latents[0, 0 ..< rows, 0...].asType(.float32)
                    eval(values); try faults.check()
                    let flat = values.asArray(Float.self)
                    for row in Swift.stride(from: 0, to: rows, by: stride) {
                        let original = Array(flat[row * width ..< (row + 1) * width])
                        let decoded = try PagedKVQuantizationReference.roundTrip(
                            original, config: profile, isKey: true)
                        let error = zip(original, decoded).reduce(0.0) {
                            $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1))
                        }
                        let norm = original.reduce(0.0) { $0 + Double($1 * $1) }
                        result.append(norm > 0 ? (error / norm).squareRoot() : 0)
                    }
                }
                return result
            }
        }
        let sorted = errors.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return (references, ["latentRowsSampled": sorted.count,
            "latentRelativeL2Median": percentile(0.5), "latentRelativeL2P99": percentile(0.99),
            "latentRelativeL2Max": sorted.last ?? 0,
            "latentRelativeL2Mean": sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)])
    }

    @Test func realCheckpointProfileQualification() async throws {
        let arm = try #require(Self.environment["DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_PROFILE"])
        try #require(["native", "balanced"].contains(arm))
        try Self.bindTestRuntimeMetallib()
        try await GLM5NextRealModelHarness.withLoaded(ssd: true, checkpointQuantization: arm) { harness in
            let session = try #require(harness.session)
            let snapshot = await session.cacheSnapshot()
            try #require(snapshot.durableMode == "ssd_complete", "\(String(describing: snapshot.status))")
            let layout = try #require(session.checkpointBackendLayout)
            try #require(layout == (arm == "native"
                ? CBv2CompleteCheckpointManifest.glm5NextPagedLayout
                : CBv2CompleteCheckpointManifest.glm5NextQuantizedPagedLayout), "layout \(layout)")
            let profile = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
            var cases: [[String: Any]] = []
            var failures: [String] = []
            for (index, length) in Self.lengths.enumerated() {
                let (prompt, target) = try await Self.prompt(harness, tokens: length)
                let base = UInt64(10_000 * (index + 1))
                func run(_ offset: UInt64, cache: Bool, salt: String = "tenant-a", donates: Bool = false,
                         topLogprobs: Int = 0, cancelAfterFirst: Bool = false) async throws -> RunRecord {
                    let run = try await harness.run(prompt, id: base + offset,
                        output: topLogprobs > 0 ? Self.logprobTokens : Self.answerTokens, cache: cache,
                        cancelAfterFirst: cancelAfterFirst, topLogprobs: topLogprobs, cacheSalt: salt,
                        donates: donates)
                    return RunRecord(run: run, answered: Self.answered(run, target: target))
                }
                let storeRoot = harness.root.appendingPathComponent("ssd", isDirectory: true)
                let filesBefore = Self.checkpointFiles(storeRoot)
                let writtenBefore = await session.cacheSnapshot().checkpoints
                let cold = try await run(1, cache: false)
                let donor = try await run(2, cache: true, donates: true)
                try await session.drainCheckpointWrites()
                let written = await session.cacheSnapshot().checkpoints
                let newFiles = Self.checkpointFiles(storeRoot).filter { filesBefore[$0.key] == nil }
                let restored = try await run(3, cache: true)
                let afterRestore = await session.cacheSnapshot().checkpoints
                let repeated = try await run(4, cache: true)
                // Lookup only (fleet-novel), so the isolated store holds the donor's files alone.
                let other: RunRecord? = try await run(5, cache: true, salt: "tenant-b")
                // A restore cancelled after its first output, then one that completes.
                let cancelled = try await run(8, cache: true, cancelAfterFirst: true)
                let afterCancel = try await run(9, cache: true)
                let restoredRow = try await run(6, cache: true, topLogprobs: Logprobs.topLogprobs)
                let coldRow = try await run(7, cache: false, topLogprobs: Logprobs.topLogprobs)
                var record: [String: Any] = [
                    "arm": arm, "layout": layout, "requestedTokens": length, "promptTokens": prompt.count,
                    "promptSHA256": GLM5NextRealModelHarness.tokenHash(prompt), "factItem": target,
                    "cold": cold.record, "donor": donor.record, "restored": restored.record,
                    "repeated": repeated.record, "other": other?.record ?? NSNull(),
                    "cancelled": cancelled.record, "afterCancel": afterCancel.record,
                    "restoredRow": restoredRow.record, "coldRow": coldRow.record,
                    "repeatTokensEqual": repeated.run.tokens == restored.run.tokens,
                    "afterCancelTokensEqual": afterCancel.run.tokens == restored.run.tokens,
                    "donorTokensEqualCold": donor.run.tokens == cold.run.tokens,
                    "restoredTokensEqualCold": restored.run.tokens == cold.run.tokens,
                    "newFileBytes": newFiles.values.sorted(),
                    "filesWritten": (written?.filesWritten ?? 0) - (writtenBefore?.filesWritten ?? 0),
                    "bytesWritten": (written?.bytesWritten ?? 0) - (writtenBefore?.bytesWritten ?? 0),
                    "writeMilliseconds": (written?.writeMilliseconds ?? 0) - (writtenBefore?.writeMilliseconds ?? 0),
                    // The restore's stage alone: authenticated read, decode and import.
                    "restoreStageMilliseconds": (afterRestore?.stageMilliseconds ?? 0)
                        - (written?.stageMilliseconds ?? 0),
                    "restoreBytesRead": (afterRestore?.stageReadBytes ?? 0) - (written?.stageReadBytes ?? 0),
                    "directRestoredVsCold": Self.direct(restoredRow.run.logprobs, coldRow.run.logprobs),
                ]
                let saved = restored.run.usage?.prefixCachePrefillTokensSaved ?? 0
                let donorSaved = donor.run.usage?.prefixCachePrefillTokensSaved ?? 0
                if donorSaved != 0 { failures.append("\(length): the donor restored \(donorSaved) tokens") }
                if saved == 0 { failures.append("\(length): restore read nothing") }
                if (other?.run.usage?.prefixCachePrefillTokensSaved ?? 0) != 0 {
                    failures.append("\(length): another tenant hit")
                }
                for (label, value) in [("repeated", repeated), ("after-cancel", afterCancel)]
                where (value.run.usage?.prefixCachePrefillTokensSaved ?? 0) != saved {
                    failures.append("\(length): \(label) restore covered a different depth")
                }
                for (label, value) in [("cold", cold), ("donor", donor), ("restored", restored),
                                       ("repeated", repeated), ("after-cancel", afterCancel)] where !value.answered {
                    failures.append("\(length): \(label) answer wrong or truncated")
                }
                if prompt.count <= Self.referenceLimit {
                    let (references, state) = try await Self.referenceAndState(
                        harness, prompt: prompt, rows: [restoredRow.run.tokens, coldRow.run.tokens],
                        profile: profile)
                    let restoredEntries = try await Self.served(restoredRow.run.logprobs, harness)
                    let coldEntries = try await Self.served(coldRow.run.logprobs, harness)
                    let restoredAgreement = Logprobs.compare(restoredEntries, references[0], label: "restored")
                    let coldAgreement = Logprobs.compare(coldEntries, references[1], label: "cold")
                    record["state"] = state
                    record["teacherRestored"] = ["maxChosenDelta": restoredAgreement.maxChosen,
                        "maxTopDelta": restoredAgreement.maxTop, "maxBound": restoredAgreement.maxBound,
                        "failures": restoredAgreement.failures]
                    record["teacherCold"] = ["maxChosenDelta": coldAgreement.maxChosen,
                        "maxTopDelta": coldAgreement.maxTop, "maxBound": coldAgreement.maxBound,
                        "failures": coldAgreement.failures]
                }
                cases.append(record)
                try harness.write("checkpoint-profile-\(arm)", ["schema": 1, "arm": arm, "layout": layout,
                    "cases": cases, "failures": failures, "loadSeconds": harness.loadSeconds])
                print("GLM_CHECKPOINT_PROFILE arm=\(arm) length=\(prompt.count) saved=\(saved) "
                    + "cold_ttft=\(cold.run.ttftSeconds ?? -1) restored_ttft=\(restored.run.ttftSeconds ?? -1) "
                    + "bytes=\(record["bytesWritten"] ?? 0) answered=\(restored.answered)")
            }
            #expect(failures.isEmpty, "\(failures)")
        }
        #expect(!GLM5NextLoadFaultState.isRetained, "native faults were retained")
    }

    /// The engine's entries as the relay serves them: decoded token text, as
    /// `Logprobs.compare` and its reference expect.
    static func served(_ values: [CBv2TokenLogprob], _ harness: GLM5NextRealModelHarness) async throws
        -> [SSETokenLogprob]
    {
        var result: [SSETokenLogprob] = []
        for value in values {
            var top: [SSETokenLogprob.Top] = []
            for alternative in value.topLogprobs {
                top.append(.init(token: try await harness.decode([alternative.token]),
                                 logprob: alternative.logprob, bytes: nil))
            }
            result.append(.init(token: try await harness.decode([value.token]), logprob: value.logprob,
                                bytes: nil, topLogprobs: top))
        }
        return result
    }
}
