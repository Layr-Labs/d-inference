import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionProviderBundleAnchor: NSObject {}

/// Explicit real-artifact provider-bridge gate. Not normal startup, HTTP/auth,
/// hosted routing, or a claim that scanner advertisement is ready.
@Suite("DiffusionGemma real provider bridge", .serialized)
struct DiffusionGemmaProviderLiveTests {
    private actor UsageCapture {
        var usage: CBv2Usage?
        func record(_ value: CBv2Usage) { usage = value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_RAW_RESPONSES_DIAGNOSTIC"] == "1"))
    func recordsResponsesWeatherBeforeAndAfterNativeParsing() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        _ = Bundle(for: DiffusionProviderBundleAnchor.self).bundleURL
        let container = try await DiffusionGemmaModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        for effort in ["none", "medium"] {
            let body: [String: Any] = ["model": "mlx-community/diffusiongemma-26B-A4B-it-4bit",
                "input": "Use get_weather to check the current weather in Paris. Do not guess the weather.",
                "tools": [["type": "function", "name": "get_weather",
                    "description": "Get the current weather for a city.", "parameters": ["type": "object",
                    "properties": ["city": ["type": "string"]], "required": ["city"], "additionalProperties": false]]],
                "tool_choice": "required", "parallel_tool_calls": false,
                "reasoning": ["effort": effort], "temperature": 1, "max_output_tokens": 512]
            let request = try JSONDecoder().decode(OpenAIResponseRequest.self,
                from: JSONSerialization.data(withJSONObject: body)).chatCompletionRequest
            let data = try JSONEncoder().encode(request)
            for seed: UInt64 in [7419, 7420, 7421] {
                let diagnostic = try await container.perform { context -> Data in
                    let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                        data, tokenizer: context.tokenizer, modelType: "diffusion_gemma")
                    let rendered = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                    #expect(rendered.contains("<|think|>") == (effort == "medium"),
                        "The actual native activation token must reflect the typed Responses control")
                    let base = context.generationConfiguration
                    let recipe = try DiffusionGemmaGenerationConfiguration(maxNewTokens: 512,
                        maxDenoisingSteps: base.maxDenoisingSteps, sampler: base.sampler,
                        minimumTemperature: base.minimumTemperature, maximumTemperature: base.maximumTemperature,
                        stabilityThreshold: base.stabilityThreshold, confidenceThreshold: base.confidenceThreshold,
                        bosTokenId: base.bosTokenId, padTokenId: base.padTokenId, eosTokenIds: base.eosTokenIds)
                    let result = try context.model.generateNative(
                        promptTokenIds: MLXArray(tokens.map(Int32.init)).reshaped(1, tokens.count),
                        generation: recipe, seed: seed, prefillChunkSize: 512)
                    let raw = context.tokenizer.decode(tokenIds: result.tokenIds.map(Int.init), skipSpecialTokens: false)
                    let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "diffusion_gemma")
                    let handler = try ToolStreamPreparation.makeHandler(request: request,
                        prepared: prepared, modelType: "diffusion_gemma")
                    var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                        nativePrefix: nil, nativeGemmaChannels: true)
                    var errorText = ""
                    do {
                        _ = try router.process(raw)
                        _ = try router.finishText()
                        try ToolConstraintValidation.validate(handler?.finish() ?? [], prepared: prepared)
                    } catch { errorText = String(describing: error) }
                    return try JSONSerialization.data(withJSONObject: ["effort": effort, "seed": seed,
                        "promptTokenIds": tokens, "rawTokenIds": result.tokenIds, "rawText": raw,
                        "validationError": errorText, "finish": result.finishReason,
                        "scope": "diagnostic before HTTP; fixed seeds do not reproduce the prior unseeded run",
                        "qualityQualification": false], options: [.sortedKeys])
                }
                print("DIFFUSION_RAW_RESPONSES " + String(decoding: diagnostic, as: UTF8.self))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_RAW_TOOL_DIAGNOSTIC"] == "1"))
    func recordsRawLiteralToolOutputBeforeAnyParser() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        _ = Bundle(for: DiffusionProviderBundleAnchor.self).bundleURL
        let container = try await DiffusionGemmaModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let literal = "A \"quote\"; path C:\\tmp\\file; café 🌊; literal <|channel>thought example<channel|>."
        for thinking in [false, true] {
            let body: [String: Any] = ["model": "mlx-community/diffusiongemma-26B-A4B-it-4bit",
                "messages": [["role": "user", "content": "Use record_text to store this exact text, preserving every character: " + literal]],
                "tools": [["type": "function", "function": ["name": "record_text",
                    "description": "Store the provided text unchanged.", "parameters": ["type": "object",
                    "properties": ["text": ["type": "string"]], "required": ["text"], "additionalProperties": false]]]],
                "tool_choice": "required", "reasoning": ["enabled": thinking],
                "temperature": 1, "seed": 7419, "max_tokens": 512, "stream": false]
            let data = try JSONSerialization.data(withJSONObject: body)
            let diagnostic = try await container.perform { context -> Data in
                let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                    data, tokenizer: context.tokenizer, modelType: "diffusion_gemma")
                let decoded = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                #expect(decoded.contains(literal), "The exact argument must survive prompt rendering/tokenization")
                let base = context.generationConfiguration
                let recipe = try DiffusionGemmaGenerationConfiguration(maxNewTokens: 512,
                    maxDenoisingSteps: base.maxDenoisingSteps, sampler: base.sampler,
                    minimumTemperature: base.minimumTemperature, maximumTemperature: base.maximumTemperature,
                    stabilityThreshold: base.stabilityThreshold, confidenceThreshold: base.confidenceThreshold,
                    bosTokenId: base.bosTokenId, padTokenId: base.padTokenId, eosTokenIds: base.eosTokenIds)
                let result = try context.model.generateNative(
                    promptTokenIds: MLXArray(tokens.map(Int32.init)).reshaped(1, tokens.count),
                    generation: recipe, seed: 7419, prefillChunkSize: 512)
                let raw = context.tokenizer.decode(tokenIds: result.tokenIds.map(Int.init), skipSpecialTokens: false)
                return try JSONSerialization.data(withJSONObject: ["thinking": thinking,
                    "promptPreservesLiteral": decoded.contains(literal), "rawText": raw,
                    "promptTokenIds": tokens,
                    "rawTokenIds": result.tokenIds, "finish": result.finishReason,
                    "scope": "diagnostic before reasoning/tool parsing", "qualityQualification": false],
                    options: [.sortedKeys])
            }
            print("DIFFUSION_RAW_TOOL " + String(decoding: diagnostic, as: UTF8.self))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_LIVE"] == "1"))
    func fullArtifactNativeBridgeMatchesDirectGenerationAndReleasesSharedBudget() async throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        let config = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let hash = SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined()
        try #require(hash == "b41320c97651075363f2895e2cbb3d1580670ee11edb653a14290a35bbf7cac5")
        // Register the owned test bundle before device initialization.
        _ = Bundle(for: DiffusionProviderBundleAnchor.self).bundleURL
        let container = try await DiffusionGemmaModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let baseline = try await container.perform { context -> (tokens: [Int32], text: String, output: [Int32], generated: Int) in
            let tokens = try context.renderTokens(
                messages: [["role": "user", "content": "Explain why leaves are green in three clear sentences."]],
                additionalContext: ["enable_thinking": false])
            try #require(tokens.count == 19)
            let result = try context.model.generateNative(
                promptTokenIds: MLXArray(tokens).reshaped(1, tokens.count),
                generation: context.generationConfiguration, seed: 4100)
            return (tokens, context.tokenizer.decode(tokenIds: result.tokenIds.map(Int.init), skipSpecialTokens: false),
                    result.tokenIds, result.generatedTokenCount)
        }
        // Real hardware accounting, with audit delivery suppressed in the fixture.
        // No cap/headroom override, credential copying or authentication bypass.
        let budget = GlobalKVCacheBudget(memorySnapshot: {
            let memory = Memory.snapshot()
            return GlobalKVCacheBudget.MemorySnapshot(total: ProcessInfo.processInfo.physicalMemory,
                active: UInt64(max(0, memory.activeMemory)), cache: UInt64(max(0, memory.cacheMemory)),
                systemAvailable: SystemMemory.availableBytes() ?? .max)
        }, clearCache: {
            MLX.Stream().synchronize(); Memory.clearCache()
        }, emitAuditEvent: { _, _, _ in })
        let prepared = try await DiffusionGemmaProviderBridge.make(
            container: container, modelID: "diffusiongemma-native-fixture",
            kvBytesCapacity: 16 * 1024 * 1024 * 1024, sharedBudget: budget)
        let captured = UsageCapture()
        await prepared.bridge.captureDiffusionNativeUsage { usage in await captured.record(usage) }
        let request = ChatCompletionRequest(
            model: "diffusiongemma-native-fixture", messages: [], temperature: 1,
            max_tokens: 256, seed: 4100)
        let stream = await prepared.bridge.submitTokenized(
            promptTokens: baseline.tokens.map(Int.init), request: request,
            requestId: "native-bridge-fixture", cacheEnabled: false)
        var text = "", completion = 0, rate: Double = 0
        var terminalCount = 0
        for await event in stream {
            switch event {
            case .chunk(let delta): text += delta
            case .info(let prompt, let generated, let tps, let reason):
                #expect(prompt == 19 && reason == "stop")
                completion = generated; rate = tps; terminalCount += 1
            case .error(let message): Issue.record("Provider bridge failed: \(message)")
            case .terminal: Issue.record("Unexpected policy/engine terminal")
            }
        }
        #expect(text == baseline.text)
        #expect(completion == baseline.generated && terminalCount == 1)
        let nativeUsage = try #require(await captured.usage)
        #expect(rate.isFinite && rate > 0)
        #expect(rate == EngineV2NativeBlockTiming.generationRate(
            completionTokens: completion, timing: nativeUsage.timing),
            "Reported rate must use the real complete generation interval, including the first block")
        await prepared.bridge.shutdown()
        #expect(await budget.outstandingReservedBytes() == 0)
        let row: [String: Any] = ["scope": "provider bridge only", "textExact": text == baseline.text,
            "completionTokens": completion, "terminalCount": terminalCount, "tokensPerSecond": rate,
            "sharedReservedBytesAfterShutdown": await budget.outstandingReservedBytes(),
            "httpQualification": false, "fullSupportQualification": false]
        print("DIFFUSION_PROVIDER " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
}

private extension EngineV2Bridge {
    func captureDiffusionNativeUsage(_ callback: @escaping @Sendable (CBv2Usage) async -> Void) {
        _testBeforeNativeTerminal = callback
    }
}
