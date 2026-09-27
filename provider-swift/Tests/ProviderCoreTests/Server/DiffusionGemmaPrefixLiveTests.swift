import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import MLXVLM
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionPrefixBundleAnchor: NSObject {}

@Suite("DiffusionGemma authenticated resident prefix", .serialized)
struct DiffusionGemmaPrefixLiveTests {
    private struct Result { let text: String; let prompt: Int; let completion: Int; let cached: Int }

    fileprivate final class Owners: @unchecked Sendable {
        weak var container: DiffusionGemmaContainer?
        weak var model: AnyObject?
        weak var text: AnyObject?
        weak var decoder: AnyObject?
        var released: Bool { container == nil && model == nil && text == nil && decoder == nil }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PREFIX_HTTP_LIVE"] == "1"))
    func exactAndAppendedRequestsMatchUncachedNativeGeneration() async throws {
        let memoryEnabled = PrefixCachePolicy.isMemoryEnabled(environment: ProcessInfo.processInfo.environment)
        try #require(memoryEnabled,
            "This explicit gate requires the ordinary operator RAM-cache opt-in")
        try await exercisePrefix(persistent: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_SSD_HTTP_LIVE"] == "1"))
    func encryptedExactAndAppendMatchWithResidentMemoryDisabled() async throws {
        try requireEphemeralSSDEnvironment()
        try await exercisePrefix(persistent: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PAGED_HTTP_LIVE"] == "1"))
    func pageBackedRequestsUseProcessAdmissionAndEncryptedPrefixReuse() async throws {
        try requireEphemeralSSDEnvironment()
        try await exercisePrefix(persistent: true, pageBacked: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_STOP_CACHE_LIVE"] == "1"))
    func stoppedDonorAndEphemeralKeyRotationPreserveNativeOutput() async throws {
        try requireEphemeralSSDEnvironment()
        try await exercisePrefix(persistent: true, pageBacked: true, stoppedReload: true)
    }

    private func requireEphemeralSSDEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        // Rich assertions expand their operands on failure. Never put the
        // complete process environment (possibly credentials) in an operand.
        let memoryEnabled = PrefixCachePolicy.isMemoryEnabled(environment: environment)
        let diskEnabled = PrefixCachePolicy.isEnabled(modelId: "mlx-community/diffusiongemma-26B-A4B-it-4bit", environment: environment)
        let ephemeral = SSDPrefixCacheFactory.forceEphemeralKey(environment: environment)
        try #require(!memoryEnabled)
        try #require(diskEnabled)
        try #require(ephemeral, "Set the explicit ephemeral opt-in and an owned isolated test root; never fall through to the operator's persistent key")
    }

    private func exercisePrefix(persistent: Bool, pageBacked: Bool = false, stoppedReload: Bool = false) async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let selectedPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]
        let selected = try #require(selectedPath)
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == URL(fileURLWithPath: selected).appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionPrefixBundleAnchor.self).bundleURL
        if persistent {
            // The CLI binds its immutable library before MLX startup. HTTP
            // tests do not execute CLI startup, so perform that SAME binding;
            // a path hash without binding must never authorize disk reuse.
            let resources = try #require(Bundle(for: DiffusionPrefixBundleAnchor.self).resourceURL)
            let library = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
            let expected = try #require(hashFile(atPath: library.path))
            try #require(bindRuntimeMetallibForMLX(from: library) == expected)
            try #require(metallibHash() == expected)
            _ = try PromptContractIdentity.compute(modelDirectory: directory)
        }
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token,
            engineV2KVBackend: pageBacked ? "paged" : "contiguous", coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        let notes = (1...24).map { index in
            "Section \(index): Each request keeps independent model state. Authentication precedes admission. "
                + "The cache may reuse a committed prefix only when its input and tenant match. "
                + "Cancellation releases the request and must not publish an unfinished entry."
        }.joined(separator: "\n")
        func body(_ extra: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model": modelID,
                "messages": [["role": "user", "content": notes + extra + "\nWhat is 17 times 19? Reply with the number only."]],
                "reasoning": ["enabled": false], "temperature": 1, "seed": 341, "max_tokens": 128, "stream": false])
        }
        let base = try body("")
        let appended = try body("\nAdditional note: Reporting must distinguish cached tokens from newly computed tokens.")
        var stopObject = try #require(JSONSerialization.jsonObject(with: base) as? [String: Any])
        stopObject["stop"] = ["2"]
        let stopped = try JSONSerialization.data(withJSONObject: stopObject)
        do {
            try await server.makeApplication().test(.ahc()) { client in
                try #require(client.port != nil, "Exercise actual authenticated loopback HTTP")
                var stoppedRepeatExact: Bool?
                func request(_ data: Data) async throws -> Result {
                    let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: data))
                    let json = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    try #require(response.status == .ok, "Native cached request failed: \(json)")
                    let choices = try #require(json["choices"] as? [[String: Any]])
                    let message = try #require(choices.first?["message"] as? [String: Any])
                    let usage = try #require(json["usage"] as? [String: Any])
                    let details = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
                    #expect(choices.first?["finish_reason"] as? String == "stop")
                    return Result(text: message["content"] as? String ?? "",
                        prompt: try #require(usage["prompt_tokens"] as? Int),
                        completion: try #require(usage["completion_tokens"] as? Int),
                        cached: details["cached_tokens"] as? Int ?? 0)
                }
                let cold = try await request(stoppedReload ? stopped : base)
                if pageBacked {
                    try #require(await server.diffusionPrefixTestPageOwner(modelID))
                    let status = try #require(await server.diffusionPrefixTestStatus(modelID))
                    #expect(status.backend == .paged)
                }
                if persistent {
                    let status = await server.diffusionPrefixTestStatus(modelID)
                    let store = try #require(await server.diffusionPrefixTestStore(modelID),
                        "Ordinary slot must produce a verified native store; status: \(String(describing: status))")
                    await store.waitForWritesForTesting()
                    try #require(store.stats().filesWritten > 0)
                    try #require(store.usesEphemeralKey)
                }
                let warm = try await request(base)
                #expect(cold.cached == 0)
                if stoppedReload {
                    #expect(cold.text.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
                    #expect(warm.text.trimmingCharacters(in: .whitespacesAndNewlines) == "323")
                    #expect(warm.prompt == cold.prompt && cold.completion < warm.completion)
                    let warmStop = try await request(stopped)
                    #expect(warmStop.text == cold.text && warmStop.completion == cold.completion)
                    stoppedRepeatExact = warmStop.text == cold.text && warmStop.completion == cold.completion
                    #expect(warmStop.cached > 0)
                    let oldStore = try #require(await server.diffusionPrefixTestStore(modelID))
                    await oldStore.waitForWritesForTesting()
                    let owners = try await server.diffusionPrefixOwnerWitnesses(modelID)
                    let oldBridge = try #require(await server.diffusionPrefixBridge(modelID))
                    try #require(await server.evictLRUIdleSlotForTesting())
                    let until = ContinuousClock.now.advanced(by: .seconds(10))
                    while !owners.released && ContinuousClock.now < until {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try #require(owners.released, "Release actual inner owners, even with the old bridge/store retained")
                    #expect(await server.debugOutstandingKVReservationBytes() == 0)
                    try await server.ensureModelLoaded(modelID)
                    let newBridge = try #require(await server.diffusionPrefixBridge(modelID))
                    let newStore = try #require(await server.diffusionPrefixTestStore(modelID))
                    #expect(newBridge !== oldBridge && newStore !== oldStore)
                    #expect(newStore.usesEphemeralKey)
                    let rotated = try await request(base)
                    #expect(rotated.text == warm.text && rotated.completion == warm.completion)
                    #expect(rotated.cached == 0,
                        "A new ephemeral key must not restore the preceding key's ciphertext")
                    await newStore.waitForWritesForTesting()
                    try #require(newStore.stats().filesWritten > 0)
                    let rewarm = try await request(stopped)
                    #expect(rewarm.text == cold.text && rewarm.completion == cold.completion)
                    stoppedRepeatExact = stoppedRepeatExact == true
                        && rewarm.text == cold.text && rewarm.completion == cold.completion
                    #expect(rewarm.cached > 0)
                    print("DIFFUSION_STOP_CACHE stoppedCached=\(warmStop.cached) fullCached=\(warm.cached) rotatedCached=\(rotated.cached) rewarmCached=\(rewarm.cached) oldInnerOwnersReleased=true persistentWarmRestartClaim=false")
                } else {
                    #expect(cold.text.contains("323"))
                    #expect(warm.text == cold.text && warm.completion == cold.completion)
                }
                #expect(warm.cached > 0 && warm.cached <= warm.prompt)
                #expect(await server.debugActiveRequestCount(modelId: modelID) == 0)
                let container = try #require(await server.diffusionPrefixTestContainer(modelID))
                let reference = try await container.perform { context -> (String, Int, Int) in
                    let ids = try ProviderPromptContractPipeline.tokenizeProviderBody(appended,
                        tokenizer: context.tokenizer, modelType: "diffusion_gemma")
                    let recipe = context.generationConfiguration
                    let config = try DiffusionGemmaGenerationConfiguration(maxNewTokens: 128,
                        maxDenoisingSteps: recipe.maxDenoisingSteps, sampler: recipe.sampler,
                        minimumTemperature: recipe.minimumTemperature, maximumTemperature: recipe.maximumTemperature,
                        stabilityThreshold: recipe.stabilityThreshold, confidenceThreshold: recipe.confidenceThreshold,
                        bosTokenId: recipe.bosTokenId, padTokenId: recipe.padTokenId, eosTokenIds: recipe.eosTokenIds)
                    let result = try context.model.generateNative(promptTokenIds: MLXArray(ids.map(Int32.init)).reshaped(1, ids.count),
                        generation: config, seed: 341, prefillChunkSize: 512)
                    let raw = context.tokenizer.decode(tokenIds: result.tokenIds.map(Int.init), skipSpecialTokens: false)
                    var parser = DiffusionGemmaChannelSplitter()
                    let pieces = parser.parse(raw) + parser.finish()
                    return (pieces.map(\.content).joined(), ids.count, result.generatedTokenCount)
                }
                let extended = try await request(appended)
                #expect(extended.cached > 0 && extended.cached.isMultiple(of: 512))
                #expect(extended.text == reference.0 && extended.prompt == reference.1 && extended.completion == reference.2)
                if persistent {
                    let store = try #require(await server.diffusionPrefixTestStore(modelID))
                    await store.waitForWritesForTesting()
                    #expect(store.stats().stages >= 2 && store.stats().stageConsumptions >= 2)
                    #expect(store.stats().filesRead >= 4 && store.stats().maximumSegmentBytes > 0)
                }
                let report: [String: Any] = ["coldPrompt": cold.prompt, "coldCached": cold.cached,
                    "warmCached": warm.cached, "appendedPrompt": extended.prompt, "appendedCached": extended.cached,
                    "exactRepeat": stoppedRepeatExact ?? (warm.text == cold.text),
                    "repeatControl": stoppedReload ? "stop=2" : "no stop",
                    "stoppedDonorAndRotation": stoppedReload,
                    "appendedEqualsCold": extended.text == reference.0,
                    "tier": persistent ? "encrypted SSD native checkpoint" : "in-memory complete snapshot",
                    "residentRetention": !persistent,
                    "pageBacked": pageBacked, "directPagedKernel": false,
                    "scope": persistent ? "authenticated loopback HTTP + normal slot + ephemeral encrypted cache; no signed restart/hosted claim" : "authenticated loopback HTTP + resident cache",
                    "persistentQualification": false, "pagedQualification": false]
                print("DIFFUSION_PREFIX_HTTP " + String(decoding: try JSONSerialization.data(withJSONObject: report,
                    options: [.sortedKeys]), as: UTF8.self))
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }
}

