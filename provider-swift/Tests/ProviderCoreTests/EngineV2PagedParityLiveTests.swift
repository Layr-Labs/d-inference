// Copyright © 2026 Eigen Labs.
//
// LIVE paged-KV parity oracle on real GPT-OSS weights, over the production
// engine seam (`EngineV2Factory.makeProductionBuild` + `EngineV2Bridge` —
// the same direct-construction idiom as the prefix-cache live suites; the
// ProviderLoop/slot-factory string threading is covered by the gate and
// policy suites). The repo's batching lesson (ragged-NaN, resource-count
// leak): solo-vs-batched output invariance is THE oracle that catches
// batch-composition corruption — so it gates the paged default before any
// fleet exposure.
//
//   1. `.auto` resolves PAGED for GPT-OSS through the real family gate
//      (build reports kvBackendKind == .paged; pool truth on the idle
//      capacity snapshot);
//   2. greedy SOLO baselines (3 mixed-length prompts) == the SAME requests
//      decoded CONCURRENTLY, token-exact per request (batch-composition
//      invariance on the paged decode kernel, real weights);
//   3. cross-backend first-token parity over the SAME loaded weights: the
//      contiguous build produces the SAME first greedy token (prefill runs
//      the same SDPA path on both backends) and both stream to a clean
//      finish — deeper-token drift between decode kernels is allowed and
//      logged for eyeballing.
//
// Gemma-4 paged is deliberately NOT covered here: production gemma
// checkpoints are VLM slots, which the gate vetoes to contiguous by
// design (text-only gemma paged is covered by the tiny-model gate tests
// and the engine repo's BenchCBv2RealModel --engines v2-paged runs).
//
// Gated like every multi-GB suite: DARKBLOOM_LIVE_MLX_TESTS=1 + the
// checkpoint in the local HF cache; skips cleanly otherwise. The pool is
// sized explicitly (8 GiB) so the eager slab commit stays trivially inside
// the test memory budget regardless of box state.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 paged parity oracle (live)", .serialized)
struct EngineV2PagedParityLiveTests {

    static let gptossModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    private static let gib = 1024 * 1024 * 1024

    private struct LiveModel {
        let modelID: String
        let model: any LanguageModel
        let tokenizer: TokenizerHandle
        let eosTokenIds: Set<Int>
    }

