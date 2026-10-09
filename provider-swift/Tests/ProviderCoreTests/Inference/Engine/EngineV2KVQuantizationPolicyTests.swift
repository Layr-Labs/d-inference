import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2KVQuantizationPolicy")
struct EngineV2KVQuantizationPolicyTests {
    @Test(arguments: [
        "gpt-oss-20b", "Qwen3.5-9B", "ternary-bonsai-2-27b",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp",
        "gemma-4-26b", "gemma-4-26b-qat-4bit", "gemma-4-26b-8bit",
        "qwen3.5-35b-a3b", "nvidia-nemotron-3.5-lightning", "future-supported-model",
    ])
    func defaultIsGeometryIndependent(modelID: String) throws {
        let selection = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "supported", modelID: modelID, environment: [:])
        #expect(selection == .balanced)
        let configuration = try #require(selection.configuration)
        #expect(configuration.keyBits == 4 && configuration.valueBits == 4)
        #expect(configuration.groupSize == 64)
        #expect(configuration.recentTokenCount == 128)
        #expect(configuration.resolvedRotationBlockSize(headDim: 192) == 64)
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases.map(\.rawValue) + ["invalid"])
    func exactMiMoTypeIgnoresEveryOverride(raw: String) throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "mimo_v2", global: raw, byModel: ["arbitrary-alias": raw],
            modelID: "arbitrary-alias",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: raw]) == .native)
    }

    @Test func precedenceAndNativeOverride() throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"],
            modelID: "m", environment: [:]) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "balanced", byModel: ["m": "k8v4"], modelID: "m",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: " OFF "]) == .native)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection("k8v8").configuration?.valueBits == 8)
        #expect(EngineV2KVQuantizationSelection.native.configuration == nil)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            try EngineV2KVQuantizationPolicy.parseSelection("k4v44")
        }
    }

    @Test func quantizedConstructionCannotSilentlyBecomeNativeContiguous() throws {
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.paged, selection: .balanced)
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: .native)
        for selection in [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8] {
            #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
                try EngineV2KVQuantizationPolicy.requireResolvedBackend(
                    .contiguous, selection: selection, reason: "kill_switch")
            }
        }
    }

    @Test func oldConfigurationDefaultsAndExplicitPrecisionRoundtrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(BackendSettings.self, from: Data("{}".utf8))
            .engineV2KVQuantization == "balanced")
        let settings = BackendSettings(
            engineV2KVQuantization: "k8v4", engineV2KVQuantizationByModel: ["gpt-oss-20b": "native"])
        #expect(try decoder.decode(BackendSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func assistantNativeOwnersAndPhysicalMarginalRate() throws {
        let window = CBv2LayerKind(attention: .slidingWindow(1024), headDim: 64, kvHeads: 2, queryHeads: 4)
        let full = CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)
        let borrower = CBv2LayerKind(attention: .full, sharesKVWithLayer: 3,
            headDim: 64, kvHeads: 2, queryHeads: 4)
        let kinds = [window, full, window, full, borrower]
        #expect(EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: false).isEmpty)
        let native = EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: true)
        #expect(native == [2, 3])
        let format = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
        let config = PagedKVPoolConfig(capacityBytes: 64 << 20,
            quantization: format, nativeLayerIndices: native)
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: kinds, dtypes: [.bfloat16, .bfloat16, .float32, .float32, .float32],
            config: config) == 1_184)
        // Pure target rate excludes windows, borrowed storage and assistant state.
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: [full], dtypes: [.float32], config: .init(
                capacityBytes: 64 << 20, quantization: format)) == 160)
    }
}
