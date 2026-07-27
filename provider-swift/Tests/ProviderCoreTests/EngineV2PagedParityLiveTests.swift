// Copyright © 2026 Eigen Labs.
//
// LIVE paged-KV parity oracle on real GPT-OSS weights, over the production
// engine seam (`EngineV2Factory.makeProductionBuild` + `EngineV2Bridge` —
// the same direct-construction idiom as the prefix-cache live suites; the
// ProviderLoop/slot-factory string threading is covered by the gate and
// policy suites). The repo's batching lesson (ragged-NaN, resource-count
// leak): solo-vs-batched output invariance is THE oracle that catches
// batch-composition corruption — so it gates explicit paged canaries before
// any future default reconsideration.
//
//   1. explicit `.paged` resolves PAGED for GPT-OSS
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
// Gemma-4 (VLM) paged IS covered here — see the two gemma arms at the end
// of the suite. An earlier revision excluded it on the premise that
// production gemma checkpoints "are VLM slots, which the gate vetoes to
// contiguous by design". That premise is FALSE: the VLM veto in
// `EngineV2KVBackendPolicy.applySlotVetoes` fires only when the paged cache
// does NOT vouch for multimodal span masks, and
// `PagedLayerCache.honorsSpanMaskContextsByConstruction == true` makes the
// veto inert — so gemma-4 VLM slots build and serve PAGED in production
// under `.auto` exactly like every other model, and a live suite that never
// exercised that was gating a fiction. What the gemma arms deliberately do
// NOT assert is cross-backend token equality: gemma-4's paged-vs-contiguous
// greedy divergence is known and ACCEPTED (8.85% teacher-forced
// disagreement, floor-gated separately in PagedTeacherForcedAgreementTests),
// so the assertable properties for this model are batch-composition
// invariance WITHIN the paged backend and serve-liveness through the real
// ProviderLoop load gates.
//
// Gated like every multi-GB suite: DARKBLOOM_LIVE_MLX_TESTS=1 + the
// checkpoint in the local HF cache; skips cleanly otherwise. The logical
// grant is 8 GiB; the physical pool is independently capped by production
// policy.
//
// MEMORY: the suite is `.serialized` and the gemma arms are declared AFTER
// the gpt-oss arms on purpose — the two checkpoints (~12 GiB + ~15 GiB)
// must never be resident concurrently within this suite; a live full-suite
// run already peaks around 30.5 GiB with other suites in parallel.

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
    /// backend selection and an 8 GiB logical grant.
    private func makeBridge(
        _ live: LiveModel, kvBackend: EngineV2KVBackendSelection
    ) throws -> (bridge: EngineV2Bridge, kind: EngineV2KVBackendKind) {
        let build = try EngineV2Factory.makeProductionBuild(
            model: live.model,
            tokenizer: live.tokenizer.inner,
            kvBytesCapacity: 8 * Self.gib,
            // The fleet's cap, not a test-local number: a parity arm sized
            // differently from production measures a different engine.
            maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent),
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
            case .terminal(_, let message, _, _): error = message
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

    /// Triage for a loop-gate arm's `ensureModelLoaded` failure. Exactly ONE
    /// failure shape is an environmental skip: the PRE-load free-memory gate
    /// (`evictUntilAvailable`) refusing because this box is busy — an
    /// `InferenceError.modelLoadFailed` carrying the gate's
    /// "Insufficient memory (X GB free, need Y GB) …" message. Everything
    /// else reaching this catch IS a load-path regression the loop gates
    /// exist to expose — explicit-paged refusal (the policy REFUSES instead
    /// of degrading for an explicit `.paged` selection), VLM extraction or
    /// engine-construction breakage, an invalid model directory, the
    /// post-bridge headroom guard unloading a fresh paged slot — and must
    /// fail the test, not return green.
    private func triageLoopGateLoadFailure(_ error: Error, arm: String) {
        if case InferenceError.modelLoadFailed(let message) = error,
            message.hasPrefix("Insufficient memory (")
        {
            print("[\(arm)] skipping — pre-load free-memory gate refused on this busy box: \(message)")
            return
        }
        Issue.record(
            "\(arm): ensureModelLoaded failed with a non-memory-pressure error — a load-path regression, not a busy box: \(String(describing: error))")
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

    @Test("explicit paged GPT-OSS: solo == concurrent, token-exact")
    func pagedBatchCompositionInvariance() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        let live = try await loadGptOss()
        let (bridge, kind) = try makeBridge(live, kvBackend: .paged)
        defer { Task { await bridge.shutdown(); MLX.Memory.clearCache() } }

        // 1. The explicit canary gate served PAGED, and
        // pool truth rides the IDLE capacity snapshot (heartbeats fire
        // before the first request).
        #expect(kind == .paged, "explicit paged must resolve for eligible gpt-oss")
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
    /// independently-capped eager slab commit, and BOTH measured-headroom
    /// guards — and require the slot to come up PAGED and serve. Startup
    /// preload and cold first-request loads share this exact construction
    /// path.
    ///
    /// The operator reserve keeps the live drill safe under concurrent
    /// developer load. Physical capacity no longer scales with the remaining
    /// logical grant; production policy caps it from useful context demand,
    /// live headroom, machine size, and Metal buffer limits.
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
                backend: BackendSettings(
                    idleTimeoutMins: 0,
                    maxModelSlots: 1,
                    engineV2KVBackend: "paged"),
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
            // Only the pre-load free-memory refusal skips; every other load
            // failure (including the post-bridge headroom guard) records an
            // Issue and fails. See triageLoopGateLoadFailure.
            triageLoopGateLoadFailure(error, arm: "paged-loop")
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

    // MARK: - Gemma-4 (VLM) arms — declared last; see the MEMORY note above.

    static let gemmaModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    private func gemmaGreedyRequest(_ prompt: String, maxTokens: Int) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: Self.gemmaModelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0,
            max_tokens: maxTokens)
    }

    /// Batch-composition invariance on the model the header used to claim
    /// could not serve paged. Cross-backend token equality is NOT asserted
    /// (known, accepted divergence — see the header); what a VLM gemma slot
    /// must still deliver on the paged backend is the ragged-NaN-class
    /// oracle: each request's greedy output byte-identical whether it
    /// decoded alone or with batchmates.
    ///
    /// Built through `LiveInferenceFixtures.loadBridge` (the production
    /// `EngineV2SlotFactory.makeProductionBridge` construction, VLM text
    /// extraction included) with an explicit "paged" selection — which
    /// REFUSES rather than degrades, so reaching the assertions at all
    /// proves construction; the `kvBackendKind` check pins it against a
    /// future revival of the VLM veto silently seating contiguous.
    @Test("explicit paged gemma-4 (VLM): solo == concurrent, token-exact")
    func gemmaPagedBatchCompositionInvariance() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        let loaded = try await LiveInferenceFixtures.loadBridge(
            modelID: Self.gemmaModelID,
            maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent),
            memoryBudgetBytes: 48 * Self.gib,
            kvBackendConfig: "paged")
        let bridge = loaded.bridge

        // Only non-throwing #expects from here on, so control always reaches
        // the deterministic shutdown below and the next (serialized) test
        // never overlaps this model's residency.
        #expect(
            await bridge.kvBackendKind == .paged,
            "explicit paged must construct for a VLM gemma-4 slot — the span-mask veto is inert (PagedLayerCache.honorsSpanMaskContextsByConstruction)")

        var solos: [(text: String, completion: Int)] = []
        for (index, item) in Self.workload.enumerated() {
            let out = await collect(
                await bridge.submit(
                    request: gemmaGreedyRequest(item.prompt, maxTokens: item.maxTokens),
                    requestId: "gemma-paged-solo-\(index)"))
            #expect(out.error == nil, "gemma solo \(index) errored: \(out.error ?? "")")
            #expect(out.completion > 0, "gemma solo \(index) produced no tokens")
            solos.append((out.text, out.completion))
        }

        let batched = await withTaskGroup(
            of: (Int, (text: String, completion: Int, error: String?)).self
        ) { group in
            for (index, item) in Self.workload.enumerated() {
                group.addTask {
                    let out = await self.collect(
                        await bridge.submit(
                            request: self.gemmaGreedyRequest(
                                item.prompt, maxTokens: item.maxTokens),
                            requestId: "gemma-paged-batch-\(index)"))
                    return (index, out)
                }
            }
            var results = [(text: String, completion: Int, error: String?)?](
                repeating: nil, count: Self.workload.count)
            for await (index, out) in group { results[index] = out }
            return results
        }
        for (index, maybe) in batched.enumerated() {
            guard let out = maybe else {
                Issue.record("gemma concurrent \(index) never finished")
                continue
            }
            #expect(out.error == nil, "gemma concurrent \(index) errored: \(out.error ?? "")")
            #expect(
                out.text == solos[index].text,
                "gemma batch-composition variance on request \(index): solo=\(solos[index].text.prefix(120)) batched=\(out.text.prefix(120))")
        }

        await bridge.shutdown()
        MLX.Memory.clearCache()
    }

    /// Serve-liveness through the REAL `ProviderLoop.ensureModelLoaded`
    /// gates for the gemma-4 VLM checkpoint — the same loop-path drill the
    /// gpt-oss arm runs, on the model whose production posture (VLM slot,
    /// paged under `.auto`) this suite previously never exercised.
    @Test("loop path: paged gemma-4 (VLM) survives the load guards and serves")
    func gemmaPagedSlotSurvivesLoadGuardsThroughProviderLoop() async throws {
        guard LiveInferenceFixtures.liveTestsEnabled else { return }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gemmaModelID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gemmaModelID)
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
                    id: Self.gemmaModelID, modelType: "gemma4",
                    sizeBytes: 15 * gib, estimatedMemoryGb: 16.0)
            ],
            config: ProviderConfig(
                provider: ProviderSettings(
                    name: "gemma-paged-loop-live", memoryReserveGB: reserveGiB),
                backend: BackendSettings(
                    idleTimeoutMins: 0,
                    maxModelSlots: 1,
                    engineV2KVBackend: "paged"),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        defer {
            Task {
                await loop.unloadModel(Self.gemmaModelID)
                MLX.Memory.clearCache()
            }
        }

        do {
            try await loop.ensureModelLoaded(modelId: Self.gemmaModelID)
        } catch {
            // Same triage as the gpt-oss arm: only the pre-load free-memory
            // refusal skips; explicit-paged refusal, VLM extraction failure,
            // engine-construction breakage, an invalid model dir, and the
            // post-bridge headroom guard all FAIL. See
            // triageLoopGateLoadFailure.
            triageLoopGateLoadFailure(error, arm: "gemma-paged-loop")
            return
        }

        let bridge = try #require(await loop.slotBridgeForTesting(modelId: Self.gemmaModelID))
        let servedKind = await bridge.kvBackendKind
        #expect(
            servedKind == .paged,
            "loop path must serve VLM gemma-4 PAGED — the span-mask veto is inert by construction")
        let out = await {
            var text = ""
            var error: String?
            for await event in await bridge.submit(
                request: ChatCompletionRequest(
                    model: Self.gemmaModelID,
                    messages: [ChatMessage(role: "user", content: "Say OK.")],
                    temperature: 0, max_tokens: 8),
                requestId: "gemma-paged-loop-1")
            {
                if case .chunk(let c) = event { text += c }
                if case .error(let e) = event { error = e }
            }
            return (text, error)
        }()
        #expect(out.1 == nil, "paged gemma slot must serve after passing the guards: \(out.1 ?? "")")
        #expect(!out.0.isEmpty)
        await loop.unloadModel(Self.gemmaModelID)
    }
}
