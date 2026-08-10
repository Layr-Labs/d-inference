// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of direct Gemma 4 VLM text-tower ownership
// on the exact qat-4bit / 8bit checkpoints production serves. Both load via
// `VLMModelFactory`, exactly like `ProviderLoop.loadModelContainer`.
//
//   (a) DIRECT OWNERSHIP + MEMORY — resolving the CBv2 serving model returns
//       the wrapper's exact `textModel` object and does not construct or
//       materialize a second tower.
//   (b) V2 SERVE — that owned model serves a text request through the real
//       production bridge/routing seam with deterministic greedy output.
//
// Vision-through-v2 image/video behavior and interleave hygiene remain pinned
// by GemmaVLMVisionEngineV2LiveTests and GemmaVLMVideoEngineV2LiveTests.
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

@Suite("Gemma 4 VLM direct text tower (live)", .serialized)
struct GemmaVLMEngineV2LiveTests {

    /// The two production Gemma 4 checkpoints (coordinator catalog ids
    /// `gemma-4-26b-qat-4bit` / `gemma-4-26b-8bit`).
    static let qat4bitModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    static let eightBitModelID = LiveInferenceFixtures.gemmaModelID  // ...-8bit

    // MARK: - Shared harness

    private struct LoadedVLMSlot {
        let modelID: String
        let container: ModelContainer
        let tokenizer: TokenizerHandle
        let model: any LanguageModel
        let eosTokenIds: Set<Int>
    }

    /// Load a checkpoint exactly as the provider does for a VLM slot:
    /// `VLMModelFactory`, retaining the wrapper that owns both towers.
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

    /// Resolve the production serving model and prove it is the wrapper-owned
    /// object. Merely exposing/resolving the tower must not add meaningful MLX
    /// residency; a second checkpoint tower would exceed this allowance by
    /// many GiB.
    private func runDirectTowerStage(
        _ slot: LoadedVLMSlot
    ) throws -> Gemma4TextModel {
        let wrapper = try #require(
            slot.model as? MLXVLM.Gemma4,
            "production Gemma VLM checkpoint must load as MLXVLM.Gemma4")
        MLX.Memory.clearCache()
        let activeBefore = MLX.GPU.activeMemory
        let owned = wrapper.textModel
        let serving = try EngineV2Factory.directServingModel(
            model: wrapper, isVLM: true)
        let textModel = try #require(serving as? Gemma4TextModel)

        #expect(ObjectIdentifier(owned) == ObjectIdentifier(textModel))
        #expect(wrapper.textModel === owned)
        let growth = max(0, MLX.GPU.activeMemory - activeBefore)
        let allowance = 64 * 1024 * 1024
        #expect(
            growth < allowance,
            Comment(
                rawValue: "direct tower resolution grew MLX active memory by "
                    + "\(growth) bytes (> 64 MiB), suggesting duplicate residency"))
        print(
            "[gemma-vlm-v2] \(slot.modelID) direct tower identity passed; "
                + "resolution growth = \(growth) bytes")
        return textModel
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

    /// Build the real production v2 engine + bridge over the VLM-owned text
    /// model, matching `EngineV2SlotFactory.makeProductionBridge`.
    private func makeBridge(
        slot: LoadedVLMSlot, textModel: Gemma4TextModel
    ) throws -> EngineV2Bridge {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: textModel,
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
        slot: LoadedVLMSlot, textModel: Gemma4TextModel,
        _ body: (EngineV2Bridge) async throws -> Void
    ) async throws {
        let bridge = try makeBridge(slot: slot, textModel: textModel)
        do {
            try await body(bridge)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    /// Direct identity/memory proof followed by deterministic production serve.
    private func runDirectTowerAndV2Serve(_ slot: LoadedVLMSlot) async throws {
        let textModel = try runDirectTowerStage(slot)

        try await withBridge(slot: slot, textModel: textModel) { bridge in
            let prompt = OpenAIMessageContent.text(
                "Count from one to five as digits separated by commas.")
            let v2Text = try await streamText(
                slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
            #expect(!v2Text.isEmpty, "v2 text serve over the VLM-owned model produced no content")

            let v2TextAgain = try await streamText(
                slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
            print("[gemma-vlm-v2] v2=\(v2Text.debugDescription)")
            #expect(
                v2TextAgain == v2Text,
                Comment(
                    rawValue: "v2 greedy decode over the VLM-owned model is "
                        + "non-deterministic: \(v2Text.debugDescription) vs "
                        + "\(v2TextAgain.debugDescription)"))
        }
    }

    // MARK: - qat-4bit: direct ownership + v2 serve

    @Test(
        "qat-4bit: direct tower identity, memory, and v2 serve determinism",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitDirectTowerAndV2Serve() async throws {
        try await withLoadedVLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            try await runDirectTowerAndV2Serve(slot)
        }
    }

    // MARK: - 8bit: direct ownership + v2 serve

    @Test(
        "8bit: direct tower identity, memory, and v2 serve determinism",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func eightBitDirectTowerAndV2Serve() async throws {
        try await withLoadedVLMSlot(
            modelID: Self.eightBitModelID, budgetBytes: 64 * 1024 * 1024 * 1024
        ) { slot in
            try await runDirectTowerAndV2Serve(slot)
        }
    }
}
