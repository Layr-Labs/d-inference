import ProviderCore
import Testing
@testable import darkbloom

@Suite("Shared serving model selection")
struct AdvertisedModelSelectionTests {
    @Test("shadow enrollment never replaces the normal serving selection")
    func shadowEnrollmentPreservesServingSelection() throws {
        let models = ["gemma", "qwen", "bonsai"].map {
            ModelInfo(id: $0, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        var config = ProviderConfig(provider: ProviderSettings(name: "shadow-selection"))
        config.backend.enabledModels = ["gemma"]
        config.backend.modelAutopilot = .init(enabled: true, consentRecorded: true,
            selectedModels: models.map(\.id), revision: "verified-inventory")

        #expect(advertisedModels(from: models, config: config).map(\.id) == ["gemma"])
        #expect(advertisedModels(from: models, config: config,
            modelOverrides: ["qwen"]).map(\.id) == ["qwen"])
        #expect(advertisedModels(from: models, config: config,
            includeDisabled: true).map(\.id) == ["gemma", "qwen", "bonsai"])
        #expect(config.backend.modelAutopilot.selectedModels == ["gemma", "qwen", "bonsai"])
    }

    @Test("explicit order and duplicates take precedence over all/config, then eligibility applies")
    func selectionPrecedence() {
        let gated = ModelRuntimeRequirements.qwen38ConcreteModelID
        let models = ["a", gated, "b"].map {
            ModelInfo(id: $0, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        var config = ProviderConfig(provider: ProviderSettings(name: "selection-fixture"))
        config.backend.enabledModels = ["a"]
        func ids(overrides: [String] = [], all: Bool = false,
                 capabilities: Set<ProviderRuntimeCapability> = []) -> [String] {
            advertisedModels(from: models, config: config, modelOverrides: overrides,
                             includeDisabled: all, runtimeCapabilities: capabilities).map(\.id)
        }
        #expect(ids() == ["a"])
        #expect(ids(all: true) == ["a", "b"])
        #expect(ids(overrides: ["b", "missing", gated, "a", "b"], all: true) == ["b", "a", "b"])
        #expect(ids(all: true, capabilities: [.appleM5, .mlxNAX]) == ["a", gated, "b"])
        config.backend.enabledModels = []
        #expect(ids() == ["a", "b"])
    }
}
