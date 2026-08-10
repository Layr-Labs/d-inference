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

    @Test("registry exposes current features")
    func registryContainsExpectedFeatures() {
        #expect(BetaFeatures.all.contains { $0.id == "gemma-prefill-layer18" })
        #expect(BetaFeatures.all.contains { $0.id == "gemma-weighted-r1" })
        #expect(BetaFeatures.all.contains { $0.id == "mtp" })
        #expect(!BetaFeatures.all.contains { $0.id == "gemma-expert-packing" })
        #expect(!BetaFeatures.all.contains { $0.id == "gemma-dense-packing" })
        // adaptive-prefill was retired with the legacy engine (v0.7.5);
        // kv-quant was retired with KV quantization itself (v0.8.0).
        #expect(!BetaFeatures.all.contains { $0.id == "adaptive-prefill" })
        #expect(!BetaFeatures.all.contains { $0.id == "kv-quant" })
    }

    @Test("feature lookup is case-insensitive and nil for unknown ids")
    func featureLookup() {
        #expect(
            BetaFeatures.feature(id: "GEMMA-PREFILL-LAYER18")?.id
                == "gemma-prefill-layer18"
        )
        #expect(BetaFeatures.feature(id: "Gemma-Weighted-R1")?.id == "gemma-weighted-r1")
        #expect(BetaFeatures.feature(id: "mtp")?.id == "mtp")
        #expect(BetaFeatures.feature(id: "MTP")?.id == "mtp")
        #expect(BetaFeatures.feature(id: "ADAPTIVE-PREFILL") == nil)  // retired v0.7.5
        #expect(BetaFeatures.feature(id: "KV-QUANT") == nil)  // retired v0.8.0
        #expect(BetaFeatures.feature(id: "does-not-exist") == nil)
    }

    @Test("mtp defaults to disabled")
    func mtpDefaultsOff() {
        let feature = BetaFeatures.feature(id: "mtp")!
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
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()

        feature.apply(true, to: &config)
        #expect(config.backend.mtp == true)
        #expect(feature.isEnabled(in: config) == true)

        feature.apply(false, to: &config)
        #expect(config.backend.mtp == false)
        #expect(feature.isEnabled(in: config) == false)

        // Retired ids resolve to nothing rather than a stale toggle.
        #expect(BetaFeatures.feature(id: "adaptive-prefill") == nil)
        #expect(BetaFeatures.feature(id: "kv-quant") == nil)
    }

    @Test("apply only mutates its mapped field")
    func applyIsScoped() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()
        let before = config

        feature.apply(true, to: &config)

        #expect(config.backend.port == before.backend.port)
        #expect(config.backend.maxModelSlots == before.backend.maxModelSlots)
        #expect(config.backend.enabledModels == before.backend.enabledModels)
        #expect(config.backend.mtpDrafterPath == before.backend.mtpDrafterPath)
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
        BetaFeatures.feature(id: "mtp")!.apply(true, to: &config)
        #expect(BetaFeatures.enabledIDs(in: config) == [
            "gemma-prefill-layer18", "mtp",
        ])
    }

    @Test("toggling mtp survives a TOML round-trip")
    func roundTripsThroughTOML() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()
        feature.apply(true, to: &config)

        let toml = ConfigManager.serialize(config)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("mtp"))
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
