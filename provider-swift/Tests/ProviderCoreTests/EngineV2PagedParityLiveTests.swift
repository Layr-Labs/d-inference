// Copyright © 2026 Eigen Labs.
//
// LIVE paged-KV parity oracle on real GPT-OSS weights, through the REAL
// provider stack (ProviderLoop → EngineV2SlotFactory → makeProductionBuild
// auto-gate → PagedKVBackend). The repo's batching lesson (ragged-NaN,
// resource-count leak): solo-vs-batched output invariance is THE oracle
// that catches batch-composition corruption — so it gates the paged
// default before any fleet exposure.
//
//   1. `auto` default: gpt-oss loads PAGED through the production gate
//      (bridge reports kvBackendKind == .paged) with the pool committed
//      at construction;
//   2. greedy SOLO baselines (3 mixed-length prompts) == the SAME requests
//      decoded CONCURRENTLY, token-exact per request (batch-composition
//      invariance on the paged decode kernel, real weights);
//   3. cross-backend first-token parity: a contiguous rebuild of the same
//      slot produces the SAME first greedy token (prefill runs the same
//      SDPA path on both backends), and streams to a clean finish —
//      deeper-token drift between kernels is allowed and logged;
//   4. the paged slot serves a repeat submit of the same prompt cleanly
//      (SSD prefix tier active by default — adoption path exercised; a
//      HIT is not asserted, gpt-oss's adoption bound owns that policy).
//
// Gemma-4 paged is deliberately NOT covered here: production gemma
// checkpoints are VLM slots, which the gate vetoes to contiguous by
// design. Real-weights gemma-paged coverage lives in the engine repo's
// BenchCBv2RealModel (`--engines v2-paged`, text-model extraction) and
// the perf-gate report.
//
// Gated like every multi-GB suite: DARKBLOOM_LIVE_MLX_TESTS=1 + the
// checkpoint present in the local HF cache; skips cleanly otherwise.
// The operator reserve is set HIGH (96 GiB) so the lone slot's KV grant —
// which the paged pool physically commits via `materializeSlabs` — stays
// small (~GBs) under concurrent-suite memory pressure.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 paged parity oracle (live)", .serialized)
struct EngineV2PagedParityLiveTests {

    static let gptossID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    private static let gib: UInt64 = 1024 * 1024 * 1024
    /// High reserve ⇒ small lone-slot KV grant ⇒ small committed pool.
    private static let reserveGiB: UInt64 = 96

