import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Paged KV quantization configuration and accounting", .serialized)
struct EngineV2KVQuantizationPolicyTests {
    @Test func defaultsAndRetiredKnobRemainNative() throws {
        let config = ConfigManager.parse("[backend]\nkv_quant = true\n")
        #expect(config.backend.engineV2KVQuantization == "native")
        #expect(config.backend.engineV2KVQuantizationByModel.isEmpty)
        #expect(config.backend.retiredKeysPresent == ["kv_quant"])
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(modelID: "qwen3.6-35b-a3b-vl-mtp-mxfp8") == .native)
        #expect(EngineV2KVQuantizationSelection.native.configuration == nil)
    }

    @Test func exactModelOverrideAndRoundTrip() throws {
        var config = ProviderConfig(provider: ProviderSettings(name: "quantization-test"))
        config.backend.engineV2KVQuantization = "int4"
        config.backend.engineV2KVQuantizationByModel = ["gpt-oss-20b": "k8v4", "rollback": "native"]
        let decoded = ConfigManager.parse(ConfigManager.serialize(config))
        #expect(decoded.backend.engineV2KVQuantization == "int4")
        #expect(decoded.backend.engineV2KVQuantizationByModel == config.backend.engineV2KVQuantizationByModel)
        #expect(decoded.backend.engineV2MaxConcurrent == config.backend.engineV2MaxConcurrent)
        let overrides = decoded.backend.engineV2KVQuantizationByModel
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(global: " INT4 ", byModel: overrides, modelID: "gpt-oss-20b") == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(global: "int4", byModel: overrides, modelID: "gpt-oss-20b-other") == .int4)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(global: "int4", byModel: overrides, modelID: "rollback") == .native)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            try EngineV2KVQuantizationPolicy.parseSelection(global: "int4", byModel: ["m": "typo"], modelID: "m")
        }
    }

    @Test(arguments: [EngineV2KVQuantizationSelection.int4, .k8v4, .int8])
    func explicitFormatNeverFallsBackToNative(selection: EngineV2KVQuantizationSelection) throws {
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.paged, selection: selection)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: selection, reason: "kill_switch")
        }
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: .native)
    }

    @Test func marginalRateIncludesFP32MetadataAndOnlyFullOwners() throws {
        let kinds: [CBv2LayerKind] = [
            .init(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4),
            .init(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4),
            .init(attention: .slidingWindow(512), headDim: 64, kvHeads: 2, queryHeads: 4),
            .init(attention: .full, sharesKVWithLayer: 0, headDim: 64, kvHeads: 2, queryHeads: 4),
        ]
        let dtypes: [DType] = [.bfloat16, .float32, .float32, .bfloat16]
        for (selection, expected) in [(EngineV2KVQuantizationSelection.int4, 320), (.k8v4, 448), (.int8, 576)] {
            let rate = EngineV2SlotFactory.slotKVBytesPerToken(
                resolvedKind: .paged, pagedPoolDType: "mixed", pagedLayerDTypes: dtypes,
                pagedQuantization: selection.configuration, layerKinds: kinds,
                nominalFP16BytesPerToken: 1024, servingModelIsGPTOSS: false)
            #expect(rate == expected)
        }
        #expect(EngineV2Factory.nativeFullKVBytesPerToken(layerKinds: kinds, dtypes: dtypes) == 1536)
        #expect(EngineV2Factory.fullKVBytesPerToken(layerKinds: kinds, dtypes: [], quantization: .init()) == Int.max)
        #expect(EngineV2Factory.fullKVBytesPerToken(
            layerKinds: [.init(attention: .full, headDim: 63, kvHeads: 2, queryHeads: 4)],
            dtypes: [.float32], quantization: .init()) == Int.max)
    }

    @Test func checkpointNamespaceBindsTheExactPackedFormat() throws {
        func storage(_ quantization: PagedKVQuantizationConfig?) throws -> CompleteCheckpointStorageIdentity {
            try #require(CompleteCheckpointStorageIdentity(kind: .paged, layerDTypes: [.bfloat16],
                pagedConfig: .init(capacityBytes: 1 << 20, maxBufferLength: 1 << 20,
                    segmentSizeBytes: 64 << 10, layerDTypes: [.bfloat16], quantization: quantization)))
        }
        let native = try storage(nil)
        let int4 = try storage(.init())
        let k8v4 = try storage(.init(keyBits: 8, valueBits: 4))
        let noRotation = try storage(.init(rotationBlockSize: 0))
        #expect(native.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        #expect(int4.backendLayout == CBv2CompleteCheckpointManifest.quantizedPagedLayout)
        #expect(native.fingerprintFields["storage.quantization"] == nil)
        #expect(int4.fingerprintFields != k8v4.fingerprintFields)
        #expect(int4.fingerprintFields != noRotation.fingerprintFields)
        #expect(int4.fingerprintFields["storage.quantization"] == PagedKVQuantizationConfig().identity)
    }

    @Test func productionConstructorPreservesGrantAndNativeWindows() throws {
        let kinds: [CBv2LayerKind] = [
            .init(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4),
            .init(attention: .slidingWindow(512), headDim: 64, kvHeads: 2, queryHeads: 4),
            .init(attention: .full, sharesKVWithLayer: 0, headDim: 64, kvHeads: 2, queryHeads: 4),
        ]
        let types: [DType] = [.bfloat16, .float32, .bfloat16]
        let format = PagedKVQuantizationConfig(keyBits: 8, valueBits: 4)
        let grant = 256 << 20
        let backend = try EngineV2Factory.makeSegmentedPagedBackend(
            admittedGrantBytes: grant, layerKinds: kinds, layerDTypes: types,
            schedulerConfig: .init(maxConcurrentRequests: 4), maxContextLength: 8192,
            maxBufferLength: 128 << 20, quantization: format)
        #expect(backend.bytesCapacity == grant)
        #expect(backend.pool.bytesMaterialized == 0)
        #expect(backend.pool.config.layerDTypes == types)
        #expect(backend.pool.config.quantizedPrefillMode == .direct)
        #expect(backend.pool.groupKey(forLayer: 0).quantization == format)
        #expect(backend.pool.groupKey(forLayer: 1).quantization == nil)
        #expect(backend.pool.groupKey(forLayer: 2) == backend.pool.groupKey(forLayer: 0))
        #expect(try backend.pool.groupKey(forLayer: 0).bytesPerToken() ==
            EngineV2Factory.fullKVBytesPerToken(layerKinds: kinds, dtypes: types, quantization: format))
    }

    @Test func typedBenchmarkOverrideReachesTheNativePoolWithoutChangingStorageIdentity() throws {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 4)]
        let format = PagedKVQuantizationConfig()
        let backend = try EngineV2Factory.makeSegmentedPagedBackend(
            admittedGrantBytes: 64 << 20, layerKinds: kinds, layerDTypes: [.float32],
            schedulerConfig: .init(maxConcurrentRequests: 1), maxContextLength: 4096,
            maxBufferLength: 64 << 20, quantization: format,
            quantizedPrefillMode: .opportunisticSDPA)
        #expect(backend.pool.config.quantizedPrefillMode == .opportunisticSDPA)
        #expect(backend.pool.config.quantization?.identity == format.identity)
        #expect(backend.pool.bytesMaterialized == 0)
    }
}
