// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore
// MARK: - Slot build (the ensureModelLoaded call site)

@Suite("EngineV2 production wiring: v2-only slot build")
struct EngineV2SlotBuildTests {


    @Test("slot build is unconditional: builds, registers, and streams translated events")
    func slotBuildAlwaysBuildsRegistersAndStreams() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]), kvBytesCapacity: 0)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: productionWiringPhysicalBytes,
                makeEngine: { _, _ in engine }))

        let bridge = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: productionMakeSizing(weightsGiB: 15)
        )

        // Registered with the runtime BEFORE the slot goes live.
        #expect(await runtime.bridge(forModel: "gemma-4-26b-qat-4bit") === bridge)

        // The bridge streams the translated events (legacy GenerationEvent
        // framing) from the scripted engine.
        var sawChunk = false
        var sawInfo = false
        let stream = await bridge.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [ChatMessage(role: "user", content: "hi")]))
        for await event in stream {
            switch event {
            case .chunk(let text):
                #expect(text == "Hello")
                sawChunk = true
            case .info(let prompt, let completion, _, _):
                #expect(prompt == 5)
                #expect(completion == 1)
                sawInfo = true
            case .error(let message):
                Issue.record("unexpected error event: \(message)")
            case .terminal(let cause, let message, _, _):
                Issue.record("unexpected terminal event: \(cause.rawValue) \(message)")
            }
        }
        #expect(sawChunk)
        #expect(sawInfo)
        #expect(engine.submitted.count == 1)
        // Tokenization went through the tokenizer's chat-template path.
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }




    @Test("production factory: unsupported model class throws (→ refusal)")
    func productionFactoryRejectsUnsupportedModel() {
        // A module that is neither Gemma4TextModel nor GPTOSSModel must throw
        // BEFORE any engine machinery is built — the factory catch turns this
        // into the ERROR refusal.
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: ProductionWiringStubLanguageModel(),
                tokenizer: productionWiringStubTokenizer(),
                kvBytesCapacity: 1 << 20,
                maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent)
            )
        }
    }

    @Test("production factory: zero KV headroom throws (→ refusal)")
    func productionFactoryRejectsZeroKVHeadroom() {
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: ProductionWiringStubLanguageModel(),
                tokenizer: productionWiringStubTokenizer(),
                kvBytesCapacity: 0,
                maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent)
            )
        }
    }


    @Test("configured concurrency reaches the bridge (box-wide + per-model override)")
    func concurrencyConfigReachesBridge() async throws {
        let loop = try productionMakeWiringLoop(engineV2MaxConcurrent: 6,
        engineV2MaxConcurrentByModel: ["gpt-oss-20b": 2])
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: productionWiringPhysicalBytes,
                makeEngine: { _, grant in
                    ScriptedCBv2Engine(script: .manual, kvBytesCapacity: grant)
                }))

        // Per-model override wins for gpt-oss-20b…
        let gptoss = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: productionMakeSizing(weightsGiB: 12, kvRate: 24_576)
        )
        #expect(await gptoss.backendSlotCapacity().maxConcurrency == 2)

        // …and the box-wide value covers everything else. Heartbeat
        // max_concurrency reports the effective per-slot value.
        let gemma = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: productionMakeSizing(weightsGiB: 15)
        )
        #expect(await gemma.backendSlotCapacity().maxConcurrency == 6)
    }
}
