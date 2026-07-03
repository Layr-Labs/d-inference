// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of v0.7.4 VISION-THROUGH-ENGINE_V2 on the
// EXACT checkpoints production serves (gemma-4-26b-qat-4bit /
// gemma-4-26b-8bit). Self-contained harness — deliberately independent of
// `GemmaVLMEngineV2LiveTests` (that file is owned by the concurrent 0.7.3
// hotfix; nothing here touches it). Stages:
//
//   (a) VISION THROUGH V2 — a real image request routed through the v2
//       engine: `EngineV2VisionPrefill` runs the wrapper's vision tower +
//       projector and the engine splices the embeddings at the placeholder
//       spans (CBv2 multimodal prefill). Asserted:
//         * the request actually took the v2 path (bridge admit count grew,
//           zero fallback WARNs recorded);
//         * greedy determinism (same image + prompt twice ⇒ identical);
//         * the embeddings STEER the output (a red image and a blue image
//           with the same prompt produce different completions — if spans/
//           embeddings were dropped, both would collapse to the same
//           text-only answer);
//         * comparison against the legacy wrapper path's greedy output for
//           the same input is LOGGED, and asserted only qualitatively:
//           token-exactness is NOT required, mirroring the v0.7.2
//           parity-gate reasoning — the extracted model implements the
//           checkpoint's declared `rope_type: "proportional"` correctly
//           while the wrapper deviates (plus bf16 kernel-order noise flips
//           near-tie MoE expert picks), so wrapper-vs-extracted divergence
//           is expected and documented, not a regression.
//
//   (b) INTERLEAVE HYGIENE — text(v2) / legacy-vision / text(v2) and
//       text(v2) / vision(v2) / text(v2): neither a legacy wrapper vision
//       request (forced by omitting the bridge for that one request) nor a
//       vision-through-v2 request may perturb a v2 text decode (span masks
//       / spliced embeddings must leave no residue in the engine's caches
//       — the Qwen3.5-mrope-class regression pattern).
//
// Teardown here is structured (unload/shutdown awaited on every exit path)
// so this suite never overlaps residency with other serialized live runs.
//
// Gated like the other multi-GB Gemma tests: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA, and each checkpoint is skipped cleanly when
// not in the local HF cache. Run live suites one at a time (--filter) —
// distinct suites are parallel by default and two 26B loads won't coexist.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

// 16x16 solid-color PNGs: same prompt, different pixels — completions must
// differ if the vision embeddings actually reach the model.
private let visionSolidRedPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mO4IyJCEmIY"
    + "1TCqYfhqAAACcQQQFd0BdQAAAABJRU5ErkJggg=="
private let visionSolidBluePNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mMQ0bhDEmIY"
    + "1TCqYfhqAAAUJBgQCtUO5gAAAABJRU5ErkJggg=="

/// Thread-safe recorder for the vision plumbing's fallback WARNs.
private final class VisionLiveFallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func append(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
}

@Suite("Gemma 4 VLM vision through engine_v2 (live)", .serialized)
struct GemmaVLMVisionEngineV2LiveTests {

    /// The two production Gemma 4 checkpoints (coordinator catalog ids
    /// `gemma-4-26b-qat-4bit` / `gemma-4-26b-8bit`).
    static let qat4bitModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    static let eightBitModelID = LiveInferenceFixtures.gemmaModelID  // ...-8bit

    // MARK: - Harness (self-contained; mirrors the provider's VLM slot shape)

    private struct LoadedVLMSlot {
        let modelID: String
        let directory: URL
        let container: ModelContainer
        let scheduler: BatchScheduler
        let tokenizer: TokenizerHandle
        let model: any LanguageModel
        let eosTokenIds: Set<Int>
    }

