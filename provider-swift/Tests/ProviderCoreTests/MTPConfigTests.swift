// Copyright © 2026 Eigen Labs.
//
// MTP config + hygiene surface (Gemma 4 MTP plan §4 D5): the `[backend]`
// `mtp` / `mtp_drafter_path` TOML keys, the `mtp` beta-feature registry
// entry (`darkbloom beta enable mtp` is registry-driven, zero CLI code),
// and the `gemma4_assistant` supported-set carve-out (a hand-downloaded
// drafter checkpoint must never be advertised as a servable chat model).

import Testing

@testable import ProviderCore

// MARK: - TOML keys

@Suite("MTP config keys")
struct MTPConfigKeyTests {

    @Test("absent keys default to mtp=false, no drafter path")
    func defaultsWhenAbsent() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)

        #expect(config.backend.mtp == false)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("present keys decode")
    func decodesPresentKeys() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = true
            mtp_drafter_path = "/opt/drafters/gemma4-assistant-4bit"
            """)

        #expect(config.backend.mtp == true)
        #expect(config.backend.mtpDrafterPath == "/opt/drafters/gemma4-assistant-4bit")
    }

    @Test("mtp works without a drafter path (fleet spec_dec path)")
    func mtpWithoutPath() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = true
            """)

        #expect(config.backend.mtp == true)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    // ConfigManager.parse falls back to a full default config on any decode
    // failure (documented behavior: a malformed provider.toml must never
    // brick a provider) — so a wrongly-typed value yields the safe default
    // (MTP off), never a crash or a half-parsed config.
    @Test("wrongly-typed mtp value falls back to defaults (off)")
    func invalidMTPValueFallsBack() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = "yes"
            """)

        #expect(config.backend.mtp == false)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("wrongly-typed mtp_drafter_path falls back to defaults")
    func invalidDrafterPathFallsBack() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = true
            mtp_drafter_path = 42
            """)

        #expect(config.backend.mtp == false)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("serialization round-trips both keys")
    func serializationRoundTrips() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(mtp: true, mtpDrafterPath: "/tmp/drafter"),
            coordinator: CoordinatorSettings()
        )

        let toml = ConfigManager.serialize(original)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("mtp = true"))
        #expect(toml.contains("mtp_drafter_path"))
        #expect(decoded.backend.mtp == true)
        #expect(decoded.backend.mtpDrafterPath == "/tmp/drafter")
    }

    @Test("nil drafter path is not emitted")
    func nilPathNotEmitted() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )

        let toml = ConfigManager.serialize(original)

        #expect(!toml.contains("mtp_drafter_path"))
    }
}

// MARK: - Beta feature

@Suite("MTP beta feature")
struct MTPBetaFeatureTests {

    private func freshConfig() -> ProviderConfig {
        ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )
    }

    @Test("registry exposes mtp, restart-required, default off")
    func registryEntry() throws {
        let feature = try #require(BetaFeatures.feature(id: "mtp"))
        #expect(feature.id == "mtp")
        #expect(feature.requiresRestart == true)
        #expect(feature.isEnabled(in: freshConfig()) == false)
        // Case-insensitive lookup, like every other beta id.
        #expect(BetaFeatures.feature(id: "MTP")?.id == "mtp")
    }

    @Test("apply toggles config.backend.mtp both ways")
    func applyTogglesField() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()

        feature.apply(true, to: &config)
        #expect(config.backend.mtp == true)
        #expect(feature.isEnabled(in: config) == true)
        #expect(BetaFeatures.enabledIDs(in: config) == ["mtp"])

        feature.apply(false, to: &config)
        #expect(config.backend.mtp == false)
        #expect(feature.isEnabled(in: config) == false)
        #expect(BetaFeatures.enabledIDs(in: config).isEmpty)
    }

    @Test("apply only mutates its mapped field")
    func applyIsScoped() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()
        let before = config

        feature.apply(true, to: &config)

        #expect(config.backend.kvQuant == before.backend.kvQuant)
        #expect(config.backend.mtpDrafterPath == before.backend.mtpDrafterPath)
        #expect(config.backend.port == before.backend.port)
        #expect(config.provider == before.provider)
        #expect(config.coordinator == before.coordinator)
    }

    // `darkbloom beta enable mtp` = apply(true) + ConfigManager.save; the
    // daemon reads the TOML back on restart. This round-trip is the whole
    // enable path, minus the file I/O.
    @Test("toggle survives a TOML round-trip")
    func roundTripsThroughTOML() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()
        feature.apply(true, to: &config)

        let toml = ConfigManager.serialize(config)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("mtp = true"))
        #expect(feature.isEnabled(in: decoded) == true)
    }
}

// MARK: - Supported-set drafter carve-out

@Suite("EngineV2 supported set: gemma4_assistant carve-out")
struct MTPSupportedModelsTests {

    @Test("gemma4_assistant is never a servable chat model")
    func assistantExcluded() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4_assistant") == false)
        // Same normalization (trim + lowercase) as every other type check.
        #expect(EngineV2SupportedModels.isSupported(modelType: " GEMMA4_ASSISTANT ") == false)
    }

    @Test("the rest of the gemma4 prefix family stays supported")
    func gemma4FamilyStillSupported() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4") == true)
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4_text") == true)
        #expect(EngineV2SupportedModels.isSupported(modelType: "gpt_oss") == true)
        // Non-CBv2 families still fail closed.
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma3") == false)
        #expect(EngineV2SupportedModels.isSupported(modelType: nil) == false)
    }

    @Test("partition drops the drafter, keeps its targets")
    func partitionExcludesDrafter() {
        let models = [
            ModelInfo(
                id: "gemma-4-26b-qat-4bit", modelType: "gemma4",
                sizeBytes: 1 << 30, estimatedMemoryGb: 1.2),
            ModelInfo(
                id: "gemma-4-26b-assistant-4bit", modelType: "gemma4_assistant",
                sizeBytes: 236_124_704, estimatedMemoryGb: 0.3),
            ModelInfo(
                id: "gemma-4-26b-text", modelType: "gemma4_text",
                sizeBytes: 1 << 30, estimatedMemoryGb: 1.2),
        ]
        let split = EngineV2SupportedModels.partition(models)
        #expect(split.supported.map(\.id) == ["gemma-4-26b-qat-4bit", "gemma-4-26b-text"])
        #expect(split.unsupported.map(\.id) == ["gemma-4-26b-assistant-4bit"])
    }
}