private extension StandaloneServer {
    func diffusionPrefixBridge(_ modelID: String) -> EngineV2Bridge? { slots[modelID]?.bridge }
    func diffusionPrefixOwnerWitnesses(_ modelID: String) async throws -> DiffusionGemmaPrefixLiveTests.Owners {
        let container = try #require(slots[modelID]?.modelContainer.diffusion)
        let result = await container.perform { context in
            let owners = DiffusionGemmaPrefixLiveTests.Owners()
            owners.model = context.model
            owners.text = context.model.model
            owners.decoder = context.model.model.decoder
            return owners
        }
        result.container = container
        return result
    }
}

extension StandaloneServer {
    func diffusionPrefixTestContainer(_ modelID: String) -> DiffusionGemmaContainer? { slots[modelID]?.modelContainer.diffusion }
    func diffusionPrefixTestStore(_ modelID: String) -> SSDHybridCheckpointStore? { slots[modelID]?.bridge.ssdHybridCheckpointStore }
    func diffusionPrefixTestStatus(_ modelID: String) -> PrefixCacheModelStatus? { slots[modelID]?.bridge.prefixCacheModelStatus() }
    func diffusionPrefixTestPageOwner(_ modelID: String) async -> Bool {
        guard let bridge = slots[modelID]?.bridge else { return false }
        return await bridge.diffusionPrefixTestPageOwner()
    }
}

private extension EngineV2Bridge {
    func diffusionPrefixTestPageOwner() -> Bool {
        guard let engine = ownedEngine as? CBv2NativeBlockEngine else { return false }
        return engine.usesPagedStorage && engine.usesProcessMemoryOwner
    }
}
