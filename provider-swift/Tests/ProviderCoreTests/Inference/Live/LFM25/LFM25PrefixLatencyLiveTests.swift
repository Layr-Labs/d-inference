// Copyright © 2026 Eigen Labs.
//
// LIVE prefix-cache LATENCY measurement on the real LFM2.5-24B-A2B artifact
// through the production bundle and the SSD complete-checkpoint tier
// (isolated test root, in-memory ephemeral key: no persistent-key flag, no
// key loader, so nothing can reach the Keychain or the product cache root).
//
// For each checkpoint storage precision ("balanced" = product default,
// "native" = exact) and each shared prefix of 2K/4K/8K tokens, per sample:
//   cold   Q1 and Q2 with the cache off (uncached prefill),
//   donor  Q1 with the cache on and the coordinator's repeated-prefix hint at
//          the shared boundary, then the time until its checkpoint write lands,
//   warm   Q2 (same prefix, different question) restoring that checkpoint.
// Each sample uses a fresh prefix, so no measurement reuses another's
// checkpoint. Numbers only (content hashes, never text) go to
// DARKBLOOM_LFM25_QUAL_OUT/latency.json. Correctness is asserted only as
// "the warm request restored the shared prefix"; whether warm is faster is
// REPORTED, never asserted, because timing is machine- and build-dependent.
// Meaningful latency needs a release build (`swift build -c release
// --build-tests`); a debug build's unspecialized codec dominates.

import Foundation
import MLX
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("LFM2.5-24B-A2B prefix-cache latency (live)", .serialized,
       .enabled(if: LFM25Qual.selected("latency")))
struct LFM25PrefixLatencyLiveTests {
    private static let maxTokens = 8
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static var prefixLengths: [Int] {
        let raw = environment["DARKBLOOM_LFM25_LATENCY_PREFIXES"] ?? "2048,4096,8192"
        return raw.split(separator: ",").compactMap { Int($0) }
    }

    private static var samples: Int { Int(environment["DARKBLOOM_LFM25_LATENCY_SAMPLES"] ?? "") ?? 3 }

    private static var precisions: [String] {
        (environment["DARKBLOOM_LFM25_LATENCY_PRECISIONS"] ?? "balanced,native")
            .split(separator: ",").map(String.init)
    }

    @Test("cold vs warm-hit TTFT and checkpoint donation latency at 2K/4K/8K shared prefixes")
    func prefixLatency() async throws {
        let model = try await LFM25Loaded.load()
        var results: [String: Any] = [
            "loadSeconds": model.loadSeconds, "maxTokens": Self.maxTokens,
            "prefixLengths": Self.prefixLengths, "samples": Self.samples,
        ]
        for (index, precision) in Self.precisions.enumerated() {
            results[precision] = try await measure(model, precision: precision, saltBase: 10_000 * (index + 1))
        }
        LFM25Qual.writeEvidence("latency", results)
    }

    private func measure(_ model: LFM25Loaded, precision: String, saltBase: Int) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-qual-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root, checkpointPrecision: precision)
        let store = try #require(slot.store)
        #expect(store.usesEphemeralKey)
        var out: [String: Any] = ["storeLayout": store.config.backendLayout,
                                  "minEffectiveTokens": store.config.minEffectiveTokens]

        // Kernel/pipeline warm-up (excluded): one uncached request.
        let warmup = model.encode(LFM25Qual.chatML(LFM25Qual.records(0 ..< 40, salt: saltBase - 1)))
        _ = await TimedRun.run(slot, tokens: warmup, maxTokens: Self.maxTokens, id: "warmup-\(precision)",
                               cacheEnabled: false)

        var rows: [[String: Any]] = []
        for length in Self.prefixLengths {
            for sample in 0 ..< Self.samples {
                let salt = saltBase + length / 16 + sample * 7
                let prefix = try sharedPrefix(model, tokens: length, salt: salt)
                let q1 = prefix + model.encode(" Which warehouse logged record 42? Answer briefly.<|im_end|>\n<|im_start|>assistant\n<think>")
                let q2 = prefix + model.encode(" Which part is most common? Answer briefly.<|im_end|>\n<|im_start|>assistant\n<think>")
                let tag = "\(precision)-\(length)-\(sample)"

                let coldQ1 = await TimedRun.run(slot, tokens: q1, maxTokens: Self.maxTokens, id: "cold1-\(tag)",
                                                cacheEnabled: false)
                let coldQ2 = await TimedRun.run(slot, tokens: q2, maxTokens: Self.maxTokens, id: "cold2-\(tag)",
                                                cacheEnabled: false)
                let before = store.stats()
                let donor = await TimedRun.run(
                    slot, tokens: q1, maxTokens: Self.maxTokens, id: "donor-\(tag)",
                    donationDemand: SSDCheckpointDonationDemand(repeatedPrefixTokens: length))
                let landed = await waitForWrite(store, above: before.filesWritten, after: donor.end)
                await store.activity.waitUntilDrained()
                let drained = Date().timeIntervalSince(donor.end)
                let afterDonation = store.stats()
                let warm = await TimedRun.run(slot, tokens: q2, maxTokens: Self.maxTokens, id: "warm-\(tag)")
                let afterWarm = store.stats()
                #expect(donor.error == nil && warm.error == nil && coldQ1.error == nil && coldQ2.error == nil)
                #expect(afterDonation.filesWritten > before.filesWritten, "\(tag): donor must write a checkpoint")
                #expect((warm.prefillTokensSaved ?? 0) > 0, "\(tag): warm must restore the shared prefix")
                #expect((warm.prefillTokensSaved ?? 0) <= length)
                let row: [String: Any] = [
                    "precision": precision, "prefixTokens": length, "sample": sample,
                    "q1Tokens": q1.count, "q2Tokens": q2.count,
                    "coldQ1": coldQ1.evidence, "coldQ2": coldQ2.evidence, "donor": donor.evidence, "warm": warm.evidence,
                    "donationLandedAfterDonorEndSeconds": landed.map { round3($0) } ?? -1,
                    "donationDrainedAfterDonorEndSeconds": round3(drained),
                    "donationFilesWritten": afterDonation.filesWritten - before.filesWritten,
                    "donationBytesWritten": afterDonation.bytesWritten - before.bytesWritten,
                    "warmFilesRead": afterWarm.filesRead - afterDonation.filesRead,
                    "warmStageConsumptions": afterWarm.stageConsumptions - afterDonation.stageConsumptions,
                    "warmEqualsColdQ2": warm.textSHA == coldQ2.textSHA,
                    "ttftSpeedup": coldQ2.ttft > 0 && warm.ttft > 0 ? round3(coldQ2.ttft / warm.ttft) : -1,
                ]
                print("LFM25-LATENCY [\(tag)] coldTTFT=\(round3(coldQ2.ttft)) warmTTFT=\(round3(warm.ttft)) "
                    + "saved=\(warm.prefillTokensSaved ?? -1) donorTTFT=\(round3(donor.ttft)) "
                    + "donorTotal=\(round3(donor.seconds)) coldQ1Total=\(round3(coldQ1.seconds)) "
                    + "writeLandedAfterEnd=\(landed.map { round3($0) } ?? -1) drained=\(round3(drained)) "
                    + "bytes=\(afterDonation.bytesWritten - before.bytesWritten)")
                rows.append(row)
            }
        }
        out["rows"] = rows
        out["store"] = store.stats().evidence
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()
        return out
    }

    /// Exactly `tokens` prompt tokens of synthetic records in a chat turn, so
    /// the shared boundary is the same for both questions.
    private func sharedPrefix(_ model: LFM25Loaded, tokens: Int, salt: Int) throws -> [Int] {
        let encoded = model.encode(
            "<|startoftext|><|im_start|>user\n" + LFM25Qual.records(0 ..< (tokens / 12 + 16), salt: salt))
        try #require(encoded.count >= tokens)
        return Array(encoded.prefix(tokens))
    }

    /// Seconds from the donor's terminal event until its write lands, or nil.
    private func waitForWrite(_ store: SSDHybridCheckpointStore, above previous: Int, after end: Date) async -> Double? {
        let deadline = Date().addingTimeInterval(120)
        while store.stats().filesWritten <= previous, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return store.stats().filesWritten > previous ? Date().timeIntervalSince(end) : nil
    }
}

