// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of v0.7.5 VISION-THROUGH-ENGINE_V2 on the
// EXACT checkpoints production serves (gemma-4-26b-qat-4bit /
// gemma-4-26b-8bit), updated for the v0.7.5 ONE-ENGINE release: the legacy
// `BatchScheduler` (and its wrapper vision stream) is deleted, so every
// slot serves through the production `EngineV2Bridge` built by
// `EngineV2SlotFactory.makeProductionBridge` — which is exactly what the
// `LiveInferenceFixtures.loadBridge` harness constructs here. Stages:
//
//   (a) VISION THROUGH V2 — a real image request routed through the v2
//       engine: `EngineV2VisionPrefill` runs the wrapper's vision tower +
//       projector and the engine splices the embeddings at the placeholder
//       spans (CBv2 multimodal prefill). Asserted:
//         * the request actually took the v2 path (bridge admit count grew,
//           zero refusal ERRORs recorded);
//         * greedy determinism (same image + prompt twice ⇒ identical);
//         * the embeddings STEER the output (a red image and a blue image
//           with the same prompt produce different completions — if spans/
//           embeddings were dropped, both would collapse to the same
//           text-only answer).
//
//   (b) INTERLEAVE HYGIENE — text(v2) / vision(v2) / text(v2): a
//       vision-through-v2 request may not perturb a v2 text decode (span
//       masks / spliced embeddings must leave no residue in the engine's
//       caches — the Qwen3.5-mrope-class regression pattern).
//
// The removed legacy comparison is no longer needed for tower parity: direct
// VLM and CBv2 now invoke the same `Gemma4TextModel` instance. Media without
// a v2 bridge still fails loudly, as pinned by non-live routing tests.
//
// Teardown here is structured (bridge shutdown awaited on every exit path)
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

/// Thread-safe recorder for the vision plumbing's refusal ERRORs.
private final class VisionLiveRefusalRecorder: @unchecked Sendable {
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

    // MARK: - Harness (the provider's one-engine VLM slot shape)

    /// One loaded v2 VLM slot: the production bridge over the wrapper-owned
    /// text tower, the retained VLM container that runs vision, and the
    /// tokenizer for the registry entry.
    private struct LoadedV2VLMSlot {
        let modelID: String
        let bridge: EngineV2Bridge
        let container: ModelContainer
        let tokenizer: TokenizerHandle
    }

    /// Structured slot lifecycle: load through the shared fixture (the
    /// exact production construction), and AWAIT `bridge.shutdown()` +
    /// pool trim on every exit path so the multi-GB residency never
    /// overlaps the next serialized test's load.
    private func withV2VLMSlot(
        modelID: String, budgetBytes: Int,
        _ body: (LoadedV2VLMSlot) async throws -> Void
    ) async throws {
        let loaded = try await LiveInferenceFixtures.loadBridge(
            modelID: modelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: budgetBytes,
            defaultMaxTokens: 256)
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let slot = LoadedV2VLMSlot(
            modelID: modelID,
            bridge: loaded.bridge,
            container: loaded.container,
            tokenizer: tokenizer)
        do {
            try await body(slot)
        } catch {
            await loaded.bridge.shutdown()
            MLX.Memory.clearCache()
            throw error
        }
        await loaded.bridge.shutdown()
        MLX.Memory.clearCache()
    }

    /// Drive one OpenAI-shaped request through the production routing seam
    /// (`MultiModelBatchSchedulerEngine.streamChatCompletion`) over the
    /// slot's registry entry and join the streamed content.
    private func streamText(
        slot: LoadedV2VLMSlot,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        visionPlumbing: EngineV2VisionPlumbing? = nil
    ) async throws -> String {
        // Destructure the Sendable pieces for the @Sendable registry closure.
        let modelID = slot.modelID
        let bridge = slot.bridge
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
    /// zero refusal ERRORs and a bridge admit for this request.
    private func streamVisionThroughV2(
        slot: LoadedV2VLMSlot,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        stage: String
    ) async throws -> String {
        let recorder = VisionLiveRefusalRecorder()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { container, request, reasoningEffort, enableThinkingOverride in
                try await EngineV2VisionPrefill.prepare(
                    container: container, request: request, reasoningEffort: reasoningEffort, enableThinkingOverride: enableThinkingOverride)
            },
            emitTelemetry: { recorder.append($0) }
        )
        let admitsBefore = await slot.bridge._testCounters().admits
        let content = try await streamText(
            slot: slot, userContent: userContent,
            maxTokens: maxTokens, visionPlumbing: plumbing)
        let admitsAfter = await slot.bridge._testCounters().admits
        #expect(
            recorder.events.isEmpty,
            Comment(
                rawValue: "[\(stage)] vision request was refused: "
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
        "qat-4bit: vision through v2 — steering, determinism, interleave",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitVisionThroughV2() async throws {
        try await withV2VLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            let textPrompt = OpenAIMessageContent.text(
                "Count from one to five as digits separated by commas.")
            let colorPrompt = "What color is this image? Answer with one word."

            // v2 text baseline for the interleave assertions.
            let v2Text = try await streamText(
                slot: slot, userContent: textPrompt, maxTokens: 32)
            #expect(!v2Text.isEmpty, "v2 text baseline produced no content")

            // (a) VISION THROUGH V2: real embeddings at real spans.
            let redContent = try await streamVisionThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                ]),
                maxTokens: 16, stage: "red")
            #expect(!redContent.isEmpty, "v2 vision request produced no content")

            // Greedy determinism: identical input ⇒ identical output.
            let redContentAgain = try await streamVisionThroughV2(
                slot: slot,
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
                slot: slot,
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
            print(
                "[gemma-vlm-vision-v2] red: v2=\(redContent.debugDescription) "
                    + "blue: v2=\(blueContent.debugDescription)")

            // (b) INTERLEAVE HYGIENE: one more vision-through-v2 request
            // directly before the text re-decode (the red/red2/blue
            // requests above already interleaved the baseline); the v2
            // text output must be byte-identical to the baseline.
            _ = try await streamVisionThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .imageURL(visionSolidRedPNGDataURI),
                ]),
                maxTokens: 16, stage: "interleave")
            let v2TextAfterV2Vision = try await streamText(
                slot: slot, userContent: textPrompt, maxTokens: 32)
            #expect(
                v2TextAfterV2Vision == v2Text,
                Comment(
                    rawValue: "v2 text decode changed after an interleaved v2 vision "
                        + "request: before=\(v2Text.debugDescription) "
                        + "after=\(v2TextAfterV2Vision.debugDescription)"))
        }
    }

    // MARK: - 8bit: vision through v2

    @Test(
        "8bit: vision through v2 — coherent, on the v2 path",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func eightBitVisionThroughV2() async throws {
        try await withV2VLMSlot(
            modelID: Self.eightBitModelID, budgetBytes: 64 * 1024 * 1024 * 1024
        ) { slot in
            let redContent = try await streamVisionThroughV2(
                slot: slot,
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
