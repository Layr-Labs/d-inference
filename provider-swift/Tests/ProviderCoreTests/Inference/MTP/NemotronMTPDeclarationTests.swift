import Foundation
import Testing
@testable import ProviderCore

@Suite("Nemotron embedded MTP declaration")
struct NemotronMTPDeclarationTests {
    private var declaration: [String: Any] {
        ["model_type": "nemotron_h", "num_nextn_predict_layers": 1,
         "mtp_layers_block_type": ["attention", "moe"],
         "darkbloom_embedded_mtp": ["version": 1, "architecture": "nemotron_h_attention_moe"]]
    }
    @Test func explicitEmbeddedContractAndMode() {
        #expect(SpecDecStore.declaresNemotronLightningMTP(declaration))
        #expect(MTPMode.auto.enablesMTP(forModelType: "nemotron_h", embeddedArtifactDeclared: true))
        #expect(!MTPMode.auto.enablesMTP(forModelType: "nemotron_h", embeddedArtifactDeclared: false))
        #expect(!MTPMode.off.enablesMTP(forModelType: "nemotron_h", embeddedArtifactDeclared: true))
        var copiedMetadata = declaration
        copiedMetadata.removeValue(forKey: "darkbloom_embedded_mtp")
        #expect(!SpecDecStore.declaresNemotronLightningMTP(copiedMetadata))
        for invalid: Any in [true, 0, 2, 1.5, "1"] {
            var wrong = declaration
            wrong["num_nextn_predict_layers"] = invalid
            #expect(!SpecDecStore.declaresNemotronLightningMTP(wrong))
        }
    }
    @Test func newArtifactHasExplicitListingBoundary() {
        #expect(EngineV2SupportedModels.isNemotron35ListingModelID(EngineV2SupportedModels.nemotron35LightningMTPModelID))
        #expect(EngineV2SupportedModels.isNemotron35ListingModelID("nvidia-nemotron-3.5-lightning"))
        #expect(EngineV2SupportedModels.isNemotron35ListingModelID("EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp"))
        // Rollout build ids behind the public name (takeover alias): the
        // Mamba/attention-Q8 build and the pre-positioned 4-bit rollback copy.
        #expect(EngineV2SupportedModels.isNemotron35ListingModelID("nvidia-nemotron-3.5-lightning-hybrid8"))
        #expect(EngineV2SupportedModels.isNemotron35ListingModelID("nvidia-nemotron-3.5-lightning-4bit-r1"))
        #expect(EngineV2SupportedModels.nemotron35LightningHybrid8BuildID == "nvidia-nemotron-3.5-lightning-hybrid8")
        #expect(EngineV2SupportedModels.nemotron35LightningRollback4bitBuildID == "nvidia-nemotron-3.5-lightning-4bit-r1")
        // Near-misses stay closed: suffix variants, case and whitespace.
        for other in ["nvidia-nemotron-3.5-lightning-hybrid8-x", "nvidia-nemotron-3.5-lightning-4bit",
                      "NVIDIA-NEMOTRON-3.5-LIGHTNING-HYBRID8", "nvidia-nemotron-3.5-lightning-hybrid8 "] {
            #expect(!EngineV2SupportedModels.isNemotron35ListingModelID(other))
        }
        #expect(!EngineV2SupportedModels.isNemotron35ListingModelID("arbitrary/Nemotron-MTP"))
        #expect(SpecDecArtifactFunnel.isInlineTarget(modelType: "nemotron_h"))
        #expect(!SpecDecArtifactFunnel.isInlineQwenTarget(modelType: "nemotron_h"))
    }
    @Test func requestStatefulAssistantRetainsAdaptiveDepth() {
        #expect(MTPAutomaticVerificationPolicy.draftDepthPolicy(usesRequestStatefulDrafter: true).fixed == nil)
        #expect(MTPAutomaticVerificationPolicy.draftDepthPolicy(usesRequestStatefulDrafter: false).fixed == 1)
    }
}
