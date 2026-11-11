// Copyright © 2026 Eigen Labs.
//
// LIVE C3/N7 qualification on the real LFM2.5-24B-A2B artifact through the
// production bundle: B = 1, 2, 4, 8 concurrent greedy requests with mixed
// prompt lengths (~25 to ~3,100 tokens) and one member cancelled
// mid-decode. Every row (the cancelled one up to its cancel) must match its
// own B=1 stream or differ first at a near-tie swap of the two leading
// candidates (see `nearTieNats`; logprobs captured for every token), the
// cancelled row must stop early, and batching must be REAL: the engine's own counters (per-request
// batch_rows_max and the engine-wide decode-rows / steps ratio) must show
// more than one decode row per step. Afterwards the engine must hold no
// request, and in-use / reserved KV must return to the idle baseline.
//
// Prefix caching is disabled per request (cacheEnabled=false) so the rows
// compare pure batched execution, not checkpoint restores.

import Foundation
import MLX
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("LFM2.5-24B-A2B batching qualification (live)", .serialized,
       .enabled(if: LFM25Qual.selected("batching")))
struct LFM25BatchingQualificationLiveTests {
    private static let questions = [
        "Which warehouse logged the most crates? Answer briefly.",
        "Name two parts that appear more than once.",
        "Summarize the records in one sentence.",
        "What is the smallest crate count listed?",
        "List three warehouse numbers you saw.",
        "Is any part logged in warehouse 4? Explain briefly.",
        "Count how many records mention part 3.",
        "Which record number comes last?",
    ]
    /// Records per prompt: ~25, 75, 190, 450, 870, 1,550, 2,230, 3,080 tokens.
    private static let recordCounts = [0, 3, 10, 25, 50, 90, 130, 180]
    private static let members: [Int: [Int]] = [1: [0], 2: [0, 7], 4: [1, 3, 5, 7], 8: Array(0 ..< 8)]
    private static let maxTokens = 64
    private static let cancelAfterChunks = 8
    /// Greedy decoding is not batch-shape invariant in bf16 (B=1 decode and
    /// [B,1] decode use different quantized-matmul/attention kernel shapes),
    /// so a free-running row may flip at a near tie and then decorrelate.
    /// Isolation is therefore judged per row: identical to B=1, or the first
    /// differing token is a swap of the two leading candidates in BOTH runs,
    /// each within `nearTieNats`, after a shared prefix whose per-token
    /// logprobs agree within `prefixToleranceNats`. Cross-row contamination
    /// would instead flip confident steps or perturb the shared prefix.
    ///
    /// A first-token difference after the scheduler split the row's prompt
    /// into a different number of prefill chunks than its B=1 run (chunk
    /// budget shared with decode rows) is judged against the mlx-lm 0.32.0
    /// reference's OWN chunked-vs-one-shot prefill variance on this artifact:
    /// max |d logit| 4.78 at prompt positions
    /// (evidence/native/reference/selfcheck.json, chat_4k chunk_512).
    private static let topLogprobs = 5
    private static let nearTieNats: Float = 1.0
    private static let prefixToleranceNats: Float = 1.0
    private static let chunkedPrefillNats: Float = 4.78125

