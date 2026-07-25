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

    @Test("registry exposes beta features")
    func registryContainsExpectedFeatures() {
        #expect(BetaFeatures.all.contains { $0.id == "mtp" })
        // adaptive-prefill was retired with the legacy engine (v0.7.5);
        // kv-quant was retired with KV quantization itself (v0.8.0).
        #expect(!BetaFeatures.all.contains { $0.id == "adaptive-prefill" })
        #expect(!BetaFeatures.all.contains { $0.id == "kv-quant" })
    }

    @Test("feature lookup is case-insensitive and nil for unknown ids")
    func featureLookup() {
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
    }

    @Test("enabledIDs reflects the current config")
    func enabledIDsReflectsConfig() {
        var config = freshConfig()
        #expect(BetaFeatures.enabledIDs(in: config).isEmpty)

        BetaFeatures.feature(id: "mtp")!.apply(true, to: &config)
        #expect(BetaFeatures.enabledIDs(in: config) == ["mtp"])
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

}
