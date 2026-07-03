// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of the v0.7.2 Gemma 4 VLM → engine_v2
// text-model extraction, on the EXACT checkpoints production serves
// (gemma-4-26b-qat-4bit / gemma-4-26b-8bit — both ship a vision tower, so
// the provider loads them through VLMModelFactory exactly like
// `ProviderLoop.loadModelContainer`). Three stages, mirroring the prod
// serving paths:
//
//   (a) EXTRACTION + PARITY — extract the CBv2-adapted MLXLLM
//       `Gemma4TextModel` over the wrapper's weight arrays; the extraction
//       must not duplicate weights (MLX active memory grows by ~nothing),
//       and the built-in load-time parity gate must pass (each side's greedy
//       argmax sits in the other's top-5 at every probe position, max
//       |Δlogit| bounded — see EngineV2VLMTextExtraction for why token-exact
//       WRAPPER parity is structurally unattainable).
//
//   (b) V2 == LEGACY GREEDY — the SAME tokenized prompt through the REAL
//       `EngineV2` over the extracted model (via `EngineV2Bridge` +
//       `MultiModelBatchSchedulerEngine`, the production seam) must produce
//       the same greedy completion as the legacy `BatchScheduler` over the
//       SAME extracted module instance (the engine-repo v2==legacy invariant,
//       here on prod weights); the wrapper's own legacy output is logged for
//       reference.
//
//   (c) INTERLEAVE HYGIENE — a legacy VISION request (real image through the
//       wrapper's prepare/generate path) sandwiched between two identical v2
//       text decodes must not perturb the v2 output (the Qwen3.5-mrope
//       regression pattern from StartupSelfTestDecodeLiveTests: shared
//       module state corrupting the "other" path). The extracted model is a
//       separate module instance sharing only immutable weight arrays, so
//       this must hold structurally.
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

