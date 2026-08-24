// Copyright © 2026 Eigen Labs.
//
// Deployment policy and accounting for Qwen exact prompt-state reuse.

import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private let exactWeightA = String(repeating: "a", count: 64)
private let exactWeightB = String(repeating: "b", count: 64)
private let exactPromptA = String(repeating: "c", count: 64)
private let exactPromptB = String(repeating: "d", count: 64)

private func exactQwenCapabilities() -> CBv2ModelCapabilities {
    var capabilities = CBv2ModelCapabilities.initialRecurrentTarget
    capabilities.supportsExactStatePrefixReuse = true
    return capabilities
}

private final class ExactAccountingEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var bytesCapacity: Int

    init(bytesCapacity: Int) {
        self.bytesCapacity = bytesCapacity
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { $0.finish() }
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: 0,
                waitingRequests: 0,
                kvBytesInUse: 0,
                kvBytesCapacity: bytesCapacity,
                kvBytesBackendCapacity: bytesCapacity,
                activeTokens: 0)
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock { bytesCapacity = max(0, bytes) }
    }

    func shutdown() async {}
}

private struct ExactAccountingTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}

private struct ExactSlotProcessorError: Error {}

private struct ExactSlotProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw ExactSlotProcessorError()
    }
}

private func tinyExactQwenModel() throws -> Qwen35MoEModel {
    let text: [String: Any] = [
        "model_type": "qwen3_5_moe",
        "hidden_size": 32,
        "num_hidden_layers": 2,
        "intermediate_size": 64,
        "num_attention_heads": 2,
        "num_key_value_heads": 1,
        "head_dim": 16,
        "linear_num_value_heads": 1,
        "linear_num_key_heads": 1,
        "linear_key_head_dim": 4,
        "linear_value_head_dim": 4,
        "linear_conv_kernel_dim": 2,
        "vocab_size": 64,
        "full_attention_interval": 2,
    ]
    let root: [String: Any] = [
        "model_type": "qwen3_5_moe",
        "text_config": text,
    ]
    let data = try JSONSerialization.data(withJSONObject: root)
    return Qwen35MoEModel(
        try JSONDecoder().decode(Qwen35Configuration.self, from: data))
}

