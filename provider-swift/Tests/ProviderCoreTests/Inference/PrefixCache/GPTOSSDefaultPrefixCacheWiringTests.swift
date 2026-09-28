import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("GPT-OSS default complete SSD production wiring", .serialized)
struct GPTOSSDefaultPrefixCacheWiringTests {
    private let modelID = "gpt-oss-20b"
    private let weightHash = String(repeating: "a", count: 64)
    private let promptContractID = "gptoss-default-test-contract"

    private func tinyTarget() throws -> GPTOSSModel {
        let data = Data("""
            {"model_type":"gpt_oss", "num_hidden_layers":2,
             "num_local_experts":4, "num_experts_per_tok":2, "vocab_size":128,
             "rms_norm_eps":0.00001, "hidden_size":64, "intermediate_size":64,
             "head_dim":64, "num_attention_heads":4, "num_key_value_heads":2,
             "sliding_window":32}
            """.utf8)
        return GPTOSSModel(try JSONDecoder().decode(GPTOSSConfiguration.self, from: data))
    }

    private func preparation(_ model: GPTOSSModel, paged: Bool = true) throws
        -> EngineV2Factory.ProductionBackendPreparation
    {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        var environment = [KVBackendGuardStore.pathEnvKey: "/dev/null"]
        if !paged { environment[EngineV2KVBackendPolicy.killSwitchEnvKey] = "0" }
        return try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: modelID, kvBytesCapacity: 128 << 20,
            maxConcurrentRequests: 1, kvBackend: .auto, maxContextLength: 1024,
            environment: environment, pagedPreflightOverride: { _ in })
    }

    private func construct(
        _ model: GPTOSSModel, _ prepared: EngineV2Factory.ProductionBackendPreparation,
        root: URL, modelID: String = "gpt-oss-20b", hash: String? = String(repeating: "a", count: 64),
        contract: String? = "gptoss-default-test-contract", environment: [String: String] = [:]
    ) async -> EngineV2SlotFactory.CompletePrefixCachePreparation? {
        let isolated = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path,
        ].merging(environment) { _, value in value }
        return await EngineV2SlotFactory.prepareCompletePrefixCache(
            modelId: modelID, model: model, preparedBackend: prepared,
            weightHash: hash, promptContractID: contract,
            mtpDrafter: nil, mtpConfig: .init(), kvBudget: nil, environment: isolated,
            identityOverride: .init(modelAggregateHash: weightHash,
                                    promptContractID: promptContractID,
                                    buildID: "gptoss-wiring-test-build",
                                    numericsFingerprint: "gptoss-wiring-test-numerics"))
    }

    @Test("Default activation constructs a historical checkpoint store on actual native pages")
    func defaultConstructsHistoricalStore() async throws {
        let model = try tinyTarget()
        let prepared = try preparation(model)
        #expect(prepared.kind == .paged)
        #expect(prepared.fallbackReason == nil)
        #expect(prepared.pagedPoolConfig?.segmentSizeBytes != nil)
        #expect(!prepared.residentPrefixCacheEnabled)
        #expect(prepared.hybridPrefixCache == nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gptoss-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await construct(model, prepared, root: root)
        let cache = try #require(result?.cache)
        defer { cache.close() }
        #expect(cache.config.modelId == modelID)
        #expect(cache.config.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(cache.config.identity.modelAggregateHash == weightHash)
        #expect(cache.config.identity.promptContractID == promptContractID)
        #expect(cache.config.minEffectiveTokens == SSDPrefixCachePolicy.defaultMinEffectiveTokens)
        await cache.closeAndWait()
    }

    @Test("Default activation preserves cache disable, exact ID, and identity refusal before disk creation")
    func defaultRetainsConstructionGates() async throws {
        let model = try tinyTarget()
        let prepared = try preparation(model)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gptoss-refused-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disabled = await construct(model, prepared, root: root,
            environment: [PrefixCachePolicy.environmentFlag: "0"])
        #expect(disabled?.cache == nil)
        #expect(disabled?.status.reason == .configDisabled)
        let alias = await construct(model, prepared, root: root, modelID: "openai/gpt-oss-20b")
        #expect(alias?.cache == nil)
        #expect(alias?.status.reason == .configDisabled)
        let missingHash = await construct(model, prepared, root: root, hash: nil)
        #expect(missingHash?.cache == nil)
        #expect(missingHash?.status.reason == .weightHashUnavailable)
        let changedHash = await construct(model, prepared, root: root, hash: String(repeating: "b", count: 64))
        #expect(changedHash?.cache == nil)
        #expect(changedHash?.status.reason == .runtimeIdentityUnavailable)
        let changedContract = await construct(model, prepared, root: root, contract: "changed-contract")
        #expect(changedContract?.cache == nil)
        #expect(changedContract?.status.reason == .runtimeIdentityUnavailable)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Paged kill switch falls back to contiguous and refuses historical SSD reuse")
    func pagedFallbackStaysCold() async throws {
        let model = try tinyTarget()
        let prepared = try preparation(model, paged: false)
        #expect(prepared.kind == .contiguous)
        #expect(prepared.fallbackReason == "kill_switch")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gptoss-contiguous-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await construct(model, prepared, root: root)
        #expect(result?.cache == nil)
        #expect(result?.status.reason == .unsupportedLayout)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
