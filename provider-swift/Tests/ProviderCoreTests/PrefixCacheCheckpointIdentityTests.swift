import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Complete checkpoint identity")
struct PrefixCacheCheckpointIdentityTests {
    private func identity(
        model: String? = String(repeating: "a", count: 64),
        prompt: String? = String(repeating: "b", count: 64),
        binary: String? = String(repeating: "c", count: 64),
        metallib: String? = String(repeating: "d", count: 64),
        os: String = "test-os",
        mtp: CBv2MTPConfig = .init(enabled: true),
        codec: String? = "qwen-test-v1",
        environment: [String: String] = [:],
        process: [String: String] = [:],
        storage: CompleteCheckpointStorageIdentity? = nil
    ) -> CBv2CompleteCheckpointIdentity? {
        PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: model, promptContractID: prompt,
            binaryHash: binary, loadedMetallibHash: metallib, osVersion: os,
            mtpConfig: mtp, assistantCodecID: codec,
            environment: environment, processEnvironment: process, storage: storage)
    }

    @Test("Missing or malformed verified identities fail cold")
    func missingIdentity() {
        for invalid in [nil, "", "model-name", String(repeating: "a", count: 63),
            String(repeating: "G", count: 64), String(repeating: "A", count: 64),
            " " + String(repeating: "a", count: 64)] as [String?] {
            #expect(identity(model: invalid) == nil)
            #expect(identity(prompt: invalid) == nil)
            #expect(identity(binary: invalid) == nil)
            #expect(identity(metallib: invalid) == nil)
        }
        #expect(identity(os: "") == nil)
    }

    @Test("Artifact, codec and numerical changes cannot reuse a disk identity")
    func compatibilityBindings() throws {
        let base = try #require(identity())
        #expect(base.modelAggregateHash == String(repeating: "a", count: 64))
        #expect(base.promptContractID == String(repeating: "b", count: 64))
        #expect(base.buildID.count == 64)
        #expect(base.numericsFingerprint.count == 64)
        let replacement = String(repeating: "e", count: 64)
        #expect(identity(model: replacement) != base)
        #expect(identity(prompt: replacement) != base)
        #expect(identity(binary: replacement)?.buildID != base.buildID)
        #expect(identity(metallib: replacement)?.buildID != base.buildID)
        #expect(identity(os: "another-os")?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(codec: "qwen-test-v2")?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(codec: nil)?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(mtp: .init(enabled: false))?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(mtp: .init(enabled: true, fixedDraftTokens: 2))?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(mtp: .init(enabled: true, verificationMode: .serialTarget))?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(environment: ["MLX_METAL_FAST_SYNCH": "1"])?.numericsFingerprint != base.numericsFingerprint)
        #expect(identity(process: ["DARKBLOOM_QWEN_KERNEL": "1"])?.numericsFingerprint != base.numericsFingerprint)
    }

    @Test("Model optimization changes separate persistent checkpoint namespaces", arguments: [
        "DARKBLOOM_GPTOSS_FUSED_GATE_UP",
        "DARKBLOOM_GPTOSS_COMPILED_EXPERTS",
        "DARKBLOOM_GPTOSS_PREFILL_OUTPUT",
        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL",
        "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY",
        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK",
        "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
    ])
    func modelOptimizationChanges(key: String) throws {
        let base = try #require(identity())
        let optimized: String
        let rollback: String
        switch key {
        case "DARKBLOOM_GPTOSS_PREFILL_OUTPUT":
            optimized = "last"
            rollback = "full"
        case "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK":
            optimized = "128"
            rollback = "256"
        default:
            optimized = "1"
            rollback = "0"
        }
        func namespace(_ value: CBv2CompleteCheckpointIdentity) -> String {
            SSDHybridCheckpointStoreFactory.namespace(modelId: "test-model", identity: value,
                backendLayout: CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        }
        for processSetting in [false, true] {
            func configured(_ value: String) throws -> CBv2CompleteCheckpointIdentity {
                try #require(identity(
                    environment: processSetting ? [:] : [key: value],
                    process: processSetting ? [key: value] : [:]))
            }
            let enabled = try configured(optimized)
            let disabled = try configured(rollback)
            #expect(enabled.buildID == disabled.buildID && disabled.buildID == base.buildID)
            #expect(enabled.modelAggregateHash == disabled.modelAggregateHash)
            #expect(enabled.numericsFingerprint != disabled.numericsFingerprint)
            #expect(namespace(enabled) != namespace(disabled))
            #expect(namespace(base) != namespace(disabled))
            #expect(try configured(rollback) == disabled)
        }
    }

    @Test("Fingerprints are ordered, unambiguous and independent of unrelated settings")
    func canonicalSettings() {
        let settings = ["MLX_TEST_A": "bc", "DARKBLOOM_CBV2_TEST_B": "d"]
        let reversed = Dictionary(uniqueKeysWithValues: settings.sorted { $0.key > $1.key })
        #expect(identity(environment: settings) == identity(environment: reversed))
        #expect(identity(environment: settings) != identity(process: settings))
        #expect(identity(environment: ["MLX_TEST_A": "bc"]) != identity(environment: ["MLX_TEST_Ab": "c"]))
        #expect(identity(environment: ["LOG_LEVEL": "debug", "UNRELATED_SECRET": "never-hashed"]) == identity())
        #expect(identity(process: ["HOME": "/different/home"]) == identity())
    }

    @Test("actual backend, precision and page geometry separate disk namespaces")
    func storageNamespace() throws {
        let contiguous = try #require(CompleteCheckpointStorageIdentity(
            kind: .contiguous, layerDTypes: [.float16, .float32], pagedConfig: nil))
        let config = PagedKVPoolConfig(
            pageSize: 16, capacityBytes: 1 << 20, maxBufferLength: 1 << 20,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float16, .float32])
        let paged = try #require(CompleteCheckpointStorageIdentity(
            kind: .paged, layerDTypes: [.float16, .float32], pagedConfig: config))
        let contiguousID = try #require(identity(storage: contiguous))
        let pagedID = try #require(identity(storage: paged))
        #expect(contiguousID != pagedID)
        let namespace = SSDHybridCheckpointStoreFactory.namespace(
            modelId: "model", identity: pagedID, backendLayout: paged.backendLayout)
        #expect(namespace != SSDHybridCheckpointStoreFactory.namespace(
            modelId: "model", identity: contiguousID, backendLayout: contiguous.backendLayout))
        #expect(SSDHybridCheckpointEnvelope.layoutEpoch(identity: pagedID, backendLayout: paged.backendLayout)
            != SSDHybridCheckpointEnvelope.layoutEpoch(identity: pagedID, backendLayout: contiguous.backendLayout))
        for change in 0 ..< 3 {
            var other = config
            if change == 0 { other.pageSize = 32 }
            if change == 1 { other.segmentSizeBytes = 128 << 10 }
            if change == 2 { other.layerDTypes = [.float32, .float16] }
            let storage = try #require(CompleteCheckpointStorageIdentity(
                kind: .paged, layerDTypes: other.layerDTypes!, pagedConfig: other))
            let changed = try #require(identity(storage: storage))
            #expect(changed != pagedID)
            #expect(SSDHybridCheckpointStoreFactory.namespace(
                modelId: "model", identity: changed, backendLayout: storage.backendLayout) != namespace)
        }
        #expect(CompleteCheckpointStorageIdentity(
            kind: .paged, layerDTypes: [.float16, .float16], pagedConfig: config) == nil)
        var fixed = config
        fixed.segmentSizeBytes = nil
        #expect(CompleteCheckpointStorageIdentity(
            kind: .paged, layerDTypes: [.float16, .float32], pagedConfig: fixed) == nil)
        var resized = config
        resized.capacityBytes *= 2
        let sameStorage = try #require(CompleteCheckpointStorageIdentity(
            kind: .paged, layerDTypes: [.float16, .float32], pagedConfig: resized))
        #expect(identity(storage: sameStorage) == pagedID)
    }
    @Test("Historical native owner maps and attention geometry bind the disk namespace")
    func historicalStorageNamespace() throws {
        let kinds = [
            CBv2LayerKind(attention: .slidingWindow(128), headDim: 64, kvHeads: 1, queryHeads: 2, modelLayerIndex: 2),
            CBv2LayerKind(attention: .full, hasSinks: true, headDim: 64, kvHeads: 1, queryHeads: 2, modelLayerIndex: 4),
            CBv2LayerKind(attention: .slidingWindow(128), sharesKVWithLayer: 0,
                          headDim: 64, kvHeads: 1, queryHeads: 2, modelLayerIndex: 6),
        ]
        let config = PagedKVPoolConfig(pageSize: 16, capacityBytes: 1 << 20,
            maxBufferLength: 1 << 20, segmentSizeBytes: 64 << 10, layerDTypes: Array(repeating: .float16, count: 3))
        func storage(_ kinds: [CBv2LayerKind], _ types: [DType] = Array(repeating: .float16, count: 3))
            -> CompleteCheckpointStorageIdentity?
        {
            var config = config
            config.layerDTypes = types
            return .init(kind: .paged, layerDTypes: types, pagedConfig: config, target: .historicalAttention(kinds))
        }
        let base = try #require(storage(kinds))
        #expect(base.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(base.fingerprintFields["storage.attention.2.owner"] == "0")
        #expect(base.fingerprintFields["storage.attention.1.modelLayer"] == "4")
        let baseID = try #require(identity(codec: nil, storage: base))
        let namespace = SSDHybridCheckpointStoreFactory.namespace(modelId: "target", identity: baseID,
                                                                  backendLayout: base.backendLayout)
        for change in 0 ..< 8 {
            var modified = kinds
            var types = Array(repeating: DType.float16, count: 3)
            switch change {
            case 0: modified[2].sharesKVWithLayer = nil
            case 1: modified[0].attention = .slidingWindow(256); modified[2].attention = .slidingWindow(256)
            case 2: modified[1].hasSinks = false
            case 3: modified[1].modelLayerIndex = 5
            case 4: modified[1].queryHeads = 4
            case 5: modified[1].headDim = 128
            case 6: modified[1].kvHeads = 2
            default: types[1] = .float32
            }
            let changedStorage = try #require(storage(modified, types))
            let changed = try #require(identity(codec: nil, storage: changedStorage))
            #expect(changed != baseID)
            #expect(SSDHybridCheckpointStoreFactory.namespace(modelId: "target", identity: changed,
                backendLayout: changedStorage.backendLayout) != namespace)
        }
        let recurrent = try #require(CompleteCheckpointStorageIdentity(
            kind: .paged, layerDTypes: config.layerDTypes!, pagedConfig: config))
        #expect(identity(codec: nil, storage: recurrent) != baseID)
        #expect(SSDHybridCheckpointEnvelope.layoutEpoch(identity: baseID, backendLayout: recurrent.backendLayout)
            != SSDHybridCheckpointEnvelope.layoutEpoch(identity: baseID, backendLayout: base.backendLayout))
        // The historical target payload does not disable Gemma's normal MTP.
        #expect(identity(mtp: .init(enabled: false), codec: nil, storage: base) != baseID)
        #expect(identity(mtp: .init(enabled: true, fixedDraftTokens: 2), codec: nil, storage: base) != baseID)
    }

    @Test("Historical eligibility refuses incompatible native mappings and storage")
    func historicalStorageRefusal() {
        let window = CBv2LayerKind(attention: .slidingWindow(128), headDim: 64, kvHeads: 1, queryHeads: 2)
        let kinds = [window, CBv2LayerKind(attention: .slidingWindow(128), sharesKVWithLayer: 0,
                                         headDim: 64, kvHeads: 1, queryHeads: 2)]
        let config = PagedKVPoolConfig(capacityBytes: 1 << 20, segmentSizeBytes: 64 << 10,
                                       layerDTypes: [.float16, .float16])
        for change in 0 ..< 6 {
            var modified = kinds
            switch change {
            case 0: modified[1].sharesKVWithLayer = 1
            case 1: modified[1].sharesKVWithLayer = 2
            case 2: modified[1].attention = .full
            case 3: modified[0].isBidirectional = true
            case 4: modified[1].modelLayerIndex = 0
            default: modified[0].headDim = 32
            }
            #expect(CompleteCheckpointStorageIdentity(kind: .paged, layerDTypes: [.float16, .float16],
                pagedConfig: config, target: .historicalAttention(modified)) == nil)
        }
        #expect(CompleteCheckpointStorageIdentity(kind: .contiguous, layerDTypes: [.float16, .float16],
            pagedConfig: nil, target: .historicalAttention(kinds)) == nil)
        #expect(CompleteCheckpointStorageIdentity(kind: .paged, layerDTypes: [.float16, .float32],
            pagedConfig: config, target: .historicalAttention(kinds)) == nil)
    }

}
