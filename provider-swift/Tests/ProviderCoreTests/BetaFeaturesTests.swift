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

    @Test("registry exposes the kv-quant feature")
    func registryContainsKVQuant() {
        #expect(BetaFeatures.all.contains { $0.id == "kv-quant" })
    }

    @Test("feature lookup is case-insensitive and nil for unknown ids")
    func featureLookup() {
        #expect(BetaFeatures.feature(id: "kv-quant")?.id == "kv-quant")
        #expect(BetaFeatures.feature(id: "KV-QUANT")?.id == "kv-quant")
        #expect(BetaFeatures.feature(id: "does-not-exist") == nil)
    }

    @Test("kv-quant defaults to disabled")
    func kvQuantDefaultsOff() {
        let feature = BetaFeatures.feature(id: "kv-quant")!
        #expect(feature.isEnabled(in: freshConfig()) == false)
        #expect(feature.requiresRestart == true)
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
    }

    @Test("enabledIDs reflects the current config")
    func enabledIDsReflectsConfig() {
        var config = freshConfig()
        #expect(BetaFeatures.enabledIDs(in: config).isEmpty)

        BetaFeatures.feature(id: "kv-quant")!.apply(true, to: &config)
        #expect(BetaFeatures.enabledIDs(in: config) == ["kv-quant"])
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
}
