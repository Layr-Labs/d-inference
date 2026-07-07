// Copyright © 2026 Eigen Labs.
//
// LIVE two-model co-residency on the v2 engine (v0.7.5 §1.1 acceptance):
// the postmortem's failure shape — first engine claims the whole KV budget,
// every later model silently falls back to legacy — must be structurally
// impossible. On real weights (the two production families):
//
//   1. load gpt-oss → its engine holds the FULL fleet KV budget;
//   2. start a REAL generation on gpt-oss; WHILE it streams, load
//      gemma-4-qat → gpt-oss's grant SHRINKS to its fair share without
//      touching the in-flight stream (engine shrink semantics), and BOTH
//      slots hold live v2 bridges with Σ(grants) ≤ the fleet budget;
//   3. gpt-oss's NEXT admission respects the SHRUNK ceiling: a worst-case
//      request that fit the old grant is refused (token_budget_exhausted);
//   4. both models serve a real 1-token decode through the production
//      serving path (MultiModelBatchSchedulerEngine → bridge);
//   5. unload gemma → gpt-oss's grant grows back to the full budget.
//
// Gated like the other multi-GB suites: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA, and each checkpoint skips cleanly when absent
// from the local HF cache (LiveInferenceFixtures pattern).

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 two-model co-residency (live)", .serialized)
struct EngineV2CoResidencyLiveTests {

    static let gptossID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    static let gemmaQatID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    private static let gib: UInt64 = 1024 * 1024 * 1024

    /// Real ProviderLoop over the two production checkpoints, with an
    /// isolated runtime. Estimated sizes mirror the on-disk footprints
    /// (gpt-oss ~12.1 GiB, gemma-qat ~14.9 GiB).
    private func makeLiveLoop() throws -> (loop: ProviderLoop, runtime: EngineV2Runtime) {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: ProcessInfo.processInfo.physicalMemory / Self.gib,
                memoryAvailableGb: max(1, ProcessInfo.processInfo.physicalMemory / Self.gib - 4),
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [
                ModelInfo(
                    id: Self.gptossID, modelType: "gpt_oss",
                    sizeBytes: 13 * Self.gib, estimatedMemoryGb: 14.0),
                ModelInfo(
                    id: Self.gemmaQatID, modelType: "gemma4",
                    sizeBytes: 15 * Self.gib, estimatedMemoryGb: 17.0),
            ],
            config: ProviderConfig(
                provider: ProviderSettings(name: "coresidency-live", memoryReserveGB: 4),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        return (loop, runtime)
    }

    /// Collect a bridge stream into (text, completionTokens, error).
    private func collectBridgeStream(
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

    @Test("load B while A streams: shrink, serve both, admission ceiling, regrow")
    func coResidencyLifecycle() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled, LiveInferenceFixtures.gemmaTestsEnabled else {
            return  // env-gated (multi-GB weights)
        }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossID)
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gemmaQatID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gemmaQatID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)

        let (loop, runtime) = try makeLiveLoop()
        await loop.setEngineV2RuntimeForTesting(runtime)
        // Structured teardown: unload whatever loaded, on every exit path.
        defer {
            Task {
                await loop.unloadModel(Self.gemmaQatID)
                await loop.unloadModel(Self.gptossID)
                MLX.Memory.clearCache()
            }
        }

        // ---- 1. Load A (gpt-oss): the lone slot holds the FULL budget. ----
        try await loop.ensureModelLoaded(modelId: Self.gptossID)
        let bridgeA = try #require(await loop.slotBridgeForTesting(modelId: Self.gptossID))
        let sizingA = try #require(await loop.slotSizingForTesting(modelId: Self.gptossID))
        let reserveBytes: UInt64 = 4 * Self.gib  // memoryReserveGB above
        let grantA0 = await bridgeA.engineKVBytesCapacity()
        let budgetAlone = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        #expect(grantA0 == Int(budgetAlone), "single model must hold the FULL fleet budget")
        // Engine-truth rate for the admission-probe arithmetic below.
        #expect(sizingA.fp16KVBytesPerToken == 24_576)