private func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

/// One request timed from submission to the first streamed chunk and to the
/// terminal event, plus the engine's own phase timestamps.
private struct TimedRun {
    var ttft = -1.0
    var seconds = 0.0
    var end = Date()
    var textSHA = ""
    var chunks = 0
    var completionTokens = 0
    var error: String?
    var prefillTokensSaved: Int?
    var engine: EngineProfile?

    var evidence: [String: Any] {
        var out: [String: Any] = [
            "ttftSeconds": round3(ttft), "seconds": round3(seconds), "textSHA": textSHA, "chunks": chunks,
            "completionTokens": completionTokens, "error": error ?? "nil",
            "prefillTokensSaved": prefillTokensSaved ?? -1,
        ]
        if let e = engine {
            func ms(_ ns: Int64?) -> Double { ns.map { Double($0) / 1e6 } ?? -1 }
            out["engineMs"] = [
                "admitted": ms(e.admittedNs), "kvAllocated": ms(e.kvAllocatedNs),
                "prefillFirstLaunch": ms(e.prefillFirstLaunchNs), "promptComputed": ms(e.promptComputedNs),
                "firstToken": ms(e.firstTokenNs), "finished": ms(e.finishedNs),
                "prefixLookup": ms(e.prefixLookupNs), "prefixAdoption": ms(e.prefixAdoptionNs),
                "prefillChunks": Double(e.prefillChunks ?? -1),
            ]
        }
        return out
    }

    static func run(
        _ slot: LFM25Slot, tokens: [Int], maxTokens: Int, id: String, cacheEnabled: Bool = true,
        donationDemand: SSDCheckpointDonationDemand? = nil
    ) async -> TimedRun {
        var run = TimedRun()
        let profile = RequestProfileBuilder()
        let signal = EngineV2RequestUsageSignal()
        var text = ""
        let start = Date()
        do {
            let stream = try await slot.bridge.submitTokenized(
                promptTokens: tokens, request: try LFM25Qual.request(maxTokens: maxTokens),
                requestId: id, cacheScope: "", cacheEnabled: cacheEnabled,
                logprobsChannel: nil, usageSignal: signal, donationDemand: donationDemand,
                firstContentDeadline: nil, profile: profile)
            for await event in stream {
                switch event {
                case .chunk(let chunk):
                    if run.ttft < 0 { run.ttft = Date().timeIntervalSince(start) }
                    text += chunk
                    run.chunks += 1
                case .info(_, let completion, _, _):
                    run.completionTokens = completion
                case .error(let message):
                    run.error = message
                case .terminal(_, let message, _, let completion):
                    run.error = message
                    run.completionTokens = completion
                }
            }
        } catch {
            run.error = String(describing: error)
        }
        run.end = Date()
        run.seconds = run.end.timeIntervalSince(start)
        run.textSHA = LFM25Qual.sha(text)
        run.engine = profile.wireObject().engine
        run.prefillTokensSaved = signal.prefixCachePrefillTokensSaved
        return run
    }
}
