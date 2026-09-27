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
        #expect(!EngineV2SupportedModels.isNemotron35ListingModelID("arbitrary/Nemotron-MTP"))
        #expect(SpecDecArtifactFunnel.isInlineTarget(modelType: "nemotron_h"))
        #expect(!SpecDecArtifactFunnel.isInlineQwenTarget(modelType: "nemotron_h"))
    }
    @Test func requestStatefulAssistantRetainsAdaptiveDepth() {
        #expect(MTPAutomaticVerificationPolicy.draftDepthPolicy(usesRequestStatefulDrafter: true).fixed == nil)
        #expect(MTPAutomaticVerificationPolicy.draftDepthPolicy(usesRequestStatefulDrafter: false).fixed == 1)
    }
}
