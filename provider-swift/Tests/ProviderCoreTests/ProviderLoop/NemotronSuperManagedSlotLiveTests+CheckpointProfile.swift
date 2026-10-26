// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
@_spi(Diagnostics) import MLXLMCommon
import Testing
@testable import ProviderCore

/// Gated qualification of the managed Super slot's checkpoint profile on the
/// pinned checkpoint, one storage arm per process: the operator's
/// `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION` (`native` or `balanced`) selects
/// it. The loop's complete SSD store lives in an isolated ephemeral-key root
/// (`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`, `DARKBLOOM_PREFIX_CACHE_TEST_ROOT`).
/// For each prompt length (`DARKBLOOM_SUPER_CHECKPOINT_LENGTHS`) it records
/// cold, donor, restored and repeated speculating runs (answer, TTFT, restored
/// tokens), the bytes the donor wrote, another tenant's miss, and logprob rows:
/// restored and cold rows against teacher forcing along their own tokens under
/// the existing Super bound, plus restored against cold on their common
/// prefix. The question asks for a fact early in the document, inside the
/// profile's coded rows. Writes `DARKBLOOM_SUPER_CHECKPOINT_PROFILE_OUT`.
extension NemotronSuperManagedSlotTests {
    private final class CheckpointProfileBundleLocator {}

    struct ProfileRow {
        var tokens: [Int] = []
        var logprobs: [CBv2TokenLogprob] = []
        var text = ""
        var ttft: Double?
        var seconds = 0.0
        var reason: String = "none"
        var saved = 0
        var stage = "not_attempted"
    }

    static let profileColors = ["red", "green", "blue", "amber", "violet", "teal", "ochre", "silver"]

    static func profileFact(_ item: Int) -> (color: String, weight: Int) {
        (profileColors[(item * 7 + item / 5) % profileColors.count], (item * 13) % 97 + 3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
        && ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_CHECKPOINT_PROFILE_LIVE"] == "1"),
        .timeLimit(.minutes(120)))
    func pinnedCheckpointCheckpointProfileQualification() async throws {
        let environment = ProcessInfo.processInfo.environment
        let arm = try #require(environment["DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"])
        try #require(["native", "balanced"].contains(arm))
        try #require(environment[PrefixCachePolicy.memoryEnvironmentFlag] != "1",
                     "the resident bank replaces the complete SSD store")
        // Just past whole 2,048-token chunks, so each restores 2,048, 8,192 and 30,720 tokens.
        let lengths = (environment["DARKBLOOM_SUPER_CHECKPOINT_LENGTHS"] ?? "2400,8400,32000")
            .split(separator: ",").compactMap { Int($0) }
        // The staged test metallib, bound before any GPU work so the store can
        // name its runtime identity.
        let resources = try #require(Bundle(for: CheckpointProfileBundleLocator.self).resourceURL)
        let library = resources
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
            .standardizedFileURL.resolvingSymlinksInPath()
        let digest = try #require(hashFile(atPath: library.path))
        try #require(bindRuntimeMetallibForMLX(from: library) == digest)

        let directory = URL(fileURLWithPath: try #require(environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]),
                            isDirectory: true)
        let (loop, loadSeconds) = try await Self.liveLoop(name: "super-checkpoint-profile")
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let store = try #require(owner.bridge.ssdHybridCheckpointStore,
            "\(owner.bridge.prefixCacheModelStatus()) \(String(describing: owner.bridge.prefixCacheConstructionFailure))")
        let engine = try #require(await owner.bridge.ownedEngine as? EngineV2)
        let layout = store.config.backendLayout
        let expectedLayout = arm == "native" ? CBv2CompleteCheckpointManifest.pagedLayout
            : owner.speculates ? CBv2CompleteCheckpointManifest.nativeQuantizedPagedMTPLayout
            : CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout
        try #require(layout == expectedLayout, "layout \(layout)")
        let stops = await owner.bridge.stopTokenIds
        let templateBytes = try NemotronSuperCheckpoint.Inputs(directory: directory).templateBytes
        let tokenizer = owner.tokenizer.inner
        let top = 5, logprobTokens = 48, answerTokens = 128, valueBound: Float = 0.35

