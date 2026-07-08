// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of the v0.7.2 Gemma 4 VLM → engine_v2
// text-model extraction, on the EXACT checkpoints production serves
// (gemma-4-26b-qat-4bit / gemma-4-26b-8bit — both ship a vision tower, so
// the provider loads them through VLMModelFactory exactly like
// `ProviderLoop.loadModelContainer`). Two stages, mirroring the prod
// serving path (updated for the v0.7.5 ONE-ENGINE release):
//
//   (a) EXTRACTION + PARITY — extract the CBv2-adapted MLXLLM
//       `Gemma4TextModel` over the wrapper's weight arrays; the extraction
//       must not duplicate weights (MLX active memory grows by ~nothing),
//       and the built-in load-time parity gate must pass (each side's greedy
//       argmax sits in the other's top-5 at every probe position, max
//       |Δlogit| bounded — see EngineV2VLMTextExtraction for why token-exact
//       WRAPPER parity is structurally unattainable).
//
//   (b) V2 SERVE — the extracted model must serve a text request through
//       the REAL production seam (`EngineV2Bridge` +
//       `MultiModelBatchSchedulerEngine.streamChatCompletion`, the exact
//       engine construction the slot factory performs after its own
//       extraction): non-empty greedy output, byte-identical across two
//       identical submissions.
//
// DELETED with the legacy engine (v0.7.5 one-engine): the "v2 == legacy
// greedy" stage (its reference — a legacy `BatchScheduler` run over the
// same extracted module — no longer exists; the engine-repo v2-vs-legacy
// invariant it verified died with the legacy engine) and the legacy-vision
// interleave stage (media on a slot without a v2 bridge now throws the
// fail-loud "no serving engine for media" error instead of serving via the
// wrapper; vision-through-v2 interleave hygiene is pinned by
// GemmaVLMVisionEngineV2LiveTests).
//
// Gated like the other multi-GB Gemma tests: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA, and each checkpoint is skipped cleanly when not
// in the local HF cache.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Gemma 4 VLM engine_v2 extraction (live)", .serialized)
struct GemmaVLMEngineV2LiveTests {

    /// The two production Gemma 4 checkpoints (coordinator catalog ids
    /// `gemma-4-26b-qat-4bit` / `gemma-4-26b-8bit`).
    static let qat4bitModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    static let eightBitModelID = LiveInferenceFixtures.gemmaModelID  // ...-8bit

    // MARK: - Shared harness

    private struct LoadedVLMSlot {
        let modelID: String
        let directory: URL
        let container: ModelContainer
        let tokenizer: TokenizerHandle
        let model: any LanguageModel
        let eosTokenIds: Set<Int>
    }