    @Test("B=1/2/4/8 mixed lengths + mid-decode cancel: isolation, real batching, no leaks")
    func batchedIsolation() async throws {
        let model = try await LFM25Loaded.load()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-qual-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try await LFM25Slot.make(model, maxConcurrent: 8, cacheRoot: root)
        defer { MLX.Memory.clearCache() }
        #expect(await slot.bridge.kvBackendKind == .paged)

        let prompts = zip(Self.recordCounts, Self.questions).enumerated().map { index, pair in
            model.encode(LFM25Qual.chatML(
                (pair.0 > 0 ? LFM25Qual.records(0 ..< pair.0, salt: index) + " " : "") + pair.1))
        }
        let idle = try await slot.settled()
        var evidence: [String: Any] = [
            "promptTokens": prompts.map(\.count), "maxTokens": Self.maxTokens,
            "kvBytesCapacity": slot.kvBytesCapacity,
            "activationReserveBytes": slot.activationReserveBytes, "idle": idle.evidence,
        ]

        // Pass 1 (asserted): pure argmax, near-tie criterion exact.
        evidence["argmax"] = try await sweep(slot, prompts: prompts, idle: idle, penalty: 1.0,
                                             assertNearTie: true, label: "argmax")
        // Pass 2 (recorded): product default sampling (repetition_penalty
        // 1.05 from generation_config). Logprobs are pre-penalty, so the
        // margin criterion is reported, not asserted; batching, cancel and
        // leak checks are asserted in both passes.
        evidence["productDefault"] = try await sweep(slot, prompts: prompts, idle: idle, penalty: nil,
                                                     assertNearTie: false, label: "default")
        evidence["peakMemoryGiB"] = LFM25Qual.gib(MLX.Memory.peakMemory)
        LFM25Qual.writeEvidence("batching", evidence)
        await slot.bridge.shutdown()
    }

