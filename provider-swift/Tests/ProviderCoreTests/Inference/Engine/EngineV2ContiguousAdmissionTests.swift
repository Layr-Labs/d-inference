import Foundation
import MLX
import MLXLLM
import MLXNN
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Native contiguous admission is independent of checkpoint storage", .serialized)
struct EngineV2ContiguousAdmissionTests {
    private let capacity = 4 << 20
    private let contextTokens = 8_192
    private let modelID = "native-contiguous-admission-fixture"

    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    private func model(layerCount: Int = 2) throws -> Gemma4TextModel {
        let configuration = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: Data("""
            {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":\(layerCount),
             "intermediate_size":128,"num_attention_heads":4,"num_key_value_heads":2,
             "head_dim":64,"global_head_dim":64,"num_kv_shared_layers":0,
             "vocab_size":128,"hidden_size_per_layer_input":0,"sliding_window":16,
             "sliding_window_pattern":2,"max_position_embeddings":8192,"use_double_wide_mlp":false}
            """.utf8))
        return Gemma4TextModel(configuration)
    }

    @Test("uncached native auto refuses a 6k prompt whose FP32 KV cannot fit a 4 MiB grant")
    func uncachedAutoUsesObservedFP32Sizes() async throws {
        let target = try model()
        let build = try EngineV2Factory.makeProductionBuild(
            model: target, modelID: modelID, tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: capacity, maxConcurrentRequests: 1,
            kvBackend: .auto, maxContextLength: contextTokens,
            environment: [PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null"])
        let engine = try #require(build.engine as? EngineV2)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvQuantization == .native)
        #expect(engine.completePrefixCache == nil)
        #expect(engine.capacity().pagedStorage == nil)
        let admission = engine.admissionForTesting
        #expect(admission.fullKVBytesPerToken == 1_024)
        #expect(admission.allocatedBytes(forTokens: 6_001) == (6_001 + 16) * 1_024)
        #expect(!admission.canEverFit(promptTokens: 6_000, maxTokens: 1))
        #expect(admission.canEverFit(promptTokens: 1_024, maxTokens: 1))
        await engine.shutdown()
    }

    @Test("cache-off and failed SSD initialization preserve native admission and bridge rates",
          arguments: [false, true])
    func optionalCacheDoesNotOwnMemorySafety(failStore: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("contiguous-admission-\(UUID().uuidString)")
        if failStore {
            // A regular file cannot contain the store's model directory.
            try Data([0]).write(to: root)
        }
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let target = try model()
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(context: .init(
            configuration: ModelConfiguration(id: modelID), model: target,
            processor: ContiguousAdmissionProcessor(), tokenizer: tokenizer))
        let preparedModel = EngineV2PreparedModel(
            snapshot: .init(model: target, eosTokenIds: [1], extraEOSTokens: []),
            servingModel: target, assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil)
        let hash = String(repeating: "a", count: 64)
        let contract = "contiguous-admission-test-contract"
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: "gemma4_text", isVLM: false, modelDirectory: nil,
            container: container, tokenizer: TokenizerHandle(tokenizer),
            sizing: .init(weightsBytes: 1, fp16KVBytesPerToken: 512,
                          maxContextLength: contextTokens, defaultMaxTokens: 32),
            kvBytesCapacity: capacity, maxConcurrentRequests: 1, kvBudget: nil,
            weightHash: hash,
            specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(promptContractID: contract,
                completeCheckpointIdentity: .init(modelAggregateHash: hash, promptContractID: contract,
                    buildID: "contiguous-admission-test", numericsFingerprint: "native-fp32")),
            environment: [PrefixCachePolicy.environmentFlag: failStore ? "1" : "0",
                          "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                          SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
                          KVBackendGuardStore.pathEnvKey: "/dev/null"])
        let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
        #expect(await bundle.bridge.kvBackendKind == .contiguous)
        #expect(bundle.bridge.ssdHybridCheckpointStore == nil)
        // A refused store's heartbeat status names the disk problem and carries its cause.
        let prefixStatus = bundle.bridge.prefixCacheModelStatus()
        #expect(prefixStatus.reason == (failStore ? .diskUnavailable : .configDisabled))
        #expect(prefixStatus.detail == (failStore ? .unsafePath : nil))
        #expect(engine.admissionForTesting.fullKVBytesPerToken == 1_024)
        #expect(!engine.admissionForTesting.canEverFit(promptTokens: 6_000, maxTokens: 1))
        #expect(await bundle.bridge.kvBytesPerToken == 1_024)
        let reported = await bundle.bridge.backendSlotCapacity()
        #expect(reported.kvBytesPerToken == 1_024)
        #expect(reported.activeTokenBudgetMax <= Int64(capacity / 1_024))
        await bundle.bridge.shutdown()
    }

    @Test("mixed native dtypes price full rows and fixed windows from the same observed table")
    func mixedNativeRowsAndWindowsUseObservedSizes() async throws {
        let target = try model()
        let parameters = target.parameters().flattened()
        #expect(parameters.contains { $0.0.contains(".layers.1.") })
        target.update(parameters: ModuleParameters.unflattened(parameters.map {
            ($0.0, $0.1.asType($0.0.contains(".layers.1.") ? .float32 : .bfloat16))
        }))
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: target, modelID: modelID, kvBytesCapacity: capacity, maxConcurrentRequests: 1,
            kvBackend: .auto, maxContextLength: contextTokens,
            environment: [PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null"])
        #expect(prepared.kind == .contiguous)
        #expect(prepared.nativeLayerDTypes == [.bfloat16, .float32])
        let build = try EngineV2Factory.assembleProductionBuild(
            model: target, tokenizer: StubBridgeTokenizer(), prefixCache: nil,
            maxConcurrentRequests: 1, mtpDrafter: nil, mtpConfig: .init(enabled: false),
            preparedBackend: prepared)
        let engine = try #require(build.engine as? EngineV2)
        let admission = engine.admissionForTesting
        #expect(admission.fullKVBytesPerToken == 1_024)
        #expect(admission.allocatedBytes(forTokens: 10) == 10 * 1_024 + 16 * 512)
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: prepared.kind, pagedPoolDType: nil,
            nativeLayerDTypes: prepared.nativeLayerDTypes, layerKinds: prepared.layerKinds,
            nominalFP16BytesPerToken: 512, servingModelIsGPTOSS: false) == admission.fullKVBytesPerToken)
        #expect(engine.completePrefixCache == nil)
        await engine.shutdown()
    }

    @Test("missing native storage observations refuse construction rather than assume two-byte KV")
    func unresolvedNativeStorageRefusesConstruction() throws {
        #expect(throws: CBv2KVError.self) {
            _ = try EngineV2Factory.makeProductionBuild(
                model: model(layerCount: 0), tokenizer: StubBridgeTokenizer(),
                kvBytesCapacity: capacity, maxConcurrentRequests: 1,
                kvBackend: .contiguous, environment: [PrefixCachePolicy.environmentFlag: "0"])
        }
    }
}

private struct ContiguousAdmissionProcessor: UserInputProcessor {
    private struct UnusedInput: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw UnusedInput() }
}
