// Copyright © 2026 Eigen Labs.
//
// MTP config + policy surface: the tri-state `[backend].mtp_mode`, legacy
// boolean decoding, beta toggle normalization, shared target policy, and the
// supported-set carve-out that prevents assistant checkpoints from being
// advertised as servable chat models.

import Testing

@testable import ProviderCore

// MARK: - TOML keys

@Suite("MTP config keys")
struct MTPConfigKeyTests {
    @Test func automaticVerificationPolicyUsesConservativeGenerationBounds() {
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M1 Max") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M2 Ultra") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M3 Pro") == 8)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M4 Max") == 8)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M5") == 8)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Unknown") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "12"],
            chipName: "Apple M1 Max") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "6"],
            chipName: "Apple M5 Max") == 6)
        #expect(MTPAutomaticVerificationPolicy.initialDraftTokens == 1)
    }


    @Test("absent mode defaults on for the Qwen3.5 family by model type")
    func defaultsWhenAbsent() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)

        #expect(config.backend.mtpMode == .auto)
        #expect(config.backend.mtp == false)
        #expect(config.backend.mtpMode.enablesMTP(forModelType: "qwen3_5"))
        #expect(config.backend.mtpMode.enablesMTP(forModelType: "qwen3_5_moe"))
        #expect(!config.backend.mtpMode.enablesMTP(forModelType: nil))
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("explicit auto, on, and off modes decode")
    func decodesModes() {
        for (raw, expected) in [
            ("auto", MTPMode.auto),
            ("on", MTPMode.on),
            ("off", MTPMode.off),
        ] {
            let config = ConfigManager.parse(
                """
                [provider]
                name = "test-provider"

                [backend]
                mtp_mode = "\(raw)"
                """)
            #expect(config.backend.mtpMode == expected)
        }
    }

    @Test("legacy booleans migrate by config generation and mtp_mode stays authoritative")
    func legacyPrecedence() {
        let legacyOn = ConfigManager.parse(
            """
            config_version = 2
            [provider]
            name = "test-provider"
            [backend]
            mtp = true
            """)
        let generatedLegacyOff = ConfigManager.parse(
            """
            config_version = 2
            [provider]
            name = "test-provider"
            [backend]
            mtp = false
            """)
        let currentLegacyOff = ConfigManager.parse(
            """
            config_version = 3
            [provider]
            name = "test-provider"
            [backend]
            mtp = false
            """)
        let modeWins = ConfigManager.parse(
            """
            config_version = 2
            [provider]
            name = "test-provider"
            [backend]
            mtp_mode = "off"
            mtp = true
            """)

        #expect(legacyOn.backend.mtpMode == .on)
        #expect(generatedLegacyOff.backend.mtpMode == .auto)
        #expect(currentLegacyOff.backend.mtpMode == .off)
        #expect(modeWins.backend.mtpMode == .off)
    }

    @Test("automatic mode uses Qwen3.5-family model types; explicit modes ignore them")
    func targetPolicy() {
        // Family ids with their checkpoint model_types. Every one of these
        // must draft under `.auto` when the funnel can find an artifact —
        // including the embedded 27B that used to resolve through the
        // external-head pin.
        let familyModelTypes = [
            // Qwen 3.5/3.6 35B MoE (embedded or catalog heads)
            "qwen3_5_moe",
            // Qwen 3.5 dense (embedded heads: the 9B, the 27B)
            "qwen3_5",
        ]
        // Non-family types stay off under `.auto` — Gemma and GPT-OSS keep
        // their explicit opt-in, and no model_type means no automatic decision.
        let nonFamilyModelTypes: [String?] = [
            "gemma4",
            "gemma4_text",
            "gpt_oss",
            "qwen3_vl_moe",
            nil,
            "  ",
        ]

        for modelType in familyModelTypes {
            #expect(
                MTPMode.auto.enablesMTP(forModelType: modelType),
                "family model_type must draft under auto: \(modelType)")
            #expect(MTPMode.on.enablesMTP(forModelType: modelType))
            #expect(!MTPMode.off.enablesMTP(forModelType: modelType))
        }
        for modelType in nonFamilyModelTypes {
            #expect(
                !MTPMode.auto.enablesMTP(forModelType: modelType),
                "non-family model_type must not draft under auto: \(modelType ?? "nil")")
            #expect(MTPMode.on.enablesMTP(forModelType: modelType))
            #expect(!MTPMode.off.enablesMTP(forModelType: modelType))
        }
        // Model-type matching is case/whitespace-insensitive like every other
        // model_type comparison in the funnel.
        #expect(MTPMode.auto.enablesMTP(forModelType: " QWEN3_5_MOE "))
        #expect(MTPMode.auto.enablesMTP(forModelType: "Qwen3_5"))
    }

    @Test("provider and standalone configs use the same target decision")
    func providerAndStandaloneSharePolicy() {
        let backend = BackendSettings(mtpMode: .auto)
        let standalone = StandaloneServerConfig(mtpMode: backend.mtpMode)

        for modelType in ["qwen3_5_moe", "qwen3_5", "gemma4", nil] as [String?] {
            #expect(
                backend.mtpMode.enablesMTP(forModelType: modelType)
                    == standalone.mtpMode.enablesMTP(forModelType: modelType))
        }
    }

    @Test("process environment remains a final negative-polarity kill switch")
    func killSwitchPolicy() {
        #expect(SpecDecArtifactFunnel.killSwitchEnabled(environment: [:]))
        for value in ["0", "false", "no", "off", " OFF "] {
            #expect(
                !SpecDecArtifactFunnel.killSwitchEnabled(
                    environment: ["DARKBLOOM_CBV2_MTP": value]))
        }
        #expect(
            SpecDecArtifactFunnel.killSwitchEnabled(
                environment: ["DARKBLOOM_CBV2_MTP": "1"]))
    }

    @Test("invalid mode falls back to the safe default configuration")
    func invalidModeFallsBack() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"
            [backend]
            mtp_mode = "sometimes"
            """)

        #expect(config.backend.mtpMode == .auto)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("serialization emits only the tri-state key")
    func serializationRoundTrips() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(mtpMode: .on, mtpDrafterPath: "/tmp/drafter"),
            coordinator: CoordinatorSettings()
        )

        let toml = ConfigManager.serialize(original)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("mtp_mode = 'on'"))
        #expect(!toml.contains("\nmtp = "))
        #expect(toml.contains("mtp_drafter_path"))
        #expect(decoded.backend.mtpMode == .on)
        #expect(decoded.backend.mtpDrafterPath == "/tmp/drafter")
    }

    @Test("legacy input normalizes to mtp_mode when saved")
    func legacySerializationNormalizes() {
        let decoded = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"
            [backend]
            mtp = true
            """)
        let toml = ConfigManager.serialize(decoded)

        #expect(toml.contains("mtp_mode = 'on'"))
        #expect(!toml.contains("\nmtp = "))
    }

    @Test("generated legacy false normalizes once and re-saves idempotently")
    func generatedLegacyFalseNormalizesIdempotently() {
        let decoded = ConfigManager.parse(
            """
            config_version = 2
            [provider]
            name = "test-provider"
            [backend]
            mtp = false
            """)

        let firstSave = ConfigManager.serialize(decoded)
        let secondSave = ConfigManager.serialize(ConfigManager.parse(firstSave))

        #expect(decoded.backend.mtpMode == .auto)
        #expect(firstSave.contains("config_version = 3"))
        #expect(firstSave.contains("mtp_mode = 'auto'"))
        #expect(!firstSave.contains("\nmtp = "))
        #expect(secondSave == firstSave)
    }

    @Test("nil drafter path is not emitted")
    func nilPathNotEmitted() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )

        let toml = ConfigManager.serialize(original)

        #expect(toml.contains("mtp_mode = 'auto'"))
        #expect(!toml.contains("\nmtp = "))
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

    @Test("registry exposes automatic MTP as model-aware rather than disabled")
    func registryEntry() throws {
        let feature = try #require(BetaFeatures.feature(id: "mtp"))
        #expect(feature.id == "mtp")
        #expect(feature.requiresRestart == true)
        #expect(feature.configAddress?.section == "backend")
        #expect(feature.configAddress?.key == "mtp_mode")
        #expect(feature.isEnabled(in: freshConfig()) == true)
        #expect(feature.state(in: freshConfig()) == .auto)
        #expect(feature.state(in: freshConfig()).enabled == nil)
        #expect(!feature.isPinned(true, in: freshConfig()))
        #expect(!feature.isPinned(false, in: freshConfig()))
        // Case-insensitive lookup, like every other beta id.
        #expect(BetaFeatures.feature(id: "MTP")?.id == "mtp")
    }

    @Test("apply writes explicit on and off modes")
    func applyTogglesField() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()

        feature.apply(true, to: &config)
        #expect(config.backend.mtpMode == .on)
        #expect(feature.isEnabled(in: config) == true)
        #expect(feature.isPinned(true, in: config))
        #expect(BetaFeatures.enabledIDs(in: config) == [
            "gemma-prefill-layer18", "gemma-weighted-r1", "mtp",
        ])

        feature.apply(false, to: &config)
        #expect(config.backend.mtpMode == .off)
        #expect(feature.isEnabled(in: config) == false)
        #expect(feature.isPinned(false, in: config))
        #expect(BetaFeatures.enabledIDs(in: config) == [
            "gemma-prefill-layer18", "gemma-weighted-r1",
        ])
    }

    @Test("apply only mutates its mapped field")
    func applyIsScoped() {
        let feature = BetaFeatures.feature(id: "mtp")!
        var config = freshConfig()
        let before = config

        feature.apply(true, to: &config)

        #expect(config.backend.maxModelSlots == before.backend.maxModelSlots)
        #expect(config.backend.mtpDrafterPath == before.backend.mtpDrafterPath)
        #expect(config.backend.port == before.backend.port)
        #expect(config.provider == before.provider)
        #expect(config.coordinator == before.coordinator)
        #expect(config.gemmaOptimizations == before.gemmaOptimizations)
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

        #expect(toml.contains("mtp_mode = 'on'"))
        #expect(!toml.contains("\nmtp = "))
        #expect(feature.isEnabled(in: decoded) == true)
    }
}

// MARK: - Closed Gemma target namespace

@Suite("EngineV2 supported set: closed Gemma target namespace")
struct MTPSupportedModelsTests {

    @Test("assistant namespace variants are never servable chat models")
    func assistantVariantsExcluded() {
        for type in [
            "gemma4_assistant", " GEMMA4_ASSISTANT ",
            "gemma4_assistant_v2", "gemma4_text_assistant",
            "gemma4_mtp", "gemma4-drafter",
        ] {
            #expect(!EngineV2SupportedModels.isSupported(modelType: type), "type=\(type)")
            #expect(!EngineV2SupportedModels.isGemma4Target(modelType: type), "type=\(type)")
        }
    }

    @Test("only official Gemma target config types are supported")
    func officialGemmaTargetsSupported() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4") == true)
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4_text") == true)
        #expect(EngineV2SupportedModels.isGemma4Target(modelType: " GEMMA4_TEXT "))
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
