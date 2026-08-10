import Testing
@testable import ProviderCore

@Suite("Beta feature registry")
struct BetaFeaturesTests {

    private func freshConfig() -> ProviderConfig {
        ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )
    }

    @Test("registry exposes only retained Gemma controls")
    func registryContainsExpectedFeatures() {
        #expect(BetaFeatures.all.contains { $0.id == "gemma-prefill-layer18" })
        #expect(BetaFeatures.all.contains { $0.id == "gemma-weighted-r1" })
        #expect(BetaFeatures.all.contains { $0.id == "kv-quant" })
        #expect(!BetaFeatures.all.contains { $0.id == "gemma-expert-packing" })
        #expect(!BetaFeatures.all.contains { $0.id == "gemma-dense-packing" })
        #expect(!BetaFeatures.all.contains { $0.id == "adaptive-prefill" })
    }

    @Test("feature lookup is case-insensitive and nil for unknown ids")
    func featureLookup() {
        #expect(
            BetaFeatures.feature(id: "GEMMA-PREFILL-LAYER18")?.id
                == "gemma-prefill-layer18"
        )
        #expect(BetaFeatures.feature(id: "Gemma-Weighted-R1")?.id == "gemma-weighted-r1")
        #expect(BetaFeatures.feature(id: "kv-quant")?.id == "kv-quant")
        #expect(BetaFeatures.feature(id: "KV-QUANT")?.id == "kv-quant")
        #expect(BetaFeatures.feature(id: "ADAPTIVE-PREFILL") == nil)
        #expect(BetaFeatures.feature(id: "does-not-exist") == nil)
    }

    @Test("kv-quant defaults to disabled")
    func kvQuantDefaultsOff() {
        let feature = BetaFeatures.feature(id: "kv-quant")!
        #expect(feature.isEnabled(in: freshConfig()) == false)
        #expect(feature.requiresRestart == true)
    }

    @Test("retained Gemma controls default on and require restart")
    func gemmaControlsDefaultOn() {
        let config = freshConfig()
        for id in ["gemma-prefill-layer18", "gemma-weighted-r1"] {
            let feature = BetaFeatures.feature(id: id)!
            #expect(feature.isEnabled(in: config))
            #expect(feature.requiresRestart)
        }
    }

    @Test("each retained Gemma row mutates exactly one setting")
    func gemmaRowsAreScoped() {
        let layer = BetaFeatures.feature(id: "gemma-prefill-layer18")!
        let weighted = BetaFeatures.feature(id: "gemma-weighted-r1")!
        var config = freshConfig()

        layer.apply(false, to: &config)
        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(config.gemmaOptimizations.weightedR1)

        weighted.apply(false, to: &config)
        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(!config.gemmaOptimizations.weightedR1)

        weighted.apply(true, to: &config)
        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(config.gemmaOptimizations.weightedR1)
    }

    @Test("apply toggles the backing config field both ways")
    func applyTogglesField() {
        let feature = BetaFeatures.feature(id: "kv-quant")!
        var config = freshConfig()

        feature.apply(true, to: &config)
        #expect(config.backend.kvQuant == true)
        #expect(feature.isEnabled(in: config) == true)

        feature.apply(false, to: &config)
        #expect(config.backend.kvQuant == false)
        #expect(feature.isEnabled(in: config) == false)

        // adaptive-prefill was retired with the legacy engine (v0.7.5).
        #expect(BetaFeatures.feature(id: "adaptive-prefill") == nil)
    }

    @Test("apply only mutates its mapped field")
    func applyIsScoped() {
        let feature = BetaFeatures.feature(id: "kv-quant")!
        var config = freshConfig()
        let before = config

        feature.apply(true, to: &config)

        #expect(config.backend.port == before.backend.port)
        #expect(config.backend.maxModelSlots == before.backend.maxModelSlots)
        #expect(config.backend.enabledModels == before.backend.enabledModels)
        #expect(config.provider == before.provider)
        #expect(config.coordinator == before.coordinator)
        #expect(config.gemmaOptimizations == before.gemmaOptimizations)
    }

    @Test("enabledIDs reflects default-on and explicit beta settings")
    func enabledIDsReflectsConfig() {
        var config = freshConfig()
        #expect(BetaFeatures.enabledIDs(in: config) == [
            "gemma-prefill-layer18", "gemma-weighted-r1",
        ])

        BetaFeatures.feature(id: "gemma-weighted-r1")!.apply(false, to: &config)
        BetaFeatures.feature(id: "kv-quant")!.apply(true, to: &config)
        #expect(BetaFeatures.enabledIDs(in: config) == [
            "gemma-prefill-layer18", "kv-quant",
        ])
    }

    @Test("toggling kv-quant survives a TOML round-trip")
    func roundTripsThroughTOML() {
        let feature = BetaFeatures.feature(id: "kv-quant")!
        var config = freshConfig()
        feature.apply(true, to: &config)

        let toml = ConfigManager.serialize(config)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("kv_quant"))
        #expect(feature.isEnabled(in: decoded) == true)
    }

    @Test("retained Gemma beta toggles survive a TOML round trip")
    func gemmaRowsRoundTripThroughTOML() {
        var config = freshConfig()
        BetaFeatures.feature(id: "gemma-prefill-layer18")!.apply(false, to: &config)
        BetaFeatures.feature(id: "gemma-weighted-r1")!.apply(false, to: &config)

        let toml = ConfigManager.serialize(config)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("prefill_layer18"))
        #expect(toml.contains("weighted_r1"))
        #expect(!decoded.gemmaOptimizations.prefillLayer18)
        #expect(!decoded.gemmaOptimizations.weightedR1)
    }

}
