import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Native execution with independent checkpoint precision")
struct NativeCheckpointQuantizationTests {
    private let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 2)]

    private func pagedConfig(quantization: PagedKVQuantizationConfig? = nil) -> PagedKVPoolConfig {
        PagedKVPoolConfig(pageSize: 16, capacityBytes: 1 << 20, maxBufferLength: 1 << 20,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32], quantization: quantization)
    }

    private func identity(_ storage: CompleteCheckpointStorageIdentity) throws -> CBv2CompleteCheckpointIdentity {
        try #require(PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractID: String(repeating: "b", count: 64),
            binaryHash: String(repeating: "c", count: 64),
            loadedMetallibHash: String(repeating: "d", count: 64), osVersion: "test-os",
            mtpConfig: .init(enabled: false), assistantCodecID: nil,
            environment: [:], processEnvironment: [:], storage: storage))
    }

    @Test(arguments: [EngineV2KVBackendKind.paged, .contiguous])
    func checkpointProfileBindsIdentityWithoutChangingLiveStorage(kind: EngineV2KVBackendKind) throws {
        let config = kind == .paged ? pagedConfig() : nil
        var fingerprints = Set<String>()
        var namespaces = Set<String>()
        for selection in EngineV2KVQuantizationSelection.allCases {
            let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
                kind: kind, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
                modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: config, assistant: .none,
                checkpointQuantization: selection.configuration))
            #expect(storage.checkpointQuantization == selection.configuration)
            #expect(storage.fingerprintFields["storage.quantization"] == (selection.configuration?.identity ?? "native"))
            let expectedLayout = kind == .paged
                ? (selection == .native ? CBv2CompleteCheckpointManifest.pagedLayout
                    : CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout)
                : (selection == .native ? CBv2CompleteCheckpointManifest.layout
                    : CBv2CompleteCheckpointManifest.nativeQuantizedContiguousLayout)
            #expect(storage.backendLayout == expectedLayout)
            let resolved = try identity(storage)
            fingerprints.insert(resolved.numericsFingerprint)
            namespaces.insert(SSDHybridCheckpointStoreFactory.namespace(
                modelId: "native-target", identity: resolved, backendLayout: storage.backendLayout))
            #expect(config?.quantization == nil, "Storage encoding never modifies live pool precision")
            if let config {
                #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
                    layerKinds: kinds, dtypes: [.float32], config: config) == 512,
                    "Compressed disk bytes are never native RAM credit")
            }
        }
        #expect(fingerprints.count == EngineV2KVQuantizationSelection.allCases.count)
        #expect(namespaces.count == EngineV2KVQuantizationSelection.allCases.count)
    }

    @Test(arguments: [EngineV2KVBackendKind.paged, .contiguous])
    func statelessHistoricalTargetsUseTheirActualNativeLayout(kind: EngineV2KVBackendKind) throws {
        for selection in [EngineV2KVQuantizationSelection.native, .balanced] {
            let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
                kind: kind, layerKinds: kinds, supportsRecurrent: false, supportsHistoricalAttention: true,
                modelDTypes: nil, nativeDTypes: [.float32], pagedConfig: kind == .paged ? pagedConfig() : nil,
                assistant: .stateless, checkpointQuantization: selection.configuration))
            let expectedLayout = kind == .paged
                ? (selection == .native ? CBv2CompleteCheckpointManifest.historicalAttentionLayout
                    : CBv2CompleteCheckpointManifest.nativeQuantizedHistoricalLayout)
                : (selection == .native ? CBv2CompleteCheckpointManifest.nativeContiguousHistoricalLayout
                    : CBv2CompleteCheckpointManifest.nativeQuantizedContiguousHistoricalLayout)
            #expect(storage.backendLayout == expectedLayout)
            #expect(storage.checkpointQuantization == selection.configuration)
        }
    }

    @Test(arguments: [EngineV2KVBackendKind.paged, .contiguous])
    func historicalTargetsPreserveDTypeAndAssistantRequirements(kind: EngineV2KVBackendKind) {
        func resolve(
            modelDTypes: [DType]? = nil, nativeDTypes: [DType]? = [.float32],
            assistant: EngineV2SlotFactory.CompleteCheckpointAssistant = .none
        ) -> CompleteCheckpointStorageIdentity? {
            EngineV2SlotFactory.completeCheckpointStorage(
                kind: kind, layerKinds: kinds, supportsRecurrent: false, supportsHistoricalAttention: true,
                modelDTypes: modelDTypes, nativeDTypes: nativeDTypes,
                pagedConfig: kind == .paged ? pagedConfig() : nil, assistant: assistant)
        }
        #expect(resolve() != nil)
        #expect(resolve(modelDTypes: [.float32]) != nil)
        #expect((resolve(modelDTypes: [.float16]) != nil) == (kind == .paged))
        #expect(resolve(nativeDTypes: nil) == nil)
        #expect(resolve(nativeDTypes: []) == nil)
        #expect(resolve(nativeDTypes: [.float32, .float32]) == nil)
        for assistant in [EngineV2SlotFactory.CompleteCheckpointAssistant.persistentCodec, .unsupportedPersistent] {
            #expect(resolve(assistant: assistant) == nil)
        }
    }

    @Test func unsupportedEncodingKeepsNativeCheckpointEligibility() throws {
        let requested = EngineV2KVQuantizationSelection.balanced.configuration
        let assistant = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: pagedConfig(),
            assistant: .persistentCodec, checkpointQuantization: requested))
        #expect(assistant.checkpointQuantization == nil)
        #expect(assistant.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        for configuration in [requested, PagedKVQuantizationConfig(keyBits: 3)] {
            let unsupported = try #require(EngineV2SlotFactory.completeCheckpointStorage(
                kind: .paged,
                layerKinds: [.init(attention: .full, headDim: 96, kvHeads: 1, queryHeads: 2)],
                supportsRecurrent: true, supportsHistoricalAttention: false,
                modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: pagedConfig(),
                assistant: .none, checkpointQuantization: configuration))
            #expect(unsupported.checkpointQuantization == nil)
            #expect(unsupported.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        }
    }

    /// An exact-history assistant (the Super and GLM MTP owners) keeps its
    /// history native beside lossy older rows, in the distinct MTP layout,
    /// only on paged recurrent storage; contiguous storage stays native.
    @Test func exactHistoryAssistantsSelectTheMTPLayoutOnlyWhenPaged() throws {
        let requested = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
        let paged = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: pagedConfig(),
            assistant: .persistentExactHistory, checkpointQuantization: requested))
        #expect(paged.checkpointQuantization == requested)
        #expect(paged.backendLayout == CBv2CompleteCheckpointManifest.nativeQuantizedPagedMTPLayout)
        #expect(paged.fingerprintFields["storage.layout"] == paged.backendLayout)
        let native = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: pagedConfig(),
            assistant: .persistentExactHistory, checkpointQuantization: nil))
        #expect(native.checkpointQuantization == nil)
        #expect(native.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        #expect(try identity(native).numericsFingerprint != (try identity(paged).numericsFingerprint))
        let contiguous = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .contiguous, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: nil,
            assistant: .persistentExactHistory, checkpointQuantization: requested))
        #expect(contiguous.checkpointQuantization == nil)
        #expect(contiguous.backendLayout == CBv2CompleteCheckpointManifest.layout)
        // Historical targets admit only absent or stateless assistants.
        #expect(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: false, supportsHistoricalAttention: true,
            modelDTypes: nil, nativeDTypes: [.float32], pagedConfig: pagedConfig(),
            assistant: .persistentExactHistory, checkpointQuantization: requested) == nil)
        for assistant in [EngineV2SlotFactory.CompleteCheckpointAssistant.none, .stateless] {
            #expect(!assistant.keepsNativeStorage(pagedRecurrent: false))
        }
        for assistant in [EngineV2SlotFactory.CompleteCheckpointAssistant.persistentCodec, .unsupportedPersistent] {
            #expect(assistant.keepsNativeStorage(pagedRecurrent: true))
        }
        #expect(!EngineV2SlotFactory.CompleteCheckpointAssistant.persistentExactHistory
            .keepsNativeStorage(pagedRecurrent: true))
        #expect(EngineV2SlotFactory.CompleteCheckpointAssistant.persistentExactHistory
            .keepsNativeStorage(pagedRecurrent: false))
    }

    /// GLM's own full-state identity: a resolved profile selects the distinct
    /// lossy GLM layout and namespace; nil keeps the exact v2 layout.
    @Test func glmProfileSelectsItsLossyFullStateLayout() throws {
        let glmKinds = [CBv2LayerKind(
            attention: .full, headDim: 64, valueHeadDim: 5, kvHeads: 1, queryHeads: 2, modelLayerIndex: 3)]
        let limits = try CBv2PagedGatheredAttentionLimits(
            maximumBatchSize: 1, maximumQueryTokens: 16, maximumContextTokens: 64,
            maximumInFlightGraphs: 2, maximumScratchBytes: 1 << 20,
            admissionMode: .stepOwned(.pinnedMetal))
        let config = PagedKVPoolConfig(pageSize: 16, capacityBytes: 1 << 20, maxBufferLength: 1 << 20,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32], gatheredAttention: limits)
        let requested = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
        let resolved = try #require(CBv2CompleteCheckpointStorageQuantization.resolveGLM5Next(
            requested, layerKinds: glmKinds, pagedConfig: config, assistant: nil))
        let lossy = try #require(CompleteCheckpointStorageIdentity(kind: .paged, layerDTypes: [.float32],
            pagedConfig: config, target: .glm5Next(glmKinds), checkpointQuantization: resolved))
        let exact = try #require(CompleteCheckpointStorageIdentity(kind: .paged, layerDTypes: [.float32],
            pagedConfig: config, target: .glm5Next(glmKinds)))
        #expect(lossy.backendLayout == CBv2CompleteCheckpointManifest.glm5NextQuantizedPagedLayout)
        #expect(exact.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
        #expect(lossy.fingerprintFields["storage.quantization"] == requested.identity)
        #expect(exact.fingerprintFields["storage.quantization"] == "native")
        #expect(try identity(lossy).numericsFingerprint != (try identity(exact).numericsFingerprint))
        // A persistent assistant without the exact-history contract keeps GLM exact.
        #expect(CBv2CompleteCheckpointStorageQuantization.resolveGLM5Next(
            requested, layerKinds: glmKinds, pagedConfig: config, assistant: NSObject()) == nil)
    }

    @Test func explicitLivePackedCheckpointRetainsItsOriginalEncoding() throws {
        let liveFormat = try #require(EngineV2KVQuantizationSelection.k8v4.configuration)
        let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: pagedConfig(quantization: liveFormat),
            assistant: .none, checkpointQuantization: EngineV2KVQuantizationSelection.k8v8.configuration))
        #expect(storage.checkpointQuantization == nil)
        #expect(storage.backendLayout == CBv2CompleteCheckpointManifest.quantizedPagedLayout)
        #expect(storage.fingerprintFields["storage.quantization"] == liveFormat.identity)
    }

    @Test func allNativeOwnersDoNotClaimCompressedStorage() throws {
        var config = pagedConfig()
        config.nativeLayerIndices = [0]
        let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged, layerKinds: kinds, supportsRecurrent: true, supportsHistoricalAttention: false,
            modelDTypes: [.float32], nativeDTypes: [.float32], pagedConfig: config, assistant: .none,
            checkpointQuantization: EngineV2KVQuantizationSelection.balanced.configuration))
        #expect(storage.checkpointQuantization == nil)
        #expect(storage.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
    }

    @Test func smallHistoricalWindowRetainsNativeStorage() throws {
        let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: .paged,
            layerKinds: [.init(attention: .slidingWindow(64), headDim: 64, kvHeads: 1, queryHeads: 2)],
            supportsRecurrent: false, supportsHistoricalAttention: true,
            modelDTypes: nil, nativeDTypes: [.float32], pagedConfig: pagedConfig(), assistant: .none,
            checkpointQuantization: EngineV2KVQuantizationSelection.balanced.configuration))
        #expect(storage.checkpointQuantization == nil)
        #expect(storage.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
    }

    @Test func newEncodingsRemainEligibleForEncryptedSSDStores() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("native-checkpoint-layouts-\(UUID().uuidString)")
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let binding = CBv2CompleteCheckpointIdentity(modelAggregateHash: "weights", promptContractID: "prompt",
            buildID: "build", numericsFingerprint: "numerics")
        for layout in [CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout,
                       CBv2CompleteCheckpointManifest.nativeQuantizedPagedMTPLayout,
                       CBv2CompleteCheckpointManifest.glm5NextQuantizedPagedLayout,
                       CBv2CompleteCheckpointManifest.nativeQuantizedHistoricalLayout,
                       CBv2CompleteCheckpointManifest.nativeQuantizedContiguousLayout,
                       CBv2CompleteCheckpointManifest.nativeQuantizedContiguousHistoricalLayout,
                       CBv2CompleteCheckpointManifest.nativeContiguousHistoricalLayout] {
            let store = try #require(await SSDHybridCheckpointStoreFactory.make(
                modelId: "native-target", identity: binding, backendLayout: layout, kvBudget: nil,
                environment: [SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
                              "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"]))
            #expect(store.config.backendLayout == layout)
            #expect(store.identity == binding)
            await store.closeAndWait()
        }
    }
}
