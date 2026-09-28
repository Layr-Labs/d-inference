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
