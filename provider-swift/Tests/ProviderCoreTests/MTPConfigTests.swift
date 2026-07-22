// Copyright © 2026 Eigen Labs.
//
// MTP config + hygiene surface: production-default policy, persistent opt-out,
// environment kill-switch precedence, and assistant namespace exclusion.

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

    @Test("active MTP forces transactional contiguous KV")
    func mtpForcesContiguousKV() {
        #expect(EngineV2SlotFactory.mtpCompatibleKVBackend(
            .paged, assistantActive: true) == .contiguous)
        #expect(EngineV2SlotFactory.mtpCompatibleKVBackend(
            .paged, assistantActive: false) == .paged)
        #expect(EngineV2SlotFactory.mtpCompatibleKVBackend(
            .contiguous, assistantActive: true) == .contiguous)
    }


    @Test("old configs without keys migrate to mtp=true")
    func defaultsWhenAbsent() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)

        #expect(config.backend.mtp == true)
        #expect(config.backend.mtpDrafterPath == nil)
    }

    @Test("present keys decode")
    func decodesPresentKeys() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = false
            mtp_drafter_path = "/opt/drafters/gemma4-assistant-4bit"
            """)

        #expect(config.backend.mtp == false)
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
    // brick a provider) — so a wrongly-typed value yields the production
    // default, never a crash or a half-parsed config.
    @Test("wrongly-typed mtp value falls back to production default")
    func invalidMTPValueFallsBack() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp = "yes"
            """)

        #expect(config.backend.mtp == true)
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

        #expect(config.backend.mtp == true)
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

@Suite("MTP production policy")
struct MTPProductionPolicyTests {
    @Test("MTP is not exposed through the beta workflow")
    func betaEntryRemoved() {
        #expect(BetaFeatures.feature(id: "mtp") == nil)
        #expect(!BetaFeatures.all.contains { $0.id == "mtp" })
    }

    @Test("explicit config opt-out survives serialization")
    func explicitOptOutRoundTrips() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(mtp: false),
            coordinator: CoordinatorSettings())
        let decoded = ConfigManager.parse(ConfigManager.serialize(original))
        #expect(decoded.backend.mtp == false)
    }

    @Test("environment kill switch is persisted into the launchd service")
    func killSwitchSurvivesLaunchdRestarts() {
        let persisted = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_CBV2_MTP": "0",
            "UNRELATED": "secret",
        ])
        #expect(persisted == ["DARKBLOOM_CBV2_MTP": "0"])
        #expect(!SpecDecArtifactFunnel.killSwitchEnabled(environment: persisted))
        #expect(SpecDecArtifactFunnel.killSwitchEnabled(environment: [:]))
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