// A real, round-trip-verified 1x1 PNG (red pixel) — same fixture as
// VLMRequestInferenceTests. The Gemma4 processor upsizes it to the minimum
// patch grid, so it exercises the full vision tower cheaply.
private let interleaveTinyPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

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
        let scheduler: BatchScheduler
        let tokenizer: TokenizerHandle
        let model: any LanguageModel
        let eosTokenIds: Set<Int>
    }

    /// Load a checkpoint EXACTLY the way the provider does for a VLM slot:
    /// `VLMModelFactory` + `BatchScheduler.loadModel` (the legacy engine the
    /// slot retains for fallback + vision requests).
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

    /// Stage (a): weight-sharing extraction + the load-time parity gate.
    ///
    /// Two concerns, measured separately:
    ///   * WEIGHT-SHARING — extract with the parity gate OFF and require MLX
    ///     active memory to grow by ~nothing (skeleton construction is lazy;
    ///     `update(parameters:)` re-points at the wrapper's arrays). A second
    ///     weight COPY would show up as ≥ the model size (~14 GiB qat-4bit).
    ///     The parity gate is excluded here because its two forward passes
    ///     materialize several GiB of transient activation buffers that MLX
    ///     retains until `clearCache` — real, but not a weight copy.
    ///   * PARITY GATE — extract again with the gate ON (production default)
    ///     and require it to pass and report a bounded max |Δlogit|. Both
    ///     extractions share the same wrapper arrays, so this is not a second
    ///     copy either; the returned model is the one stages (b)/(c) use.
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
        #expect(
            growth < 1_536 * 1024 * 1024,
            Comment(
                rawValue: "extraction grew MLX active memory by \(growth) bytes "
                    + "(> 1.5 GiB) — weights were copied instead of shared"))

        // Parity gate (production default env). Returns the model stages
        // (b)/(c) run on.
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: slot.model, modelDirectory: slot.directory)
        let diff = try #require(
            extraction.parityMaxAbsLogitDiff, "parity gate did not run under the default env")
        print("[gemma-vlm-v2] \(slot.modelID) parity max |Δlogit| = \(diff), weight-share growth = \(growth) bytes")
        return extraction
    }

    /// Drive one OpenAI-shaped request through the production routing seam
    /// (`MultiModelBatchSchedulerEngine.streamChatCompletion`) over an
    /// arbitrary registry entry and join the streamed content.
    private func streamText(
        modelID: String,
        scheduler: BatchScheduler,
        tokenizer: TokenizerHandle,
        container: ModelContainer?,
        isVLM: Bool,
        modelType: String,
        bridge: EngineV2Bridge?,
        userContent: OpenAIMessageContent,
        maxTokens: Int
    ) async throws -> String {
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    modelID: .init(
                        scheduler: scheduler,
                        tokenizer: tokenizer,
                        modelType: modelType,
                        container: container,
                        isVLM: isVLM,
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

    /// Convenience: stream over the loaded VLM slot's own entry (the shape
    /// the provider registers for a Gemma 4 slot).
    private func streamText(
        slot: LoadedVLMSlot,
        bridge: EngineV2Bridge?,
        userContent: OpenAIMessageContent,
        maxTokens: Int
    ) async throws -> String {
        try await streamText(
            modelID: slot.modelID,
            scheduler: slot.scheduler,
            tokenizer: slot.tokenizer,
            container: slot.container,
            isVLM: true,
            modelType: "gemma4",
            bridge: bridge,
            userContent: userContent,
            maxTokens: maxTokens)
    }

    /// Build a LEGACY `BatchScheduler` over the EXTRACTED text model via a
    /// synthetic text-only container — the reference for the token-exact
    /// engine-equivalence check in stage (b): the real EngineV2 and the
    /// legacy BatchedEngine, run over the SAME module instance, must agree
    /// exactly on greedy decode (the engine-repo v2-vs-legacy invariant,
    /// verified here on prod weights through the provider's own seams).
    private func makeExtractedTextScheduler(
        slot: LoadedVLMSlot, extracted: Gemma4TextModel
    ) async -> BatchScheduler {
        struct NeverCalledProcessor: UserInputProcessor {
            struct NotSupported: Error {}
            func prepare(input: UserInput) async throws -> LMInput { throw NotSupported() }
        }
        // Thread the slot's EOS set into the config so the legacy scheduler
        // stops at the SAME turn-end token the v2 bridge does — otherwise the
        // token-exact comparison trips on stop config, not on decode.
        let context = ModelContext(
            configuration: ModelConfiguration(
                directory: slot.directory, eosTokenIds: slot.eosTokenIds),
            model: extracted,
            processor: NeverCalledProcessor(),
            tokenizer: slot.tokenizer.inner
        )
        let container = ModelContainer(context: context)
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(300),
            defaultMaxTokens: 256
        )
        await scheduler.loadModel(container: container, modelId: slot.modelID + "#extracted-text")
        return scheduler
    }

    /// Build the REAL production v2 engine + bridge over the extracted text
    /// model (same constructor path as `EngineV2Factory.makeProductionEngine`
    /// from the slot factory).
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

    // MARK: - qat-4bit: full pipeline (extraction, v2==legacy, interleave)

    @Test(
        "qat-4bit: extraction parity, v2==legacy greedy, vision interleave hygiene",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitFullPipeline() async throws {
        let slot = try await loadVLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024)
        let scheduler = slot.scheduler
        defer { Task { await scheduler.unloadModel() } }

        // (a) extraction + load-time parity gate + weight-sharing invariant.
        let extraction = try runExtractionStage(slot)

        // (b) engine equivalence, token-exact: the REAL EngineV2 over the
        //     extracted model must reproduce the legacy BatchedEngine over
        //     the SAME extracted module instance exactly on greedy decode.
        //     The wrapper's legacy path is compared qualitatively only —
        //     token-exact wrapper parity is structurally unattainable (bf16
        //     kernel-order noise flips near-tie MoE expert picks, and the
        //     wrapper mis-implements the checkpoint's `rope_type:
        //     "proportional"`; see EngineV2VLMTextExtraction).
        let prompt = OpenAIMessageContent.text(
            "Count from one to five as digits separated by commas.")
        let wrapperLegacyText = try await streamText(
            slot: slot, bridge: nil, userContent: prompt, maxTokens: 32)
        #expect(!wrapperLegacyText.isEmpty, "wrapper legacy text path produced no content")

        let textRefScheduler = await makeExtractedTextScheduler(
            slot: slot, extracted: extraction.model)
        let legacyExtractedText = try await streamText(
            modelID: slot.modelID,
            scheduler: textRefScheduler,
            tokenizer: slot.tokenizer,
            container: nil,
            isVLM: false,
            modelType: "gemma4_text",
            bridge: nil,
            userContent: prompt,
            maxTokens: 32)
        #expect(!legacyExtractedText.isEmpty, "extracted-model legacy path produced no content")

        let bridge = try makeBridge(slot: slot, extracted: extraction.model)
        let v2Text = try await streamText(
            slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
        print("[gemma-vlm-v2] wrapperLegacy=\(wrapperLegacyText.debugDescription)")
        print("[gemma-vlm-v2] legacyExtracted=\(legacyExtractedText.debugDescription)")
        print("[gemma-vlm-v2] v2=\(v2Text.debugDescription)")
        #expect(
            v2Text == legacyExtractedText,
            Comment(
                rawValue: "v2 greedy diverged from legacy greedy on the SAME extracted model: "
                    + "v2=\(v2Text.debugDescription) "
                    + "legacy=\(legacyExtractedText.debugDescription)"))
        await textRefScheduler.unloadModel()

        // (c) interleave hygiene: legacy VISION request between two identical
        //     v2 text decodes; the v2 output must be unchanged and the vision
        //     request must stream real content through the wrapper.
        let visionContent = try await streamText(
            slot: slot, bridge: bridge,
            userContent: .parts([
                .text("What color is this image? Answer with one word."),
                .imageURL(interleaveTinyPNGDataURI),
            ]),
            maxTokens: 16)
        #expect(!visionContent.isEmpty, "vision request through the legacy path produced no content")

        let v2TextAfterVision = try await streamText(
            slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
        #expect(
            v2TextAfterVision == v2Text,
            Comment(
                rawValue: "v2 text decode changed after an interleaved vision request: "
                    + "before=\(v2Text.debugDescription) after=\(v2TextAfterVision.debugDescription)"))

        await bridge.shutdown()
    }

    // MARK: - 8bit: extraction parity + v2==legacy greedy

    @Test(
        "8bit: extraction parity and v2==legacy greedy",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func eightBitExtractionAndGreedyParity() async throws {
        let slot = try await loadVLMSlot(
            modelID: Self.eightBitModelID, budgetBytes: 64 * 1024 * 1024 * 1024)
        let scheduler = slot.scheduler
        defer { Task { await scheduler.unloadModel() } }

        let extraction = try runExtractionStage(slot)

        let prompt = OpenAIMessageContent.text(
            "Count from one to five as digits separated by commas.")
        let wrapperLegacyText = try await streamText(
            slot: slot, bridge: nil, userContent: prompt, maxTokens: 32)
        #expect(!wrapperLegacyText.isEmpty, "wrapper legacy text path produced no content")

        let textRefScheduler = await makeExtractedTextScheduler(
            slot: slot, extracted: extraction.model)
        let legacyExtractedText = try await streamText(
            modelID: slot.modelID,
            scheduler: textRefScheduler,
            tokenizer: slot.tokenizer,
            container: nil,
            isVLM: false,
            modelType: "gemma4_text",
            bridge: nil,
            userContent: prompt,
            maxTokens: 32)
        #expect(!legacyExtractedText.isEmpty, "extracted-model legacy path produced no content")

        let bridge = try makeBridge(slot: slot, extracted: extraction.model)
        let v2Text = try await streamText(
            slot: slot, bridge: bridge, userContent: prompt, maxTokens: 32)
        print("[gemma-vlm-v2] wrapperLegacy=\(wrapperLegacyText.debugDescription)")
        print("[gemma-vlm-v2] legacyExtracted=\(legacyExtractedText.debugDescription)")
        print("[gemma-vlm-v2] v2=\(v2Text.debugDescription)")
        #expect(
            v2Text == legacyExtractedText,
            Comment(
                rawValue: "v2 greedy diverged from legacy greedy on the SAME extracted model: "
                    + "v2=\(v2Text.debugDescription) "
                    + "legacy=\(legacyExtractedText.debugDescription)"))
        await textRefScheduler.unloadModel()

        await bridge.shutdown()
    }
}