    /// One B=1/2/4/8 sweep. `penalty` 1.0 makes greedy a pure argmax of the
    /// raw logits that logprobs report, so the near-tie criterion is exact;
    /// nil keeps the product default sampling (generation_config).
    private func sweep(
        _ slot: LFM25Slot, prompts: [[Int]], idle: CBv2CapacitySnapshot,
        penalty: Float?, assertNearTie: Bool, label: String
    ) async throws -> [String: Any] {
        var evidence: [String: Any] = ["repetitionPenalty": penalty.map { Double($0) } ?? -1]
        // B=1 references, one request at a time.
        var references: [LFM25Run] = []
        for (index, tokens) in prompts.enumerated() {
            let run = await LFM25Run.run(slot, tokens: tokens, maxTokens: Self.maxTokens,
                                          id: "qual-ref-\(index)", cacheEnabled: false,
                                          topLogprobs: Self.topLogprobs, repetitionPenalty: penalty)
            #expect(run.error == nil, "reference \(index): \(run.error ?? "")")
            #expect(run.completionTokens > 0)
            references.append(run)
        }
        evidence["references"] = references.map(\.evidence)

        var widths: [[String: Any]] = []
        for width in [1, 2, 4, 8] {
            let rows = try #require(Self.members[width])
            let cancelled = width >= 2 ? rows[1] : nil
            let before = await slot.capacity()
            let peakSampler = LFM25CapacitySampler(slot: slot)
            let sampling = Task { await peakSampler.run() }
            let runs = await withTaskGroup(of: (Int, LFM25Run).self) { group in
                for row in rows {
                    group.addTask {
                        (row, await LFM25Run.run(
                            slot, tokens: prompts[row], maxTokens: Self.maxTokens,
                            id: "qual-b\(width)-r\(row)", cacheEnabled: false,
                            cancelAfterChunks: row == cancelled ? Self.cancelAfterChunks : nil,
                            topLogprobs: Self.topLogprobs, repetitionPenalty: penalty))
                    }
                }
                var out: [Int: LFM25Run] = [:]
                for await (row, run) in group { out[row] = run }
                return out
            }
            peakSampler.stop()
            let observed = await sampling.value
            let after = try await slot.settled(idle: idle)
            let steps = after.stepsExecuted - before.stepsExecuted
            let decodeRows = Int(after.decodeRowsTotal - before.decodeRowsTotal)
            var rowEvidence: [[String: Any]] = []
            var isolated = 0
            var exact = 0
            for row in rows {
                let run = try #require(runs[row])
                let reference = references[row]
                let divergence = LFM25Divergence(reference: reference.logprobs, run: run.logprobs)
                var item = run.evidence
                item["row"] = row
                item["matchesB1"] = run.text == reference.text
                item["commonPrefixChars"] = LFM25Qual.commonPrefix(run.text, reference.text)
                item["referenceChars"] = reference.text.count
                item["divergence"] = divergence.evidence
                let chunksDiffer = run.engine?.prefillChunks != reference.engine?.prefillChunks
                let bound = divergence.index == 0 && chunksDiffer ? Self.chunkedPrefillNats : Self.nearTieNats
                let acceptable = divergence.isIdentical
                    || (divergence.isTopTwoSwap(within: bound)
                        && divergence.prefixMaxAbsDelta <= Self.prefixToleranceNats)
                item["prefillChunks"] = run.engine?.prefillChunks ?? -1
                item["referencePrefillChunks"] = reference.engine?.prefillChunks ?? -1
                item["nearTieBoundNats"] = Double(bound)
                item["isolated"] = acceptable
                #expect(!run.logprobs.isEmpty, "B=\(width) row \(row): no logprobs captured")
                if assertNearTie {
                    #expect(acceptable, "B=\(width) row \(row): divergence is not a near-tie swap \(divergence.evidence)")
                }
                if !acceptable { item["divergenceDetail"] = divergence.detail(reference.logprobs, run.logprobs) }
                if acceptable { isolated += 1 }
                if divergence.isIdentical { exact += 1 }
                if row == cancelled {
                    #expect(run.completionTokens < reference.completionTokens)
                } else {
                    #expect(run.error == nil, "B=\(width) row \(row): \(run.error ?? "")")
                }
                rowEvidence.append(item)
            }
            let maxRows = rows.compactMap { runs[$0]?.engine?.batchRowsMax }.max() ?? 0
            if width >= 2 {
                // Real batching, from the engine's own counters.
                #expect(maxRows >= 2, "B=\(width): no step ran more than one decode row")
                #expect(decodeRows > steps / 2)
            }
            // No leaked request, KV pages, or reservations.
            #expect(after.activeRequests == 0 && after.waitingRequests == 0)
            #expect(after.kvBytesInUse == idle.kvBytesInUse)
            #expect(after.kvBytesReserved == idle.kvBytesReserved)
            widths.append([
                "width": width, "rows": rowEvidence, "cancelledRow": cancelled ?? -1,
                "isolatedRows": isolated, "identicalToB1Rows": exact, "engineSteps": steps, "engineDecodeRows": decodeRows,
                "meanDecodeRowsPerStep": steps > 0 ? Double(decodeRows) / Double(steps) : 0,
                "perRequestBatchRowsMax": maxRows,
                "maxObservedActiveRequests": observed.maxActive,
                "maxObservedKVBytesInUse": observed.maxKVInUse,
                "before": before.evidence, "after": after.evidence,
            ])
            print("LFM25-QUAL batching [\(label)] B=\(width) isolated=\(isolated)/\(rows.count) identical=\(exact) "
                + "steps=\(steps) decodeRows=\(decodeRows) batchRowsMax=\(maxRows) "
                + "maxActive=\(observed.maxActive) kvInUseAfter=\(after.kvBytesInUse) idle=\(idle.kvBytesInUse)")
        }
        evidence["widths"] = widths
        return evidence
    }
}

/// Polls the engine's capacity snapshot while a batch runs (observability
/// only; the assertions use the engine's own step counters).
final class LFM25CapacitySampler: @unchecked Sendable {
    private let slot: LFM25Slot
    private let lock = NSLock()
    private var stopped = false
    init(slot: LFM25Slot) { self.slot = slot }
    func stop() { lock.withLock { stopped = true } }
    private var isStopped: Bool { lock.withLock { stopped } }
    func run() async -> (maxActive: Int, maxKVInUse: Int) {
        var maxActive = 0
        var maxKV = 0
        while !isStopped {
            let snapshot = await slot.capacity()
            maxActive = max(maxActive, snapshot.activeRequests)
            maxKV = max(maxKV, snapshot.kvBytesInUse)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (maxActive, maxKV)
    }
}