@Suite("EngineV2 exact prefix cache deployment policy")
struct EngineV2ExactPrefixCacheTests {
    @Test("exact cache is default-off and unrecognized enable values fail closed")
    func defaultOff() {
        let absent = EngineV2SlotFactory.exactPrefixCacheConfiguration(
            environment: [:])
        #expect(absent.enabled == false)
        #expect(
            absent.maxBytes
                == EngineV2SlotFactory.defaultExactPrefixCacheMaxBytes)
        #expect(
            absent.maxFraction
                == EngineV2SlotFactory.defaultExactPrefixCacheMaxFraction)

        for raw in ["0", "false", "disabled", "garbage"] {
            #expect(
                EngineV2SlotFactory.exactPrefixCacheConfiguration(
                    environment: [
                        EngineV2SlotFactory.exactPrefixCacheEnabledEnvironmentKey:
                            raw
                    ]).enabled == false)
        }
    }

    @Test("exact opt-in independently requires verified load-bracket weights")
    func exactIdentityHashGateIsIndependentFromSSD() {
        let exactOnly = [
            PrefixCachePolicy.environmentFlag: "0",
            EngineV2SlotFactory.exactPrefixCacheEnabledEnvironmentKey: "1",
        ]
        #expect(
            EngineV2SlotFactory.cacheIdentityRequiresFreshWeightHash(
                environment: exactOnly))
        #expect(
            !EngineV2SlotFactory.cacheIdentityRequiresFreshWeightHash(
                environment: [
                    PrefixCachePolicy.environmentFlag: "0",
                    EngineV2SlotFactory.exactPrefixCacheEnabledEnvironmentKey: "0",
                ]))
    }

    @Test("exact-capable Qwen selects only the stronger cache")
    func exactQwenSelection() throws {
        let decision = EngineV2SlotFactory.exactPrefixCacheDecision(
            modelId: "qwen3.6-35b-a3b",
            capabilities: exactQwenCapabilities(),
            backend: .contiguous,
            backendDType: nil,
            weightHash: exactWeightA,
            promptContractID: exactPromptA,
            slotKVBytesCapacity: 8_000,
            configuration: .init(
                enabled: true, maxBytes: 1_000, maxFraction: 0.25),
            minimumEngineKVBytes: 1_000)
        #expect(decision.isActive)
        #expect(decision.reason == .ready)

        let exact = try #require(
            EngineV2SlotFactory.makeExactPrefixCache(decision: decision))
        #expect(
            EngineV2Factory.prefixCacheIsSupported(
                capabilities: exactQwenCapabilities(), prefixCache: exact))
        #expect(
            !EngineV2Factory.prefixCacheIsSupported(
                capabilities: exactQwenCapabilities(),
                prefixCache: PrefixCacheV2()))
    }

    @Test("slot factory installs exact Qwen cache and carves its grant")
    func slotConstruction() async throws {
        let model = try tinyExactQwenModel()
        let tokenizer = ExactAccountingTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/qwen"),
                model: model,
                processor: ExactSlotProcessor(),
                tokenizer: tokenizer))
        let preparedModel = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: model, eosTokenIds: [1], extraEOSTokens: []),
            servingModel: model,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)
        let slotGrant = 2 * 1_073_741_824
        let cacheBudget = 268_435_456

        let bundle = try await EngineV2SlotFactory.makeProductionBundle( // pragma: allowlist secret
            modelId: "qwen3.6-tiny",
            modelType: "qwen3_5_moe",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1,
                fp16KVBytesPerToken: 32,
                maxContextLength: 100_000_000,
                defaultMaxTokens: 32),
            kvBytesCapacity: slotGrant,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            kvBackendConfig: "contiguous",
            weightHash: exactWeightA,
            exactPrefixCacheConfiguration: .init(
                enabled: true,
                maxBytes: cacheBudget,
                maxFraction: 0.25),
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(promptContractID: exactPromptA),
            environment: [PrefixCachePolicy.environmentFlag: "0"])

        let bridge = bundle.bridge
        let cache = try #require(bridge.exactPrefixCache)
        #expect(cache.config.maxBytes == cacheBudget)
        #expect(bridge.ssdPrefixCache == nil)
        #expect(bridge.exactPrefixCacheReason == "ready")
        #expect(await bridge.resliceAdmissionBytesClaim() == slotGrant)
        let capacity = await bridge.capacitySnapshot()
        #expect(capacity.kvBytesCapacity == slotGrant - cacheBudget)
        await bridge.shutdown()
    }

    @Test("hard byte and fraction ceilings are carved from the slot grant")
    func budgetCarve() {
        let configuration = EngineV2SlotFactory.ExactPrefixCacheConfiguration(
            enabled: true, maxBytes: 4_000, maxFraction: 0.25)
        let fractionBound = EngineV2SlotFactory.exactPrefixCacheDecision(
            modelId: "qwen",
            capabilities: exactQwenCapabilities(),
            backend: .contiguous,
            backendDType: nil,
            weightHash: exactWeightA,
            promptContractID: exactPromptA,
            slotKVBytesCapacity: 10_000,
            configuration: configuration,
            minimumEngineKVBytes: 1_000)
        #expect(fractionBound.cacheBudgetBytes == 2_500)
        #expect(fractionBound.engineKVBytesCapacity == 7_500)
        #expect(
            fractionBound.cacheBudgetBytes
                + fractionBound.engineKVBytesCapacity == 10_000)

        let floorBound = EngineV2SlotFactory.exactPrefixCacheDecision(
            modelId: "qwen",
            capabilities: exactQwenCapabilities(),
            backend: .contiguous,
            backendDType: nil,
            weightHash: exactWeightA,
            promptContractID: exactPromptA,
            slotKVBytesCapacity: 1_100,
            configuration: configuration,
            minimumEngineKVBytes: 1_000)
        #expect(floorBound.cacheBudgetBytes == 100)
        #expect(floorBound.engineKVBytesCapacity == 1_000)
    }

    @Test("cache carve remains part of total admission through re-slicing")
    func bridgeAccounting() async throws {
        let cache = ExactPrefixCacheV2(
            config: .init(
                modelIdentity: "test-model",
                policyIdentity: "test-policy",
                maxBytes: 100))
        let engine = ExactAccountingEngine(bytesCapacity: 900)
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "qwen",
            tokenizer: TokenizerHandle(ExactAccountingTokenizer()),
            eosTokenIds: [],
            exactPrefixCache: cache,
            exactPrefixCacheConfigured: true,
            exactPrefixCacheReason: "ready")

        #expect(await bridge.slotKVBytesClaim() == 1_000)
        #expect(await bridge.resliceAdmissionBytesClaim() == 1_000)
        #expect(bridge.exactPrefixCacheFixedCarveBytes() == 100)

        await bridge.updateKVBytesCapacity(700)
        #expect(engine.capacity().kvBytesCapacity == 600)
        #expect(await bridge.slotKVBytesClaim() == 700)
        #expect(await bridge.resliceAdmissionBytesClaim() == 700)
        await bridge.shutdown()
    }

    @Test("re-slice floor is evaluated after the fixed exact-cache carve")
    func resliceFloorIncludesCarve() {
        let floor = Int(EngineV2KVSizing.minimumServiceableGrantBytes)
        #expect(
            EngineV2KVSizing.resliceMeetsServiceabilityFloor(
                ["qwen": floor + 100],
                fixedCarveBytes: ["qwen": 100]))
        #expect(
            !EngineV2KVSizing.resliceMeetsServiceabilityFloor(
                ["qwen": floor],
                fixedCarveBytes: ["qwen": 100]))
    }

    @Test("artifact, policy, backend, and dtype changes invalidate identities")
    func identityChanges() throws {
        func identity(
            weight: String = exactWeightA,
            prompt: String = exactPromptA,
            backend: EngineV2KVBackendKind = .contiguous,
            dtype: String? = nil,
            policy: String = EngineV2SlotFactory.exactPrefixCachePolicyDomain
        ) throws -> EngineV2SlotFactory.ExactPrefixCacheIdentity {
            try EngineV2SlotFactory.exactPrefixCacheIdentity(
                modelId: "qwen",
                weightHash: weight,
                promptContractID: prompt,
                backend: backend,
                backendDType: dtype,
                policyDomain: policy
            ).get()
        }

        let base = try identity()
        #expect(try identity(weight: exactWeightB).modelIdentity != base.modelIdentity)
        #expect(try identity(prompt: exactPromptB).modelIdentity != base.modelIdentity)
        #expect(try identity(backend: .paged).policyIdentity != base.policyIdentity)
        #expect(try identity(dtype: "float16").policyIdentity != base.policyIdentity)
        #expect(
            try identity(policy: "darkbloom.cbv2-exact-prompt-state-v2")
                .policyIdentity != base.policyIdentity)
    }

    @Test("legacy attention cache remains isolated from exact-state policy")
    func legacyIsolation() {
        let legacyDecision = EngineV2SlotFactory.exactPrefixCacheDecision(
            modelId: "gemma",
            capabilities: .attentionOnly,
            backend: .contiguous,
            backendDType: nil,
            weightHash: exactWeightA,
            promptContractID: exactPromptA,
            slotKVBytesCapacity: 8_000,
            configuration: .init(
                enabled: true, maxBytes: 1_000, maxFraction: 0.25),
            minimumEngineKVBytes: 1_000)
        #expect(!legacyDecision.isActive)
        #expect(legacyDecision.reason == .unsupportedModel)
        #expect(legacyDecision.cacheBudgetBytes == 0)
        #expect(legacyDecision.engineKVBytesCapacity == 8_000)
        #expect(
            EngineV2Factory.prefixCacheIsSupported(
                capabilities: .attentionOnly, prefixCache: PrefixCacheV2()))

        let exact = ExactPrefixCacheV2(
            config: .init(modelIdentity: "qwen", maxBytes: 0))
        #expect(
            !EngineV2Factory.prefixCacheIsSupported(
                capabilities: .attentionOnly, prefixCache: exact))
    }

    @Test("enabled malformed budgets fail closed without a carve")
    func invalidBudget() {
        let parsed = EngineV2SlotFactory.exactPrefixCacheConfiguration(
            environment: [
                EngineV2SlotFactory.exactPrefixCacheEnabledEnvironmentKey: "true",
                EngineV2SlotFactory.exactPrefixCacheMaxBytesEnvironmentKey: "not-an-int",
            ])
        let decision = EngineV2SlotFactory.exactPrefixCacheDecision(
            modelId: "qwen",
            capabilities: exactQwenCapabilities(),
            backend: .contiguous,
            backendDType: nil,
            weightHash: exactWeightA,
            promptContractID: exactPromptA,
            slotKVBytesCapacity: 8_000,
            configuration: parsed,
            minimumEngineKVBytes: 1_000)
        #expect(parsed.enabled)
        #expect(decision.reason == .invalidBudget)
        #expect(decision.cacheBudgetBytes == 0)
        #expect(decision.engineKVBytesCapacity == 8_000)
    }
}