        // ---- Admission probe P: worst-case KV that FITS the full grant but
        // NOT the post-shrink share. Sized between the two ceilings:
        // estimatedBytes ≈ maxTokens × 24,576 (gpt-oss sliding plateaus are
        // negligible). Probe first: it must be ADMITTED now (first token
        // arrives), then cancelled before it burns real decode time. ----
        let probeTokens = 2_500_000  // ≈ 61 GiB worst-case KV
        let probePrompt = try await tokenize("Write a very long story.", loop: loop)
        func submitProbe() async -> AsyncStream<GenerationEvent> {
            await bridgeA.submitTokenized(
                promptTokens: probePrompt,
                request: ChatCompletionRequest(
                    model: Self.gptossID,
                    messages: [ChatMessage(role: "user", content: "Write a very long story.")],
                    temperature: 0,
                    max_tokens: probeTokens),
                requestId: "probe-\(UUID().uuidString.prefix(8))")
        }
        do {
            let probe = await submitProbe()
            var admitted = false
            for await event in probe {
                switch event {
                case .chunk:
                    admitted = true
                case .info, .error:
                    break
                }
                if admitted { break }
            }
            #expect(admitted, "the worst-case probe must fit the FULL grant pre-shrink")
            // Cancel everything on the bridge (only the probe is live).
            for id in await activeIds(bridgeA) { await bridgeA.cancel(requestId: id) }
            // Drain to the terminal so its KV reservation is released.
            for await _ in probe {}
        }

        // ---- 2. Stream on A while B loads. ----
        let streamA = await bridgeA.submitTokenized(
            promptTokens: try await tokenize("Count from 1 to 30, separated by commas.", loop: loop),
            request: ChatCompletionRequest(
                model: Self.gptossID,
                messages: [
                    ChatMessage(role: "user", content: "Count from 1 to 30, separated by commas.")
                ],
                temperature: 0,
                max_tokens: 200),
            requestId: "stream-during-load")
        let collectorA = Task { await collectBridgeStream(streamA) }

        try await loop.ensureModelLoaded(modelId: Self.gemmaQatID)
        let bridgeB = try #require(await loop.slotBridgeForTesting(modelId: Self.gemmaQatID))
        let sizingB = try #require(await loop.slotSizingForTesting(modelId: Self.gemmaQatID))
        #expect(sizingB.fp16KVBytesPerToken == 20_480)

        // A's in-flight stream completes untouched across the shrink.
        let resultA = await collectorA.value
        #expect(resultA.error == nil, "A's stream must survive the shrink: \(resultA.error ?? "")")
        #expect(resultA.completion > 0)
        #expect(resultA.text.contains("10"), "greedy count should reach 10: \(resultA.text.prefix(200))")

        // ---- 3. Both grants re-sliced; Σ ≤ fleet budget; ceilings live. ----
        let grantA1 = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: reserveBytes)
        let expected = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: Self.gptossID,
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: Self.gemmaQatID,
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget)
        #expect(grantA1 == expected[Self.gptossID])
        #expect(grantB == expected[Self.gemmaQatID])
        #expect(grantA1 < grantA0)
        #expect(UInt64(grantA1) + UInt64(grantB) <= fleetBudget)
        print(
            "[co-residency] fleetBudget=\(fleetBudget / Self.gib)GiB "
                + "grantA0=\(UInt64(grantA0) / Self.gib)GiB "
                + "grantA1=\(UInt64(grantA1) / Self.gib)GiB "
                + "grantB=\(UInt64(grantB) / Self.gib)GiB")

        // ---- 4. A's NEXT admission respects the SHRUNK ceiling: the same
        // worst-case probe that was admitted pre-shrink is now REFUSED with
        // the canonical capacity error. ----
        let refusedProbe = await submitProbe()
        let refusal = await collectBridgeStream(refusedProbe)
        #expect(refusal.error?.contains("token_budget_exhausted") == true,
                "post-shrink probe must be refused, got: \(refusal.error ?? "nil")")

        // Both slots serve a REAL decode through the production path.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gemmaQatID)

        // ---- 5. Unload B: A grows back to the FULL budget. ----
        await loop.unloadModel(Self.gemmaQatID)
        let grantA2 = await bridgeA.engineKVBytesCapacity()
        let budgetAfterUnload = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        #expect(grantA2 == Int(budgetAfterUnload))
        #expect(grantA2 > grantA1)
        print("[co-residency] after unload grantA2=\(UInt64(grantA2) / Self.gib)GiB")

        // A still serves after the round trip.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)

        await loop.unloadModel(Self.gptossID)
    }

    // MARK: - Helpers

    /// Tokenize a user turn with the LOADED model's tokenizer (chat template
    /// applied) — the same shape the production submit path produces.
    private func tokenize(_ text: String, loop: ProviderLoop) async throws -> [Int] {
        let tokenizer = try await loop.resolveTokenizerForLocal(Self.gptossID)
        return try tokenizer.inner.applyChatTemplate(
            messages: [["role": "user", "content": text]],
            tools: nil, additionalContext: nil)
    }

    /// The bridge's live provider request-ids (for cancelling the probe).
    private func activeIds(_ bridge: EngineV2Bridge) async -> [String] {
        await bridge._testActiveRequestIds()
    }
}
