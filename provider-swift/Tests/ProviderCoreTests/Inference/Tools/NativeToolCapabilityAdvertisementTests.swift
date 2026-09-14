import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Exercise the serialized provider messages consumed by coordinator routing,
/// rather than inferring network eligibility from local tool enforcement.
@Suite("Native tool capability advertisement")
struct NativeToolCapabilityAdvertisementTests {
    private func model(_ id: String, _ type: String?, template: String? = nil) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1,
                  toolConstraintTemplateHash: template)
    }

    private var nativeModels: [ModelInfo] {
        [model(EngineV2SupportedModels.nemotron35LightningModelID, "nemotron_h"),
         model(EngineV2SupportedModels.nemotron35LightningMTPModelID, "nemotron_h"),
         model(EngineV2SupportedModels.nemotron35LightningRegistryModelID, "nemotron_h")]
    }

    private var legacyModels: [ModelInfo] {
        [model("gemma-4-qualified", "gemma4_text",
               template: Gemma4ToolConstraintContract.pinnedTemplateSHA256),
         model("EigenLabs/Qwen3.8-27B-4bit", "qwen3_5")]
    }

    private var unsupportedModels: [ModelInfo] {
        [model("mlx-community/NVIDIA-Nemotron-Nano", "nemotron_h"),
         model("unknown-lightning", "nemotron_h"),
         model("unqualified-qwen27", "qwen3_5"),
         model("misleading-nemotron", "nemotron_h_unknown"),
         model("unknown", nil),
         model("gemma-4-drifted", "gemma4_text", template: "wrong-template")]
    }

    private func config(_ models: [ModelInfo], runtime: Set<ProviderRuntimeCapability> = []) -> CoordinatorClientConfig {
        CoordinatorClientConfig(url: "wss://coordinator.invalid/ws",
            hardware: HardwareInfo(machineModel: "test", chipName: "Apple M5 Max",
                chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: models, backendName: "mlx_swift_lm", runtimeCapabilities: runtime)
    }

    private func registration(_ config: CoordinatorClientConfig,
                              models: [ModelInfo]? = nil) throws -> ProviderMessage.Register {
        let bytes = try CoordinatorClientCodec.encodeRegistration(from: config, models: models)
        let message = try ProviderProtocolCodec.decodeProviderMessage(from: bytes)
        guard case .register(let result) = message else {
            throw AdvertisementError.unexpectedMessage
        }
        return result
    }

    private func update(_ models: [ModelInfo]) throws -> ProviderMessage.ModelsUpdate {
        let bytes = try CoordinatorClientCodec.encodeOutboundMessage(.modelsUpdate(models: models))
        let message = try ProviderProtocolCodec.decodeProviderMessage(from: bytes)
        guard case .modelsUpdate(let result) = message else {
            throw AdvertisementError.unexpectedMessage
        }
        return result
    }

    @Test func registrationAdvertisesNativeAndPreservesLegacyContracts() throws {
        let models = nativeModels + legacyModels + unsupportedModels
        let result = try registration(config(models, runtime: [.appleM5, .mlxNAX]))
        let expected = (nativeModels + legacyModels).map(\.id).sorted()
        #expect(result.toolConstraintProtocol == 1)
        #expect(result.toolConstraintModels == expected)
        #expect(result.models.map(\.id) == models.map(\.id))
        for model in nativeModels {
            let context = ChatTemplateFixContext(modelId: model.id, modelType: model.modelType)
            for mode: ToolConstraintMode in [.required, .named("add")] {
                #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
                        == .structuredPostValidation)
            }
        }
    }

    @Test func modelsUpdateAddsAndRevokesOnlyExplicitSupportedModels() throws {
        let native = try update(nativeModels + unsupportedModels)
        #expect(native.toolConstraintProtocol == 1)
        #expect(native.toolConstraintModels == nativeModels.map(\.id).sorted())

        // Replacing a native build by an unqualified family cannot leave a
        // stale positive claim in the next authoritative models_update.
        var changed = nativeModels[0]
        changed.modelType = "unknown"
        let revoked = try update([changed] + unsupportedModels)
        #expect(revoked.toolConstraintProtocol == 1)
        #expect(revoked.toolConstraintModels == [])
    }

    @Test func reconnectUsesCurrentModelsAndRetainsRuntimeAndTemplateGates() throws {
        let initial = config(nativeModels + legacyModels)
        let constrained = try registration(initial)
        // The protected Qwen27 artifact still requires M5/NAX capabilities;
        // adding native families does not bypass that preexisting filter.
        #expect(!constrained.models.contains { $0.id == "EigenLabs/Qwen3.8-27B-4bit" })
        #expect(constrained.toolConstraintModels == (nativeModels + [legacyModels[0]]).map(\.id).sorted())

        var broken = nativeModels[0]
        broken.templateRenderOK = false
        let fresh = try registration(initial, models: [broken])
        #expect(fresh.toolConstraintModels == [broken.id])
        #expect(fresh.models.count == 1)
        #expect(fresh.models.first?.templateRenderOK == false)
        // Template health is a separate coordinator gate; preserve its exact
        // negative report rather than changing or erasing it during encoding.

        let empty = try registration(initial, models: unsupportedModels)
        #expect(empty.toolConstraintProtocol == nil)
        #expect(empty.toolConstraintModels == nil)
    }

    @Test func nativeExactIDRequiresArchitectureAndLegacyExactIDIsUnchanged() {
        #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for:
            model(EngineV2SupportedModels.nemotron35LightningModelID, "llama")))
        // Existing Qwen35TemplateFix recognizes this trusted exact ID even
        // when older discovery metadata does not name its architecture.
        #expect(ToolChoiceEnforcementPolicy.advertisesCapability(for:
            model("EigenLabs/Qwen3.8-27B-4bit", "llama")))
    }

    private enum AdvertisementError: Error { case unexpectedMessage }
}