        // The catalog line makes each length's document its own prefix, so no
        // length restores another's checkpoint.
        func body(catalog: Int, facts count: Int, target: Int) throws -> Data {
            let document = (1 ... count).map { item -> String in
                let fact = Self.profileFact(item)
                return "Fact \(item): item \(item) is \(fact.color) and weighs \(fact.weight) kg."
            }.joined(separator: " ")
            return try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "temperature": 0,
                "chat_template_kwargs": ["enable_thinking": false],
                "messages": [["role": "user", "content": "Reference catalog \(catalog).\n" + document
                    + "\n\nWhat color is item \(target), and how much does it weigh? Answer in one short sentence."]]])
        }
        func prompt(tokens: Int) throws -> (tokens: [Int], target: Int) {
            var count = max(40, tokens / 17)
            var best: ([Int], Int)?
            for _ in 0 ..< 4 {
                let target = max(3, count / 5)
                let data = try body(catalog: tokens, facts: count, target: target)
                let rendered = try NemotronSuperRequestPlan(body: data, modelID: Self.modelID)
                    .textPromptTokens(body: data, templateBytes: templateBytes, tokenizer: tokenizer)
                best = (rendered, target)
                let ratio = Double(tokens) / Double(rendered.count)
                if abs(1 - ratio) < 0.01 && rendered.count <= tokens { break }
                count = max(40, Int((Double(count) * ratio * 0.995).rounded(.down)))
            }
            return try #require(best)
        }
        /// A complete answer (the model stopped by itself) naming the fact.
        func answered(_ row: ProfileRow, target: Int) -> Bool {
            let fact = Self.profileFact(target)
            return row.reason == "stop" && row.text.lowercased().contains(fact.color)
                && row.text.contains("\(fact.weight)")
        }

        // Engine requests with the store's own staging, as the production
        // bridge and the benchmark session stage them: the receipt binds the
        // stage to its consumer. No donation demand keeps local write-all;
        // `donates: false` registers the coordinator's fleet-novel hint (0),
        // so the request only looks up.
        var receipt: UInt64 = 0x51_0000
        func run(_ tokens: [Int], id: UInt64, cache: Bool, scope: String = "tenant-a",
                 topLogprobs: Int = 0, maxTokens: Int, cancelAfterFirst: Bool = false,
                 donates: Bool = true) async throws -> ProfileRow {
            receipt += 1
            var request = CBv2Request(id: .init(id), promptTokens: tokens,
                sampling: .init(temperature: 0, topLogprobs: topLogprobs), maxTokens: maxTokens,
                stopTokens: stops, cacheSalt: cache ? scope : nil, prefixCacheEnabled: cache)
            let receiptID = CBv2RequestID(receipt)
            request.prefixCacheReceiptID = receiptID
            if cache && !donates {
                store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: receiptID)
            }
            var row = ProfileRow()
            let started = ContinuousClock.now
            func seconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            }
            if cache {
                let importRequest = request
                let staged = await store.stage(requestID: receiptID, request: importRequest,
                    reserveReadScratch: { try engine.reserveCompleteCheckpointReadScratch() }) {
                        try engine.planCompleteCheckpointImport(manifest: $0, request: importRequest)
                    }
                row.stage = String(describing: staged.disposition)
            }
            for await event in try engine.submit(request) {
                switch event {
                case .delta(let text, let values, let entries):
                    if row.ttft == nil {
                        row.ttft = seconds(started.duration(to: .now))
                        if cancelAfterFirst { engine.cancel(.init(id)) }
                    }
                    row.text += text
                    row.tokens += values
                    row.logprobs += entries ?? []
                case .finished(let reason, let usage):
                    row.reason = String(describing: reason)
                    row.saved = usage.prefixCachePrefillTokensSaved
                }
            }
            row.seconds = seconds(started.duration(to: .now))
            await store.abandonStaging(requestID: receiptID)
            store.discardDonationDemand(requestID: receiptID)
            store.discardReadyReceipt(requestID: receiptID)
            return row
        }
        func summarize(_ row: ProfileRow, target: Int) -> [String: Any] {
            ["ttftSeconds": row.ttft ?? -1, "seconds": row.seconds, "completionTokens": row.tokens.count,
             "finish": row.reason, "stage": row.stage, "prefillTokensSaved": row.saved,
             "answered": answered(row, target: target), "answer": String(row.text.prefix(160))]
        }
        /// Teacher forcing along `row`'s own tokens on the idle engine.
        func teacher(_ prompt: [Int], _ row: ProfileRow) throws -> [String: Any] {
            let snapshot = try engine.teacherForcedScores(try CBv2TeacherForcedScoreRequest(
                promptTokens: prompt, continuation: row.tokens, vocabularySize: 131_072))
            var deviations: [Float] = [], gaps: [Float] = []
            for (entry, score) in zip(row.logprobs, snapshot.records) {
                let forced = Float(bitPattern: score.forcedLogProbabilityBits)
                deviations.append(abs(entry.logprob - forced))
                if score.argMaxID != entry.token {
                    gaps.append(Float(bitPattern: score.argMaxValueBits)
                        - Float(bitPattern: score.forcedTokenValueBits))
                }
            }
            let sorted = deviations.sorted()
            return ["steps": deviations.count, "maxDelta": sorted.last ?? 0,
                    "medianDelta": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                    "meanDelta": deviations.isEmpty ? 0 : deviations.reduce(0, +) / Float(deviations.count),
                    "argmaxMismatches": gaps.count, "maxMismatchGap": gaps.max() ?? 0,
                    "withinBound": (sorted.last ?? .infinity) < valueBound
                        && gaps.allSatisfy { $0 <= 2 * valueBound }]
        }
        func direct(_ restored: ProfileRow, _ cold: ProfileRow) -> [String: Any] {
            var chosen: [Float] = []
            var parting: Int?
            for (index, (a, b)) in zip(restored.logprobs, cold.logprobs).enumerated() {
                guard a.token == b.token else { parting = index; break }
                chosen.append(abs(a.logprob - b.logprob))
            }
            let sorted = chosen.sorted()
            return ["commonSteps": chosen.count, "parting": parting ?? NSNull(),
                    "maxChosenDelta": sorted.last ?? 0,
                    "medianChosenDelta": sorted.isEmpty ? 0 : sorted[sorted.count / 2]]
        }

        /// Sizes of the store's checkpoint files, by name.
        func checkpointFiles() -> [String: Int] {
            var files: [String: Int] = [:]
            let enumerator = FileManager.default.enumerator(at: store.config.root,
                                                            includingPropertiesForKeys: [.fileSizeKey])
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == SSDBlockStore.fileExtension else { continue }
                files[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return files
        }

        var cases: [[String: Any]] = []
        var failures: [String] = []
        for (index, length) in lengths.enumerated() {
            let (tokens, target) = try prompt(tokens: length)
            let base = UInt64(0x5C00_0000 + index * 0x1000)
            let before = store.stats()
            let filesBefore = checkpointFiles()
            let cold = try await run(tokens, id: base + 1, cache: false, maxTokens: answerTokens)
            let donor = try await run(tokens, id: base + 2, cache: true, maxTokens: answerTokens)
            await store.waitForWritesForTesting()
            let written = store.stats()
            let newFiles = checkpointFiles().filter { filesBefore[$0.key] == nil }
            let restored = try await run(tokens, id: base + 3, cache: true, maxTokens: answerTokens)
            let afterRestore = store.stats()
            let repeated = try await run(tokens, id: base + 4, cache: true, maxTokens: answerTokens)
            let other = try await run(tokens, id: base + 5, cache: true, scope: "tenant-b", maxTokens: answerTokens,
                                    donates: false)
            // A restore cancelled after its first output, then one that completes.
            let cancelled = try await run(tokens, id: base + 8, cache: true, maxTokens: answerTokens,
                                          cancelAfterFirst: true)
            let afterCancel = try await run(tokens, id: base + 9, cache: true, maxTokens: answerTokens)
            let restoredRow = try await run(tokens, id: base + 6, cache: true, topLogprobs: top,
                                            maxTokens: logprobTokens)
            let coldRow = try await run(tokens, id: base + 7, cache: false, topLogprobs: top,
                                        maxTokens: logprobTokens)
            await store.waitForWritesForTesting()
            let teacherRestored = try teacher(tokens, restoredRow)
            let teacherCold = try teacher(tokens, coldRow)
            let record: [String: Any] = [
                "arm": arm, "layout": layout, "speculates": owner.speculates, "requestedTokens": length,
                "promptTokens": tokens.count, "factItem": target,
                "cold": summarize(cold, target: target), "donor": summarize(donor, target: target),
                "restored": summarize(restored, target: target), "repeated": summarize(repeated, target: target),
                "other": summarize(other, target: target), "restoredRow": summarize(restoredRow, target: target),
                "coldRow": summarize(coldRow, target: target),
                "cancelled": summarize(cancelled, target: target), "afterCancel": summarize(afterCancel, target: target),
                "repeatTokensEqual": repeated.tokens == restored.tokens,
                "afterCancelTokensEqual": afterCancel.tokens == restored.tokens,
                "donorTokensEqualCold": donor.tokens == cold.tokens,
                "restoredTokensEqualCold": restored.tokens == cold.tokens,
                "newFileBytes": newFiles.values.sorted(),
                "filesWritten": written.filesWritten - before.filesWritten,
                "bytesWritten": written.bytesWritten - before.bytesWritten,
                "writeMilliseconds": written.writeMilliseconds - before.writeMilliseconds,
                // The restore's stage alone: authenticated read, decode and import.
                "restoreStageMilliseconds": afterRestore.stageMilliseconds - written.stageMilliseconds,
                "restoreBytesRead": afterRestore.stageReadBytes - written.stageReadBytes,
                "teacherRestored": teacherRestored, "teacherCold": teacherCold,
                "directRestoredVsCold": direct(restoredRow, coldRow),
            ]
            if donor.saved != 0 { failures.append("\(length): the donor restored \(donor.saved) tokens") }
            if restored.saved == 0 { failures.append("\(length): restore read nothing") }
            if other.saved != 0 { failures.append("\(length): another tenant hit") }
            // Gaj's matched controls, which Super's deterministic speculation
            // keeps: export leaves the donor's output unchanged, and restores
            // of one file (repeated, after a cancelled one) are equal.
            if donor.tokens != cold.tokens { failures.append("\(length): the donating export changed the donor") }
            for (label, row) in [("repeated", repeated), ("after-cancel", afterCancel)] {
                if row.saved != restored.saved { failures.append("\(length): \(label) restore covered a different depth") }
                if row.tokens != restored.tokens { failures.append("\(length): \(label) restore differs from the first") }
            }
            for (label, row) in [("cold", cold), ("donor", donor), ("restored", restored), ("repeated", repeated),
                                 ("after-cancel", afterCancel)]
            where !answered(row, target: target) {
                failures.append("\(length): \(label) answer wrong or truncated")
            }
            cases.append(record)
            let summary: [String: Any] = ["schema": 1, "arm": arm, "layout": layout,
                "loadSeconds": Double(loadSeconds.components.seconds), "cases": cases, "failures": failures]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
            if let output = environment["DARKBLOOM_SUPER_CHECKPOINT_PROFILE_OUT"] {
                try data.write(to: URL(fileURLWithPath: output))
            }
            print("SUPER_CHECKPOINT_PROFILE arm=\(arm) prompt=\(tokens.count) saved=\(restored.saved) "
                + "cold_ttft=\(cold.ttft ?? -1) restored_ttft=\(restored.ttft ?? -1) "
                + "bytes=\(written.bytesWritten - before.bytesWritten) answered=\(answered(restored, target: target))")
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        try await Self.awaitMemoryReturn(loop)
    }
}