    private func makeLiveLoop(
        kvBackend: String
    ) throws -> (loop: ProviderLoop, runtime: EngineV2Runtime) {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max,
                memoryGb: ProcessInfo.processInfo.physicalMemory / Self.gib,
                memoryAvailableGb: max(
                    1, ProcessInfo.processInfo.physicalMemory / Self.gib - 4),
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [
                ModelInfo(
                    id: Self.gptossID, modelType: "gpt_oss",
                    sizeBytes: 13 * Self.gib, estimatedMemoryGb: 14.0)
            ],
            config: ProviderConfig(
                provider: ProviderSettings(
                    name: "paged-parity-live", memoryReserveGB: Self.reserveGiB),
                backend: BackendSettings(
                    idleTimeoutMins: 0, maxModelSlots: 1,
                    engineV2KVBackend: kvBackend),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        return (loop, runtime)
    }

    private func collect(
        _ stream: AsyncStream<GenerationEvent>
    ) async -> (text: String, completion: Int, error: String?) {
        var text = ""
        var completion = 0
        var error: String?
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info(_, let completionTokens, _, _): completion = completionTokens
            case .error(let message): error = message
            }
        }
        return (text, completion, error)
    }

    private func greedyRequest(_ prompt: String, maxTokens: Int) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: Self.gptossID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0,
            max_tokens: maxTokens)
    }

    /// Mixed-length greedy workload: short, medium, and long-ish prompts
    /// with different budgets so concurrent rows join/leave at different
    /// steps (the batch-composition churn the oracle must survive).
    private static let workload: [(prompt: String, maxTokens: Int)] = [
        ("List three prime numbers.", 24),
        ("Explain, in two sentences, why the sky appears blue on a clear day.", 40),
        (
            "Summarize the tradeoffs between contiguous and paged key-value cache "
                + "layouts for transformer inference on unified-memory hardware, "
                + "covering memory waste, admission, and kernel dispatch overhead.",
            56
        ),
    ]

    @Test("gpt-oss auto-serves PAGED; solo == concurrent, token-exact")
    func pagedBatchCompositionInvariance() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * 1024 * 1024 * 1024)

        let (loop, runtime) = try makeLiveLoop(kvBackend: "auto")
        await loop.setEngineV2RuntimeForTesting(runtime)
        defer {
            Task {
                await loop.unloadModel(Self.gptossID)
                MLX.Memory.clearCache()
            }
        }

        try await loop.ensureModelLoaded(modelId: Self.gptossID)
        let bridge = try #require(await loop.slotBridgeForTesting(modelId: Self.gptossID))

        // 1. The production `auto` gate served PAGED (the default-ON path).
        #expect(await bridge.kvBackendKind == .paged, "auto must resolve paged for gpt-oss")
        let snapshot = await bridge.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity > 0, "pool truth must ride the idle snapshot")

        // 2a. Solo greedy baselines, one at a time.
        var solos: [(text: String, completion: Int)] = []
        for (index, item) in Self.workload.enumerated() {
            let out = await collect(
                await bridge.submit(
                    request: greedyRequest(item.prompt, maxTokens: item.maxTokens),
                    requestId: "paged-solo-\(index)"))
            #expect(out.error == nil, "solo \(index) errored: \(out.error ?? "")")
            #expect(out.completion > 0, "solo \(index) produced no tokens")
            solos.append((out.text, out.completion))
        }

        // 2b. The SAME requests, concurrent. Greedy decode on the paged
        // kernel must be batch-composition invariant: identical text per
        // request regardless of batchmates (the ragged-NaN-class oracle).
        let streams = await withTaskGroup(
            of: (Int, (text: String, completion: Int, error: String?)).self
        ) { group in
            for (index, item) in Self.workload.enumerated() {
                group.addTask {
                    let out = await self.collect(
                        await bridge.submit(
                            request: self.greedyRequest(item.prompt, maxTokens: item.maxTokens),
                            requestId: "paged-batch-\(index)"))
                    return (index, out)
                }
            }
            var results = [(text: String, completion: Int, error: String?)?](
                repeating: nil, count: Self.workload.count)
            for await (index, out) in group { results[index] = out }
            return results.compactMap { $0 }
        }
        try #require(streams.count == Self.workload.count)
        for (index, out) in streams.enumerated() {
            #expect(out.error == nil, "concurrent \(index) errored: \(out.error ?? "")")
            #expect(
                out.text == solos[index].text,
                "batch-composition variance on request \(index): solo=\(solos[index].text.prefix(120)) batched=\(out.text.prefix(120))")
        }

        // 4. Repeat submit of the longest prompt: the default SSD prefix
        // tier's lookup/adopt path runs against paged sequence state and
        // must finish cleanly (hit-or-miss is the tier's own policy).
        let repeated = await collect(
            await bridge.submit(
                request: greedyRequest(Self.workload[2].prompt, maxTokens: 24),
                requestId: "paged-repeat-0"))
        #expect(repeated.error == nil, "repeat submit errored: \(repeated.error ?? "")")
    }

    @Test("cross-backend first-token parity (prefill path is shared)")
    func crossBackendFirstTokenParity() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * 1024 * 1024 * 1024)

        let prompt = Self.workload[1].prompt
        var firstTexts: [String] = []
        var fullTexts: [String] = []
        for backend in ["paged", "contiguous"] {
            let (loop, runtime) = try makeLiveLoop(kvBackend: backend)
            await loop.setEngineV2RuntimeForTesting(runtime)
            try await loop.ensureModelLoaded(modelId: Self.gptossID)
            let bridge = try #require(
                await loop.slotBridgeForTesting(modelId: Self.gptossID))
            #expect(
                await bridge.kvBackendKind
                    == (backend == "paged" ? .paged : .contiguous))
            // First greedy token: produced by PREFILL logits — the same
            // SDPA path on both backends — so it must match exactly.
            let first = await collect(
                await bridge.submit(
                    request: greedyRequest(prompt, maxTokens: 1),
                    requestId: "xback-first-\(backend)"))
            #expect(first.error == nil)
            firstTexts.append(first.text)
            // Longer decode diverges only through kernel float-order
            // differences; require a clean finish, log for eyeballing.
            let full = await collect(
                await bridge.submit(
                    request: greedyRequest(prompt, maxTokens: 32),
                    requestId: "xback-full-\(backend)"))
            #expect(full.error == nil)
            #expect(full.completion > 0)
            fullTexts.append(full.text)
            await loop.unloadModel(Self.gptossID)
            MLX.Memory.clearCache()
        }
        try #require(firstTexts.count == 2)
        #expect(
            firstTexts[0] == firstTexts[1],
            "first greedy token must match across backends (paged=\(firstTexts[0]) contiguous=\(firstTexts[1]))")
        print("[xback] paged:      \(fullTexts[0].prefix(160))")
        print("[xback] contiguous: \(fullTexts[1].prefix(160))")
    }
}
