import Foundation
import Testing
@testable import ProviderCore

@Suite("Native media tool wire capability")
struct NativeMediaToolsCapabilityTests {
    @Test func advertisementIsScopedToQualifiedNativeMetadata() throws {
        var model = ModelInfo(id: "native", modelType: "diffusion_gemma", sizeBytes: 1,
            estimatedMemoryGb: 1, isVision: true, templateRenderOK: true)
        #expect(ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: model))
        for type in ["gemma4", "qwen4_exp", "prism_hadamard_qwen35", "llama"] {
            model.modelType = type
            #expect(!ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: model))
        }
        model.modelType = "diffusion_gemma"
        model.isVision = nil
        #expect(!ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: model))
        model.isVision = true
        for verdict: Bool? in [nil, false] {
            model.templateRenderOK = verdict
            #expect(!ToolChoiceEnforcementPolicy.advertisesNativeMediaTools(for: model))
        }
    }

    @Test func oldWireOmitsCapabilityAndExplicitValuesRoundTrip() throws {
        var model = ModelInfo(id: "native", sizeBytes: 1, estimatedMemoryGb: 1)
        let missing = try JSONEncoder().encode(model)
        #expect(!String(decoding: missing, as: UTF8.self).contains("native_media_tools"))
        #expect(try JSONDecoder().decode(ModelInfo.self, from: missing).nativeMediaTools == nil)
        for value in [false, true] {
            model.nativeMediaTools = value
            let encoded = try JSONEncoder().encode(model)
            #expect(try JSONDecoder().decode(ModelInfo.self, from: encoded) == model)
        }
    }

    @Test func capabilitySurvivesRegistrationAndModelUpdates() throws {
        let hardware = HardwareInfo(machineModel: "fixture", chipName: "fixture",
            chipFamily: .m3, chipTier: .ultra, memoryGb: 128, memoryAvailableGb: 100,
            cpuCores: .init(total: 1, performance: 1, efficiency: 0), gpuCores: 1,
            memoryBandwidthGbs: 1)
        var model = ModelInfo(id: "native", modelType: "diffusion_gemma", sizeBytes: 1,
            estimatedMemoryGb: 1, isVision: true, templateRenderOK: true, nativeMediaTools: true)
        for value in [true, false] {
            model.nativeMediaTools = value
            let messages: [ProviderMessage] = [
                .register(.init(hardware: hardware, models: [model], backend: "mlx-swift")),
                .register(.init(hardware: hardware, models: [model], backend: "mlx-swift",
                    attestation: RawJSON(rawBytes: Data(#"{"synthetic":true}"#.utf8)))),
                .modelsUpdate(.init(models: [model])),
            ]
            for message in messages {
                let data = try ProviderProtocolCodec.encodeProviderMessage(message)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let models = try #require(object["models"] as? [[String: Any]])
                #expect(models.first?["native_media_tools"] as? Bool == value)
                #expect(try ProviderProtocolCodec.decodeProviderMessage(from: data) == message)
            }
        }
    }
}