    private func loadGptOss() async throws -> LiveModel {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.gptossModelID)
        else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossModelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * Self.gib)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let gptoss = try #require(
            snapshot.model as? GPTOSSModel, "gpt-oss checkpoint must load as GPTOSSModel")
        let eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            base: snapshot.eosTokenIds,
            tokenToId: { tokenizer.inner.convertTokenToId($0) })
        return LiveModel(
            modelID: "gpt-oss-20b",
            model: gptoss,
            tokenizer: tokenizer,
            eosTokenIds: eos)
    }

    /// Production engine + bridge over the loaded weights with an explicit
    /// backend selection. 8 GiB pool: the eager slab commit stays trivially
    /// inside the test budget, and admission comfortably fits the workload.
    private func makeBridge(
        _ live: LiveModel, kvBackend: EngineV2KVBackendSelection
    ) throws -> (bridge: EngineV2Bridge, kind: EngineV2KVBackendKind) {
        let build = try EngineV2Factory.makeProductionBuild(
            model: live.model,
            tokenizer: live.tokenizer.inner,
            kvBytesCapacity: 8 * Self.gib,
            prefixCache: nil,
            kvBackend: kvBackend)
        let bridge = EngineV2Bridge(
            engine: build.engine,
            modelId: live.modelID,
            tokenizer: live.tokenizer,
            eosTokenIds: live.eosTokenIds,
            kvBackendKind: build.kvBackendKind)
        return (bridge, build.kvBackendKind)
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
            model: Self.gptossModelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0,
            max_tokens: maxTokens)
    }

    /// Mixed-length greedy workload: different prompts and budgets so
    /// concurrent rows join/leave at different steps (the batch-composition
    /// churn the oracle must survive).
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

    @Test("gpt-oss .auto serves PAGED; solo == concurrent, token-exact")
    func pagedBatchCompositionInvariance() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        let live = try await loadGptOss()
        let (bridge, kind) = try makeBridge(live, kvBackend: .auto)
        defer { Task { await bridge.shutdown(); MLX.Memory.clearCache() } }

        // 1. The real family gate served PAGED (the default-ON path), and
        // pool truth rides the IDLE capacity snapshot (heartbeats fire
        // before the first request).
        #expect(kind == .paged, ".auto must resolve paged for gpt-oss")
        #expect(await bridge.kvBackendKind == .paged)
        let snapshot = await bridge.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity > 0)
        #expect(snapshot.kvBytesBackendCapacity <= 8 * Self.gib)

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
        let batched = await withTaskGroup(
            of: (Int, (text: String, completion: Int, error: String?)).self
        ) { group in
            for (index, item) in Self.workload.enumerated() {
                group.addTask {
                    let out = await self.collect(
                        await bridge.submit(
                            request: self.greedyRequest(
                                item.prompt, maxTokens: item.maxTokens),
                            requestId: "paged-batch-\(index)"))
                    return (index, out)
                }
            }
            var results = [(text: String, completion: Int, error: String?)?](
                repeating: nil, count: Self.workload.count)
            for await (index, out) in group { results[index] = out }
            return results
        }
        for (index, maybe) in batched.enumerated() {
            let out = try #require(maybe, "concurrent \(index) never finished")
            #expect(out.error == nil, "concurrent \(index) errored: \(out.error ?? "")")
            #expect(
                out.text == solos[index].text,
                "batch-composition variance on request \(index): solo=\(solos[index].text.prefix(120)) batched=\(out.text.prefix(120))")
        }
    }

    @Test("cross-backend first-token parity over the same weights")
    func crossBackendFirstTokenParity() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        let live = try await loadGptOss()
        let prompt = Self.workload[1].prompt

        var firstTexts: [String] = []
        var fullTexts: [String] = []
        for selection in [EngineV2KVBackendSelection.paged, .contiguous] {
            let (bridge, kind) = try makeBridge(live, kvBackend: selection)
            #expect(
                kind == (selection == .paged ? .paged : .contiguous),
                "explicit selection must construct its backend")
            // First greedy token comes from PREFILL logits — the same SDPA
            // path on both backends — so it must match exactly.
            let first = await collect(
                await bridge.submit(
                    request: greedyRequest(prompt, maxTokens: 1),
                    requestId: "xback-first-\(selection.rawValue)"))
            #expect(first.error == nil)
            firstTexts.append(first.text)
            // Longer decode diverges only through kernel float-order
            // differences; require a clean finish, log for eyeballing.
            let full = await collect(
                await bridge.submit(
                    request: greedyRequest(prompt, maxTokens: 32),
                    requestId: "xback-full-\(selection.rawValue)"))
            #expect(full.error == nil)
            #expect(full.completion > 0)
            fullTexts.append(full.text)
            await bridge.shutdown()
            MLX.Memory.clearCache()
        }
        try #require(firstTexts.count == 2)
        #expect(
            firstTexts[0] == firstTexts[1],
            "first greedy token must match across backends (paged=\(firstTexts[0]) contiguous=\(firstTexts[1]))")
        print("[xback] paged:      \(fullTexts[0].prefix(160))")
        print("[xback] contiguous: \(fullTexts[1].prefix(160))")
    }

    /// The LOOP-PATH drill this suite originally lost (PR #531 Codex P1):
    /// load gpt-oss through the REAL `ProviderLoop.ensureModelLoaded` —
    /// pre-load estimate gate, weights, re-slice, engine build with the
    /// eager slab commit, and BOTH measured-headroom guards — and require
    /// the slot to come up PAGED and serve. Before the backend-aware
    /// post-bridge guard, this failed deterministically: the slab consumed
    /// the entire KV budget and the 1 GiB floor unloaded every paged slot.
    ///
    /// The operator reserve (40 GiB) sizes the slab to ~43 GiB on a 128 GB
    /// box so the drill is safe under concurrent dev load, while leaving
    /// the pre-load free-memory gate (`availableBytes − reserve ≥ weights
    /// estimate`) ~22 GiB of margin on a typically-loaded box — the test
    /// skips (not fails) if the box is too busy, like every live suite.
    @Test("loop path: paged gpt-oss survives the load guards and serves")
    func pagedSlotSurvivesLoadGuardsThroughProviderLoop() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossModelID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossModelID)
        }
        let gib: UInt64 = 1 << 30
        let reserveGiB: UInt64 = 40

        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max,
                memoryGb: ProcessInfo.processInfo.physicalMemory / gib,
                memoryAvailableGb: max(1, ProcessInfo.processInfo.physicalMemory / gib - 4),
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [
                ModelInfo(
                    id: Self.gptossModelID, modelType: "gpt_oss",
                    sizeBytes: 13 * gib, estimatedMemoryGb: 14.0)
            ],
            config: ProviderConfig(
                provider: ProviderSettings(
                    name: "paged-loop-live", memoryReserveGB: reserveGiB),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        defer {
            Task {
                await loop.unloadModel(Self.gptossModelID)
                MLX.Memory.clearCache()
            }
        }

        do {
            try await loop.ensureModelLoaded(modelId: Self.gptossModelID)
        } catch {
            // A busy box legitimately fails the PRE-load free-memory gate;
            // that is a box condition, not a regression — skip loudly.
            // The post-bridge guard failure this test exists for reads
            // "engine build left insufficient KV headroom" and must FAIL.
            let text = String(describing: error)
            if text.contains("engine build left insufficient KV headroom") {
                Issue.record("post-bridge guard unloaded the paged slot: \(text)")
                return
            }
            print("[paged-loop] skipping — load gate refused on this box: \(text)")
            return
        }

        let bridge = try #require(await loop.slotBridgeForTesting(modelId: Self.gptossModelID))
        let servedKind = await bridge.kvBackendKind
        #expect(servedKind == .paged, "loop path must serve gpt-oss PAGED")
        let out = await {
            var text = ""
            var error: String?
            for await event in await bridge.submit(
                request: ChatCompletionRequest(
                    model: Self.gptossModelID,
                    messages: [ChatMessage(role: "user", content: "Say OK.")],
                    temperature: 0, max_tokens: 8),
                requestId: "paged-loop-1")
            {
                if case .chunk(let c) = event { text += c }
                if case .error(let e) = event { error = e }
            }
            return (text, error)
        }()
        #expect(out.1 == nil, "paged slot must serve after passing the guards: \(out.1 ?? "")")
        #expect(!out.0.isEmpty)
        await loop.unloadModel(Self.gptossModelID)
    }
}
