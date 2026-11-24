// Copyright © 2026 Eigen Labs.
//
// MTP config + policy surface: the tri-state `[backend].mtp_mode`, the
// retired boolean `mtp` key, beta toggle normalization, shared target policy, and the
// supported-set carve-out that prevents assistant checkpoints from being
// advertised as servable chat models.

import MLXLMCommon
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
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Apple M6") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: "Unknown") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "12"],
            chipName: "Apple M1 Max") == 4)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "6"],
            chipName: "Apple M5 Max") == 6)
        #expect(MTPAutomaticVerificationPolicy.initialDraftTokens == 1)
    }

    /// The catalog Gemma 4 26B QAT speculates only while one row decodes: its
    /// envelope is one `[1, 2]` rectangle, so two or more rows get depth 0.
    @Test func gemmaQATSpeculatesOnlyAsALoneRow() {
        let gemma = MTPAcceptancePolicy.gemmaQATModelID
        for chip in ["Apple M5 Ultra", "Apple M5 Max", "Apple M4 Max", "Apple M3 Ultra", "Apple M1 Max"] {
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaLoneRow: true, gemmaTwoDrafts: false) == 2)
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaLoneRow: false, gemmaTwoDrafts: false)
                == MTPAutomaticVerificationPolicy.maxRectangularTokens(chipName: chip))
        }
        for model in ["gemma-4-26b", "gemma-4-26b-8bit", "qwen3.6-35b-a3b-vl-mtp-mxfp8", nil] as [String?] {
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: "Apple M5 Max", modelID: model, gemmaLoneRow: true, gemmaTwoDrafts: true) == 8)
        }
        // The operator's cap still only tightens.
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "8"], chipName: "Apple M5 Max",
            modelID: gemma, gemmaLoneRow: true, gemmaTwoDrafts: false) == 2)
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "0"], chipName: "Apple M5 Max",
            modelID: gemma, gemmaLoneRow: true, gemmaTwoDrafts: false) == 0)
        #expect(MTPAutomaticVerificationPolicy.gemmaLoneRowEnabled(nil))
        // Empty counts as unset: the LaunchAgent drops empty values, so a
        // background provider sees the same as a foreground one.
        for raw in ["", " ", "1", "true", "YES", "on", " 1 "] {
            #expect(MTPAutomaticVerificationPolicy.gemmaLoneRowEnabled(raw))
        }
        for raw in ["0", "false", "no", "off", " 0 ", "OFF"] {
            #expect(!MTPAutomaticVerificationPolicy.gemmaLoneRowEnabled(raw))
        }
    }

    /// The two-draft policy is per measured chip: M5 Ultra, M3 Ultra and M5 Max
    /// draft two tokens only for a lone row, and every other chip (or the switch
    /// off) keeps the one-draft lone-row policy.
    @Test func gemmaQATTwoDraftsFollowTheChip() {
        let gemma = MTPAcceptancePolicy.gemmaQATModelID
        for chip in ["Apple M5 Ultra", "Apple M3 Ultra", "Apple M5 Max"] {
            #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
                modelID: gemma, chipName: chip, twoDrafts: true, m5UltraLoneRow: true) == [2, 0], "\(chip)")
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaTwoDrafts: true,
                gemmaM5UltraLoneRow: true) == 3, "\(chip)")
            let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: false, modelID: gemma, chipName: chip, gemmaTwoDrafts: true)
            #expect(depth.maximum == 2 && depth.fixed == 2)
            // The switch off restores the lone-row policy on the same chip.
            #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
                modelID: gemma, chipName: chip, twoDrafts: false) == nil)
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaTwoDrafts: false) == 2)
            let off = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: false, modelID: gemma, chipName: chip, gemmaTwoDrafts: false)
            #expect(off.maximum == 1 && off.fixed == nil)
        }
        // Unmeasured chips keep today's lone-row policy with the switch on.
        for chip in ["Apple M5 Pro", "Apple M5", "Apple M4 Max", "Apple M4 Ultra",
            "Apple M3 Max", "Apple M2 Ultra", "Apple M1 Max", "Unknown"]
        {
            #expect(MTPAutomaticVerificationPolicy.gemmaTwoDrafts(chipName: chip) == nil)
            #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
                modelID: gemma, chipName: chip, twoDrafts: true) == nil)
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaTwoDrafts: true) == 2)
            let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: false, modelID: gemma, chipName: chip, gemmaTwoDrafts: true)
            #expect(depth.maximum == 1 && depth.fixed == nil)
        }
        // The operator's cap still only tightens; other models and the
        // benchmark override never take the table.
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "2"], chipName: "Apple M5 Ultra",
            modelID: gemma, gemmaTwoDrafts: true, gemmaM5UltraLoneRow: true) == 2)
        #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
            modelID: gemma, chipName: "Apple M5 Ultra", hasBenchmarkVerificationOverride: true,
            twoDrafts: true) == nil)
        for model in ["gemma-4-26b", "gemma-4-26b-8bit", nil] as [String?] {
            #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
                modelID: model, chipName: "Apple M5 Ultra", twoDrafts: true) == nil)
        }
    }

    /// With two Gemma rows decoding, M5 Ultra runs ordinary chained decode
    /// (depth 0) and admits no `[2, 3]` verification; a lone row still drafts
    /// two tokens.
    @Test func gemmaQATTwoRowsOnM5UltraDecodeWithoutDrafts() throws {
        let table = try #require(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
            modelID: MTPAcceptancePolicy.gemmaQATModelID, chipName: "Apple M5 Ultra", twoDrafts: true,
            m5UltraLoneRow: true))
        #expect(table.first == 2, "a lone row drafts two")
        #expect(table.dropFirst().allSatisfy { $0 == 0 }, "two or more rows draft nothing: \(table)")
        // Two rows verify chained only when even one draft each does not fit.
        #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
            environment: [:], chipName: "Apple M5 Ultra", modelID: MTPAcceptancePolicy.gemmaQATModelID,
            gemmaTwoDrafts: true, gemmaM5UltraLoneRow: true) < 2 * 2, "no two-row verification")
    }

    /// `DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW=0` restores M5 Ultra's earlier
    /// table (one or two rows draft two, envelope 6) and nothing else.
    @Test func gemmaQATM5UltraLoneRowSwitchRestoresTheTwoRowTable() {
        let gemma = MTPAcceptancePolicy.gemmaQATModelID
        for (chip, table, tokens) in [
            ("Apple M5 Ultra", [2, 2, 0], 6), ("Apple M3 Ultra", [2, 0], 3), ("Apple M5 Max", [2, 0], 3),
        ] {
            #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
                modelID: gemma, chipName: chip, twoDrafts: true, m5UltraLoneRow: false) == table, "\(chip)")
            #expect(MTPAutomaticVerificationPolicy.maxRectangularTokens(
                environment: [:], chipName: chip, modelID: gemma, gemmaTwoDrafts: true,
                gemmaM5UltraLoneRow: false) == tokens, "\(chip)")
        }
        #expect(MTPAutomaticVerificationPolicy.gemmaTwoDrafts(chipName: "Apple M4 Ultra", m5UltraLoneRow: false) == nil)
        #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
            modelID: gemma, chipName: "Apple M5 Ultra", twoDrafts: false, m5UltraLoneRow: false) == nil)
        // A call without the parameter follows the read-once process switch.
        let enabled = MTPAutomaticVerificationPolicy.gemmaM5UltraLoneRowEnabled
        #expect(MTPAutomaticVerificationPolicy.fixedDraftTokensByDecodeRows(
            modelID: gemma, chipName: "Apple M5 Ultra", twoDrafts: true) == (enabled ? [2, 0] : [2, 2, 0]))
    }

    /// Under the two-draft policy on M5 Ultra, a Gemma QAT prompt longer than
    /// 16,384 tokens decodes without drafts; `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS`
    /// moves the limit or, with `0`, removes it. No other chip, model or
    /// policy gets a limit, whatever the setting.
    @Test func gemmaQATLongPromptsOnM5UltraDecodeWithoutDrafts() {
        typealias Limit = MTPAutomaticVerificationPolicy.GemmaDraftPromptLimit
        let gemma = MTPAcceptancePolicy.gemmaQATModelID
        func limit(
            _ chip: String, _ setting: Limit, model: String? = MTPAcceptancePolicy.gemmaQATModelID,
            twoDrafts: Bool = true, benchmark: Bool = false, onByDefault: Bool = true
        ) -> Int? {
            MTPAutomaticVerificationPolicy.maxDraftPromptTokens(
                modelID: model, chipName: chip, hasBenchmarkVerificationOverride: benchmark,
                twoDrafts: twoDrafts, limit: setting, onByDefault: onByDefault)
        }
        #expect(MTPAutomaticVerificationPolicy.gemmaM5UltraMaxDraftPromptTokens == 16384)
        #expect(limit("Apple M5 Ultra", .chipDefault) == 16384)
        #expect(limit("Apple M5 Ultra", .tokens(8192)) == 8192)
        #expect(limit("Apple M5 Ultra", .off) == nil)
        for setting in [Limit.chipDefault, .off, .tokens(2048)] {
            // The two-draft switch off, the benchmark override and other models.
            #expect(limit("Apple M5 Ultra", setting, twoDrafts: false) == nil)
            #expect(limit("Apple M5 Ultra", setting, benchmark: true) == nil)
            for model in ["gemma-4-26b", "gemma-4-26b-8bit", "qwen3.6-35b-a3b-vl-mtp-mxfp8", nil]
                as [String?]
            {
                #expect(limit("Apple M5 Ultra", setting, model: model) == nil)
            }
            // Every other chip, the other two-draft chips included.
            for chip in ["Apple M5 Max", "Apple M3 Ultra", "Apple M5 Pro", "Apple M5", "Apple M4 Max",
                "Apple M4 Ultra", "Apple M2 Ultra", "Apple M1 Max", "Unknown"]
            {
                #expect(limit(chip, setting) == nil, "\(chip)")
            }
        }
        // A call without the setting follows the read-once process value.
        #expect(MTPAutomaticVerificationPolicy.maxDraftPromptTokens(
            modelID: gemma, chipName: "Apple M5 Ultra", twoDrafts: true)
            == limit(
                "Apple M5 Ultra", MTPAutomaticVerificationPolicy.gemmaDraftPromptLimit,
                onByDefault: MTPAutomaticVerificationPolicy.gemmaPromptLimitOnByDefault))
    }

    /// The build default can be switched off in one line
    /// (`gemmaPromptLimitOnByDefault`). Off, an unset setting gives no limit,
    /// so the engine runs as it did before the limit existed; an explicit
    /// positive setting still applies it, and `0` stays off.
    @Test func gemmaPromptLimitDefaultCanBeSwitchedOff() {
        func limit(_ setting: MTPAutomaticVerificationPolicy.GemmaDraftPromptLimit, _ onByDefault: Bool) -> Int? {
            MTPAutomaticVerificationPolicy.maxDraftPromptTokens(
                modelID: MTPAcceptancePolicy.gemmaQATModelID, chipName: "Apple M5 Ultra",
                twoDrafts: true, limit: setting, onByDefault: onByDefault)
        }
        #expect(MTPAutomaticVerificationPolicy.gemmaPromptLimitOnByDefault)
        #expect(limit(.chipDefault, true) == 16384)
        #expect(limit(.chipDefault, false) == nil)
        #expect(limit(.tokens(8192), false) == 8192)
        #expect(limit(.off, true) == nil)
        #expect(limit(.off, false) == nil)
        for chip in ["Apple M5 Max", "Apple M3 Ultra", "Unknown"] {
            #expect(MTPAutomaticVerificationPolicy.maxDraftPromptTokens(
                modelID: MTPAcceptancePolicy.gemmaQATModelID, chipName: chip, twoDrafts: true,
                limit: .chipDefault, onByDefault: true) == nil, "\(chip)")
        }
    }

    @Test func gemmaDraftPromptLimitParsesTheEnvironment() {
        typealias Limit = MTPAutomaticVerificationPolicy.GemmaDraftPromptLimit
        for raw in [nil, "", " ", "abc", "-5", "4096.5", "1e4"] as [String?] {
            #expect(Limit(raw) == .chipDefault, "\(raw ?? "nil")")
        }
        for raw in ["0", " 0 ", "OFF", "off", "false", "No"] {
            #expect(Limit(raw) == .off, "\(raw)")
        }
        #expect(Limit("8192") == .tokens(8192))
        #expect(Limit(" 2048 ") == .tokens(2048))
    }

    @Test func gemmaDraftPromptLimitRollbackIsForwarded() {
        let key = MTPAutomaticVerificationPolicy.gemmaMaxDraftPromptTokensEnvironmentKey
        #expect(key == "DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func gemmaM5UltraLoneRowRollbackIsForwarded() {
        let key = MTPAutomaticVerificationPolicy.gemmaM5UltraLoneRowEnvironmentKey
        #expect(key == "DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func gemmaTwoDraftsRollbackIsForwarded() {
        let key = MTPAutomaticVerificationPolicy.gemmaTwoDraftsEnvironmentKey
        #expect(key == "DARKBLOOM_GEMMA_MTP_TWO_DRAFTS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func gemmaLoneRowRollbackIsForwarded() {
        let key = MTPAutomaticVerificationPolicy.gemmaLoneRowEnvironmentKey
        #expect(key == "DARKBLOOM_GEMMA_MTP_LONE_ROW")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }


    @Test("absent mode enables supported embedded heads and exact Gemma QAT")
    func defaultsWhenAbsent() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)

        #expect(config.backend.mtpMode == .auto)
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5", embeddedArtifactDeclared: true))
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5_moe", embeddedArtifactDeclared: true))
        // No embedded declaration → auto never asks, even for Qwen.
        #expect(!config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5", embeddedArtifactDeclared: false))
        #expect(!config.backend.mtpMode.enablesMTP(
            forModelType: nil, embeddedArtifactDeclared: true))
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "gemma4", embeddedArtifactDeclared: false,
            modelID: "gemma-4-26b-qat-4bit"))
        #expect(config.backend.mtpDrafterPath == nil)
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "mimo_v2", embeddedArtifactDeclared: true))
        #expect(!config.backend.mtpMode.enablesMTP(
            forModelType: "mimo_v2", embeddedArtifactDeclared: false))
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

    @Test("the retired boolean mtp key is ignored and warned; mtp_mode stays authoritative")
    func retiredBooleanKey() {
        for stamp in ["", "config_version = 2\n", "config_version = 3\n"] {
            for legacy in ["true", "false"] {
                let config = ConfigManager.parse(
                    """
                    \(stamp)[provider]
                    name = "test-provider"
                    [backend]
                    mtp = \(legacy)
                    """)
                #expect(config.backend.mtpMode == .auto)
                #expect(config.backend.retiredKeysPresent == ["mtp"])
                let messages = RetiredKnobWarnings.messages(config: config, environment: [:])
                #expect(messages.count == 1)
                // A bare `mtp = false` used to mean off and now resolves as
                // `auto`, so the warning must name the exact mtp_mode values
                // that keep the old intent.
                let warning = messages.first ?? ""
                #expect(warning.contains("[backend] mtp,"))
                #expect(warning.contains("RETIRED knob and is IGNORED"))
                #expect(warning.contains(#"default "auto""#))
                #expect(warning.contains(#"To keep MTP off, set mtp_mode = "off""#))
                #expect(warning.contains(#"to force it on, set mtp_mode = "on""#))
                for value in [MTPMode.off, .on, .auto] {
                    #expect(warning.contains(#""\#(value.rawValue)""#))
                }
            }
        }
        let modeWins = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"
            [backend]
            mtp_mode = "off"
            mtp = true
            """)
        #expect(modeWins.backend.mtpMode == .off)
    }

    @Test("automatic embedded heads require a supported embedded model type")
    func targetPolicy() {
        // Declared embedded heads in Qwen 3.5 and native Qwen4 checkpoints
        // self-activate under `auto`. Exact Gemma QAT uses its separately
        // validated external assistant policy below. Nemotron Lightning's
        // declared head needs explicit `on`: it serves plain decode under `auto`.
        let familyModelTypes = ["qwen3_5_moe", "qwen3_5", "qwen4_exp", "qwen4_exp_text", "mimo_v2"]
        let nonFamilyModelTypes: [String?] = [
            "gemma4",
            "gemma4_text",
            "gpt_oss",
            "nemotron_h",
            "qwen3_vl_moe",
            "mimo_v2_flash",
            "mimo_v2_typo",
            nil,
            "  ",
        ]

        for modelType in familyModelTypes {
            #expect(
                MTPMode.auto.enablesMTP(
                    forModelType: modelType, embeddedArtifactDeclared: true),
                "embedded family checkpoint must draft under auto: \(modelType)")
            // Without the embedded declaration, auto never asks — no catalog
            // lookup, no prefetch. Separately published assistants need `on`.
            #expect(
                !MTPMode.auto.enablesMTP(
                    forModelType: modelType, embeddedArtifactDeclared: false),
                "family checkpoint without an embedded head stays target-only: \(modelType)")
            #expect(MTPMode.on.enablesMTP(
                forModelType: modelType, embeddedArtifactDeclared: false))
            #expect(!MTPMode.off.enablesMTP(
                forModelType: modelType, embeddedArtifactDeclared: true))
        }
        for modelType in nonFamilyModelTypes {
            #expect(
                !MTPMode.auto.enablesMTP(
                    forModelType: modelType, embeddedArtifactDeclared: true),
                "non-family model_type must not draft under auto: \(modelType ?? "nil")")
            #expect(MTPMode.on.enablesMTP(
                forModelType: modelType, embeddedArtifactDeclared: false))
            #expect(!MTPMode.off.enablesMTP(
                forModelType: modelType, embeddedArtifactDeclared: true))
        }
        // Model-type matching is case/whitespace-insensitive like every other
        // model_type comparison in the funnel.
        #expect(MTPMode.auto.enablesMTP(
            forModelType: " QWEN3_5_MOE ", embeddedArtifactDeclared: true))
        #expect(MTPMode.auto.enablesMTP(
            forModelType: "Qwen3_5", embeddedArtifactDeclared: true))
        #expect(MTPMode.auto.enablesMTP(
            forModelType: " QWEN4_EXP_TEXT ", embeddedArtifactDeclared: true))
    }

    @Test("automatic Gemma admission requires exact QAT identity and supported target type")
    func automaticGemmaIsExact() {
        for modelType in ["gemma4", " GEMMA4_TEXT "] {
            for embedded in [true, false] {
                #expect(MTPMode.auto.enablesMTP(
                    forModelType: modelType, embeddedArtifactDeclared: embedded,
                    modelID: "gemma-4-26b-qat-4bit"))
                #expect(!MTPMode.off.enablesMTP(
                    forModelType: modelType, embeddedArtifactDeclared: embedded,
                    modelID: "gemma-4-26b-qat-4bit"))
                for modelID in [nil, "gemma-4-26b-8bit", "gemma-4-26b-qat-4bit-copy",
                    "GEMMA-4-26B-QAT-4BIT", " gemma-4-26b-qat-4bit "] as [String?]
                {
                    #expect(!MTPMode.auto.enablesMTP(
                        forModelType: modelType, embeddedArtifactDeclared: embedded,
                        modelID: modelID))
                }
            }
        }
        for modelType in [nil, "gemma4_assistant", "gemma4_text_assistant", "gpt_oss"] as [String?] {
            #expect(!MTPMode.auto.enablesMTP(
                forModelType: modelType, embeddedArtifactDeclared: true,
                modelID: "gemma-4-26b-qat-4bit"))
        }
    }

    @Test("default auto enables only exact Bonsai 9B identities and prewarms their assistant catalog",
          arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func automaticBonsaiIsExact(modelID: String) {
        let backend = BackendSettings()
        let standalone = StandaloneServerConfig()
        for mode in [backend.mtpMode, standalone.mtpMode, .on] {
            #expect(mode.enablesMTP(forModelType: " PRISM_HADAMARD_QWEN35 ",
                embeddedArtifactDeclared: false, modelID: modelID))
            #expect(mode.requiresCatalogPrewarm(forModelType: "prism_hadamard_qwen35", modelID: modelID))
        }
        #expect(!MTPMode.off.enablesMTP(forModelType: "prism_hadamard_qwen35",
            embeddedArtifactDeclared: true, modelID: modelID))
        #expect(!MTPMode.off.requiresCatalogPrewarm(forModelType: "prism_hadamard_qwen35", modelID: modelID))
        for id in [modelID.uppercased(), modelID + "-copy", " " + modelID, "prism-ml/bonsai-27b"] {
            #expect(!MTPMode.auto.enablesMTP(forModelType: "prism_hadamard_qwen35",
                embeddedArtifactDeclared: true, modelID: id))
            #expect(!MTPMode.auto.requiresCatalogPrewarm(forModelType: "prism_hadamard_qwen35", modelID: id))
        }
        for type in [nil, "qwen3_5", "gemma4"] as [String?] {
            #expect(!MTPMode.auto.enablesMTP(forModelType: type,
                embeddedArtifactDeclared: false, modelID: modelID))
            #expect(!MTPMode.auto.requiresCatalogPrewarm(forModelType: type, modelID: modelID))
        }
    }

    @Test("catalog prewarm follows external assistant eligibility without warming embedded heads")
    func catalogPrewarmPolicy() {
        #expect(MTPMode.auto.requiresCatalogPrewarm(
            forModelType: "gemma4", modelID: "gemma-4-26b-qat-4bit"))
        for (modelType, modelID) in [
            ("gemma4", "gemma-4-26b-8bit"),
            ("qwen3_5_moe", "qwen3.6-35b-a3b-vl-mtp-mxfp8"),
            ("qwen4_exp", "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"),
            ("qwen4_exp_text", "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"),
            ("nemotron_h", "nvidia-nemotron-3.5-lightning"),
        ] {
            #expect(!MTPMode.auto.requiresCatalogPrewarm(forModelType: modelType, modelID: modelID))
            #expect(MTPMode.on.requiresCatalogPrewarm(forModelType: modelType, modelID: modelID))
        }
        for mode in [MTPMode.auto, .on, .off] {
            #expect(!mode.requiresCatalogPrewarm(
                forModelType: "gemma4_assistant", modelID: "gemma-4-26b-qat-4bit"))
        }
        #expect(!MTPMode.off.requiresCatalogPrewarm(
            forModelType: "gemma4", modelID: "gemma-4-26b-qat-4bit"))
        for mode in [MTPMode.auto, .on, .off] {
            #expect(!mode.requiresCatalogPrewarm(forModelType: "mimo_v2", modelID: "native-mimo-fixture"))
        }
    }

    @Test("provider and standalone configs use the same target decision")
    func providerAndStandaloneSharePolicy() {
        let backend = BackendSettings(mtpMode: .auto)
        let standalone = StandaloneServerConfig(mtpMode: backend.mtpMode)

        for modelType in ["qwen3_5_moe", "qwen3_5", "qwen4_exp", "qwen4_exp_text", "gemma4", nil] as [String?] {
            for embedded in [true, false] {
                #expect(
                    backend.mtpMode.enablesMTP(
                        forModelType: modelType, embeddedArtifactDeclared: embedded)
                        == standalone.mtpMode.enablesMTP(
                            forModelType: modelType, embeddedArtifactDeclared: embedded))
            }
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

    @Test("a retired boolean mtp key is dropped when the config is saved")
    func retiredBooleanDroppedOnSave() {
        let decoded = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"
            [backend]
            mtp = true
            """)
        let toml = ConfigManager.serialize(decoded)

        #expect(toml.contains("mtp_mode = 'auto'"))
        #expect(!toml.contains("\nmtp = "))
        #expect(ConfigManager.serialize(ConfigManager.parse(toml)) == toml)
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