    /// Load a checkpoint EXACTLY the way the provider does for a VLM slot:
    /// `VLMModelFactory` + `BatchScheduler.loadModel` (the legacy engine the
    /// slot retains for fallback + video requests).
    private func loadVLMSlot(modelID: String, budgetBytes: Int) async throws -> LoadedVLMSlot {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: budgetBytes)

        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(300),
            defaultMaxTokens: 256
        )
        await scheduler.loadModel(container: container, modelId: modelID)

        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        return LoadedVLMSlot(
            modelID: modelID,
            directory: directory,
            container: container,
            scheduler: scheduler,
            tokenizer: tokenizer,
            model: snapshot.model,
            eosTokenIds: snapshot.eosTokenIds
        )
    }

    /// Structured slot lifecycle: the multi-GB residency is AWAITED out of
    /// memory on every exit path before the next serialized test loads.
    private func withVLMSlot(
        modelID: String, budgetBytes: Int,
        _ body: (LoadedVLMSlot) async throws -> Void
    ) async throws {
        let slot = try await loadVLMSlot(modelID: modelID, budgetBytes: budgetBytes)
        do {
            try await body(slot)
        } catch {
            await slot.scheduler.unloadModel()
            MLX.Memory.clearCache()
            throw error
        }
        await slot.scheduler.unloadModel()
        MLX.Memory.clearCache()
    }

    /// Structured bridge lifecycle: `shutdown()` (engine drain + pump
    /// teardown) awaited on every exit path.
    private func withBridge(
        slot: LoadedVLMSlot,
        _ body: (EngineV2Bridge) async throws -> Void
    ) async throws {
        // Weight-sharing extraction with the production parity gate ON —
        // the same construction `ProviderLoop.makeEngineV2BridgeForSlot`
        // performs for an allowlisted VLM slot.
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: slot.model, modelDirectory: slot.directory)
        let engine = try EngineV2Factory.makeProductionEngine(
            model: extraction.model,
            tokenizer: slot.tokenizer.inner,
            kvBytesCapacity: 4 * 1024 * 1024 * 1024
        )
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: slot.modelID,
            tokenizer: slot.tokenizer,
            eosTokenIds: slot.eosTokenIds
        )
        do {
            try await body(bridge)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    /// Drive one OpenAI-shaped request through the production routing seam
    /// (`MultiModelBatchSchedulerEngine.streamChatCompletion`) over the
    /// slot's registry entry and join the streamed content. `bridge: nil`
    /// forces the legacy wrapper path for that request.
    private func streamText(
        slot: LoadedVLMSlot,
        bridge: EngineV2Bridge?,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        visionPlumbing: EngineV2VisionPlumbing? = nil
    ) async throws -> String {
        // Destructure the Sendable pieces — `LoadedVLMSlot.model` (the raw
        // module handle) must not cross into the @Sendable registry closure.
        let modelID = slot.modelID
        let scheduler = slot.scheduler
        let tokenizer = slot.tokenizer
        let container = slot.container
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    modelID: .init(
                        scheduler: scheduler,
                        tokenizer: tokenizer,
                        modelType: "gemma4",
                        container: container,
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            },
            defaultMaxTokens: 256,
            engineV2Vision: visionPlumbing
        )
        let request = OpenAIChatCompletionRequest(
            model: slot.modelID,
            messages: [OpenAIChatMessage(role: .user, content: userContent)],
            temperature: 0,
            maxTokens: maxTokens
        )
        var content = ""
        for try await event in try await engine.streamChatCompletion(request: request) {
            if case .content(let text) = event {
                content += text
            }
        }
        return content
    }

    /// Stream a vision request through v2 and REQUIRE it took the v2 path:
    /// zero fallback WARNs and a bridge admit for this request.
    private func streamVisionThroughV2(
        slot: LoadedVLMSlot,
        bridge: EngineV2Bridge,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        stage: String
    ) async throws -> String {
        let recorder = VisionLiveFallbackRecorder()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { container, request in
                try await EngineV2VisionPrefill.prepare(container: container, request: request)
            },
            emitTelemetry: { recorder.append($0) }
        )
        let admitsBefore = await bridge._testCounters().admits
        let content = try await streamText(
            slot: slot, bridge: bridge, userContent: userContent,
            maxTokens: maxTokens, visionPlumbing: plumbing)
        let admitsAfter = await bridge._testCounters().admits
        #expect(
            recorder.events.isEmpty,
            Comment(
                rawValue: "[\(stage)] vision request fell back to legacy: "
                    + "\(recorder.events.map(\.message))"))
        #expect(
            admitsAfter == admitsBefore + 1,
            Comment(
                rawValue: "[\(stage)] bridge admits \(admitsBefore) → \(admitsAfter); "
                    + "the vision request did not reach the v2 engine"))
        return content
    }

    // MARK: - qat-4bit: vision through v2 + interleave hygiene

    @Test(
        "qat-4bit: vision through v2 — steering, determinism, legacy comparison, interleave",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitVisionThroughV2() async throws {
        try await withVLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            try await withBridge(slot: slot) { bridge in
                let textPrompt = OpenAIMessageContent.text(
                    "Count from one to five as digits separated by commas.")
                let colorPrompt = "What color is this image? Answer with one word."

                // v2 text baseline for the interleave assertions.
                let v2Text = try await streamText(
                    slot: slot, bridge: bridge, userContent: textPrompt, maxTokens: 32)
                #expect(!v2Text.isEmpty, "v2 text baseline produced no content")

                // (a) VISION THROUGH V2: real embeddings at real spans.
                let redContent = try await streamVisionThroughV2(
                    slot: slot, bridge: bridge,
                    userContent: .parts([
                        .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                    ]),
                    maxTokens: 16, stage: "red")
                #expect(!redContent.isEmpty, "v2 vision request produced no content")

                // Greedy determinism: identical input ⇒ identical output.
                let redContentAgain = try await streamVisionThroughV2(
                    slot: slot, bridge: bridge,
                    userContent: .parts([
                        .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                    ]),
                    maxTokens: 16, stage: "red2")
                #expect(
                    redContentAgain == redContent,
                    Comment(
                        rawValue: "v2 vision greedy decode is non-deterministic: "
                            + "\(redContent.debugDescription) vs \(redContentAgain.debugDescription)"))

                // Embedding steering: different pixels, same prompt ⇒ the
                // completions must differ.
                let blueContent = try await streamVisionThroughV2(
                    slot: slot, bridge: bridge,
                    userContent: .parts([
                        .text(colorPrompt), .imageURL(visionSolidBluePNGDataURI),
                    ]),
                    maxTokens: 16, stage: "blue")
                #expect(!blueContent.isEmpty, "v2 vision request (blue) produced no content")
                #expect(
                    blueContent != redContent,
                    Comment(
                        rawValue: "red and blue images produced IDENTICAL v2 completions "
                            + "(\(redContent.debugDescription)) — vision embeddings are not "
                            + "reaching the model"))

                // Legacy-vs-v2 for the same input: logged; asserted only
                // qualitatively (see the file header for the RoPE reasoning).
                let legacyRedContent = try await streamText(
                    slot: slot, bridge: nil,
                    userContent: .parts([
                        .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                    ]),
                    maxTokens: 16)
                print(
                    "[gemma-vlm-vision-v2] red: v2=\(redContent.debugDescription) "
                        + "legacy=\(legacyRedContent.debugDescription) "
                        + (redContent == legacyRedContent
                            ? "(token-exact)" : "(diverged — expected, RoPE)"))
                print("[gemma-vlm-vision-v2] blue: v2=\(blueContent.debugDescription)")
                #expect(!legacyRedContent.isEmpty, "legacy vision reference produced no content")

                // (b) INTERLEAVE HYGIENE. The legacy vision request above
                // already ran between v2 decodes; assert the v2 text decode
                // is unchanged after BOTH interleave kinds.
                let v2TextAfterLegacyVision = try await streamText(
                    slot: slot, bridge: bridge, userContent: textPrompt, maxTokens: 32)
                #expect(
                    v2TextAfterLegacyVision == v2Text,
                    Comment(
                        rawValue: "v2 text decode changed after an interleaved legacy vision "
                            + "request: before=\(v2Text.debugDescription) "
                            + "after=\(v2TextAfterLegacyVision.debugDescription)"))

                _ = try await streamVisionThroughV2(
                    slot: slot, bridge: bridge,
                    userContent: .parts([
                        .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                    ]),
                    maxTokens: 16, stage: "interleave")
                let v2TextAfterV2Vision = try await streamText(
                    slot: slot, bridge: bridge, userContent: textPrompt, maxTokens: 32)
                #expect(
                    v2TextAfterV2Vision == v2Text,
                    Comment(
                        rawValue: "v2 text decode changed after an interleaved v2 vision "
                            + "request: before=\(v2Text.debugDescription) "
                            + "after=\(v2TextAfterV2Vision.debugDescription)"))
            }
        }
    }

    // MARK: - 8bit: vision through v2

    @Test(
        "8bit: vision through v2 — coherent, on the v2 path",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func eightBitVisionThroughV2() async throws {
        try await withVLMSlot(
            modelID: Self.eightBitModelID, budgetBytes: 64 * 1024 * 1024 * 1024
        ) { slot in
            try await withBridge(slot: slot) { bridge in
                let redContent = try await streamVisionThroughV2(
                    slot: slot, bridge: bridge,
                    userContent: .parts([
                        .text("What color is this image? Answer with one word."),
                        .imageURL(visionSolidRedPNGDataURI),
                    ]),
                    maxTokens: 16, stage: "8bit.red")
                #expect(!redContent.isEmpty, "v2 vision request produced no content")
                print("[gemma-vlm-vision-v2] 8bit red: v2=\(redContent.debugDescription)")
            }
        }
    }
}