    /// Load a checkpoint EXACTLY the way the provider does for a VLM slot:
    /// `VLMModelFactory` (the container the vision tower lives in). Loaded
    /// BY HAND rather than through `LiveInferenceFixtures.loadBridge`
    /// because stage (a) must run the extraction ITSELF, on the raw wrapper
    /// handle, with clean before/after memory readings — the fixture's
    /// production bridge would run the extraction internally first.
    private func loadVLMSlot(modelID: String, budgetBytes: Int) async throws -> LoadedVLMSlot {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        #expect(
            ProviderLoop.modelIsVLM(at: directory),
            "prod Gemma 4 checkpoints are VLM builds — if this fails the whole premise changed")
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: budgetBytes)

        let container = try await VLMModelFactory.shared.loadContainer(
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
        return LoadedVLMSlot(
            modelID: modelID,
            directory: directory,
            container: container,
            tokenizer: tokenizer,
            model: snapshot.model,
            eosTokenIds: snapshot.eosTokenIds
        )
    }

    /// Load a VLM slot, run `body`, and trim the MLX pool on every exit
    /// path. The multi-GB residency itself dies with `slot` (the container
    /// is the only retainer — the legacy scheduler that used to co-own it
    /// is deleted); the pool trim keeps the NEXT serialized test's load
    /// from stacking on this one's buffer garbage.
    private func withLoadedVLMSlot(
        modelID: String, budgetBytes: Int,
        _ body: (LoadedVLMSlot) async throws -> Void
    ) async throws {
        let slot = try await loadVLMSlot(modelID: modelID, budgetBytes: budgetBytes)
        do {
            try await body(slot)
        } catch {
            MLX.Memory.clearCache()
            throw error
        }
        MLX.Memory.clearCache()
    }

    /// Stage (a): weight-sharing extraction + the load-time parity gate.
    ///
    /// Two concerns, measured separately:
    ///   * WEIGHT-SHARING — extract with the parity gate OFF and require MLX
    ///     active memory to grow by no more than a small tolerance. Skeleton
    ///     construction is lazy; `update(parameters:)` re-points at the
    ///     wrapper's arrays; nothing multi-GiB may be retained (the removed
    ///     SwitchGLU fused gate+up cache was the v0.7.2 black hole — a
    ///     second weight copy would show up as ≥ the model size).
    ///   * PARITY GATE — extract again with the gate ON (production default)
    ///     and require it to pass and report a bounded max |Δlogit|. Both
    ///     extractions share the same wrapper arrays, so this is not a second
    ///     copy either; the returned model is the one stage (b) serves.
    private func runExtractionStage(
        _ slot: LoadedVLMSlot
    ) throws -> EngineV2VLMTextExtraction.Extraction {
        // Weight-sharing invariant (parity gate off).
        MLX.Memory.clearCache()
        let activeBefore = MLX.GPU.activeMemory
        let noParity = try EngineV2VLMTextExtraction.extractTextModel(
            from: slot.model, modelDirectory: slot.directory,
            environment: ["DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK": "0"])
        #expect(noParity.parityMaxAbsLogitDiff == nil)
        let growth = max(0, MLX.GPU.activeMemory - activeBefore)
        let allowance = 1_536 * 1024 * 1024
        #expect(
            growth < allowance,
            Comment(
                rawValue: "extraction grew MLX active memory by \(growth) bytes "
                    + "(> 1.5 GiB) — weights or a module cache were duplicated "
                    + "instead of shared"))

        // Parity gate (production default env). Returns the model stage
        // (b) runs on.
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: slot.model, modelDirectory: slot.directory)
        let diff = try #require(
            extraction.parityMaxAbsLogitDiff, "parity gate did not run under the default env")
        print(
            "[gemma-vlm-v2] \(slot.modelID) parity max |Δlogit| = \(diff), "
                + "weight-share growth = \(growth) bytes")
        return extraction
    }

    /// Drive one OpenAI-shaped text request through the production routing
    /// seam (`MultiModelBatchSchedulerEngine.streamChatCompletion`) over
    /// the slot's one-engine registry entry and join the streamed content.
    private func streamText(
        slot: LoadedVLMSlot,
        bridge: EngineV2Bridge,
        userContent: OpenAIMessageContent,
        maxTokens: Int
    ) async throws -> String {
        // Destructure the Sendable pieces — `LoadedVLMSlot.model` (the raw
        // module handle) must not cross into the @Sendable registry closure.
        let modelID = slot.modelID
        let tokenizer = slot.tokenizer
        let container = slot.container
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    modelID: .init(
                        tokenizer: tokenizer,
                        modelType: "gemma4",
                        container: container,
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            },
            defaultMaxTokens: 256
        )
        let request = OpenAIChatCompletionRequest(
            model: modelID,
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

    /// Build the REAL production v2 engine + bridge over the extracted text
    /// model — the same construction `EngineV2SlotFactory.makeProductionBridge`
    /// performs right after ITS extraction, so stage (b) serves through the
    /// exact one-engine seam production uses.
    private func makeBridge(
        slot: LoadedVLMSlot, extracted: Gemma4TextModel
    ) throws -> EngineV2Bridge {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: extracted,
            tokenizer: slot.tokenizer.inner,
            kvBytesCapacity: 4 * 1024 * 1024 * 1024
        )
        return EngineV2Bridge(
            engine: engine,
            modelId: slot.modelID,
            tokenizer: slot.tokenizer,
            eosTokenIds: slot.eosTokenIds
        )
    }

    /// Structured bridge lifecycle: `shutdown()` (engine drain + pump
    /// teardown) awaited on every exit path.
    private func withBridge(
        slot: LoadedVLMSlot, extracted: Gemma4TextModel,
        _ body: (EngineV2Bridge) async throws -> Void
    ) async throws {
        let bridge = try makeBridge(slot: slot, extracted: extracted)
        do {
            try await body(bridge)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    /// Stages (a)+(b) for one checkpoint: measured extraction + parity
    /// gate, then greedy serve determinism through the production seam.
    private func runExtractionAndV2Serve(_ slot: LoadedVLMSlot) async throws {
        // (a) extraction + load-time parity gate + weight-sharing invariant.
        let extraction = try runExtractionStage(slot)

        // (b) v2 serve: the extracted model, behind the real EngineV2
        //     bridge, must produce non-empty greedy output through the
        //     production routing seam — and byte-identical output for two
        //     identical submissions (greedy decode is deterministic).
        try await withBridge(slot: slot, extracted: extraction.model) { bridge in
            let prompt = OpenAIMessageContent.text(
                "Count from one to five as digits separated by commas.")
            let v2Text = try await streamText(
                slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
            #expect(!v2Text.isEmpty, "v2 text serve over the extracted model produced no content")

            let v2TextAgain = try await streamText(
                slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
            print("[gemma-vlm-v2] v2=\(v2Text.debugDescription)")
            #expect(
                v2TextAgain == v2Text,
                Comment(
                    rawValue: "v2 greedy decode over the extracted model is "
                        + "non-deterministic: \(v2Text.debugDescription) vs "
                        + "\(v2TextAgain.debugDescription)"))
        }
    }

    // MARK: - qat-4bit: extraction parity + v2 serve

    @Test(
        "qat-4bit: extraction parity and v2 serve determinism",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitExtractionAndV2Serve() async throws {
        try await withLoadedVLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            try await runExtractionAndV2Serve(slot)
        }
    }

    // MARK: - 8bit: extraction parity + v2 serve

    @Test(
        "8bit: extraction parity and v2 serve determinism",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func eightBitExtractionAndV2Serve() async throws {
        try await withLoadedVLMSlot(
            modelID: Self.eightBitModelID, budgetBytes: 64 * 1024 * 1024 * 1024
        ) { slot in
            try await runExtractionAndV2Serve(slot)
        }
    }
}
