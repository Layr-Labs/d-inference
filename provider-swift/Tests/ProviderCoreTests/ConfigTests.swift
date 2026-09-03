import Foundation
import Testing
@testable import ProviderCore

@Test func configParsingDefaultsMaxModelSlotsWhenMissing() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)

    #expect(config.backend.maxModelSlots == 3)
}

@Test func configParsingUsesCustomMaxModelSlots() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    max_model_slots = 7
    """)

    #expect(config.backend.maxModelSlots == 7)
}

@Test func configSerializationRoundTripsMaxModelSlots() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(maxModelSlots: 5),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    #expect(toml.contains("max_model_slots"))
    #expect(decoded.backend.maxModelSlots == 5)
}

@Test func prefillDeadlineModePreservesAbsentInheritance() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    """)
    #expect(config.backend.prefillDeadlineMode == nil)
    #expect(
        PrefillDeadlineMode.resolve(
            configured: config.backend.prefillDeadlineMode,
            environment: [:]) == .enforce)

    let serialized = ConfigManager.serialize(config)
    #expect(!serialized.contains("prefill_deadline_mode"))
    #expect(ConfigManager.parse(serialized).backend.prefillDeadlineMode == nil)
}

@Test func prefillDeadlineModeParsesAndSerializes() throws {
    let disabled = ConfigManager.parse("""
    [backend]
    prefill_deadline_mode = "off"
    """)
    #expect(disabled.backend.prefillDeadlineMode == .off)
    let enforced = ConfigManager.parse("""
    [backend]
    prefill_deadline_mode = "enforce"
    """)
    #expect(enforced.backend.prefillDeadlineMode == .enforce)

    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(prefillDeadlineMode: .off),
        coordinator: CoordinatorSettings())
    let serialized = ConfigManager.serialize(original)
    #expect(serialized.contains("prefill_deadline_mode = 'off'"))
    #expect(
        ConfigManager.parse(serialized).backend.prefillDeadlineMode == .off)

    let enforcing = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(prefillDeadlineMode: .enforce),
        coordinator: CoordinatorSettings())
    let enforcingTOML = ConfigManager.serialize(enforcing)
    #expect(enforcingTOML.contains("prefill_deadline_mode = 'enforce'"))
    #expect(
        ConfigManager.parse(enforcingTOML).backend.prefillDeadlineMode == .enforce)
}

// v0.8.0 removed KV quantization from the product. Effectively every
// provider.toml in the field carries `kv_quant` because the serializer used
// to round-trip it, so an UPGRADING provider must load such a config without
// error, keep every other setting, and surface `kv_quant` for the
// retired-key WARN — the same treatment the v0.7.5 one-engine knobs get.
@Test func configParsingRetiresKVQuantWithoutLosingNeighbours() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    kv_quant = true
    max_model_slots = 7
    idle_timeout_mins = 30
    engine_v2_kv_backend = "paged"
    mtp = true
    """)

    #expect(config.backend.retiredKeysPresent == ["kv_quant"])
    // Every neighbouring setting survives the retired key.
    #expect(config.provider.name == "test-provider")
    #expect(config.backend.port == 8100)
    #expect(config.backend.maxModelSlots == 7)
    #expect(config.backend.idleTimeoutMins == 30)
    #expect(config.backend.engineV2KVBackend == "paged")
    #expect(config.backend.mtpMode == .on)
    #expect(config.backend.mtp == true)
}

@Test func configParsingSurfacesNoRetiredKeysByDefault() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)

    #expect(config.backend.retiredKeysPresent.isEmpty)
}

// v0.7.5 one-engine (plus `kv_quant`, retired in v0.8.0): these [backend]
// keys are RETIRED. An old provider.toml must keep parsing cleanly — a stale
// config can never brick a provider — and the retired keys must be SURFACED
// (startup WARNs off this list) rather than silently swallowed. Values ignored.
@Test func configParsingSurfacesRetiredKeysWithoutFailing() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    engine_v2 = false
    continuous_batching = false
    adaptive_prefill = true
    legacy_compiled_decode = true
    kv_quant = true
    idle_timeout_mins = 30
    """)

    #expect(
        Set(config.backend.retiredKeysPresent) == [
            "engine_v2", "continuous_batching", "adaptive_prefill",
            "legacy_compiled_decode", "kv_quant",
        ])
    // Live neighbors still decode.
    #expect(config.backend.idleTimeoutMins == 30)
}

@Test func configSerializationDropsRetiredKeys() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    // Retired keys are never re-emitted, so a config round-trip sheds them.
    #expect(!toml.contains("adaptive_prefill"))
    #expect(!toml.contains("engine_v2 ="))
    #expect(!toml.contains("continuous_batching"))
    #expect(!toml.contains("legacy_compiled_decode"))
    #expect(!toml.contains("kv_quant"))
    #expect(decoded.backend.retiredKeysPresent.isEmpty)
}

// The warning text docs/provider/beta-features.md promises, produced by the
// single shared emitter `Start.run()` calls before it picks a serving mode.
// It used to be inlined in `ProviderLoop.run()`, which `darkbloom start
// --local` never builds — a standalone operator upgrading a provider.toml
// that still set `kv_quant` was told nothing at all.
@Test func retiredKnobWarningsNameEveryRetiredConfigKeyAndEnvVar() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    kv_quant = true
    engine_v2 = false
    """)

    let messages = RetiredKnobWarnings.messages(config: config, environment: [:])
    #expect(messages.count == 2)
    #expect(messages.contains(
        "provider.toml sets [backend] kv_quant, which is a RETIRED knob and is "
            + "IGNORED — remove the key"))
    #expect(messages.contains { $0.contains("[backend] engine_v2,") })

    // Retired ENV vars earn their own line, ahead of the config keys.
    let withEnv = RetiredKnobWarnings.messages(
        config: config, environment: ["DARKBLOOM_COMPILED_DECODE": "1"])
    #expect(withEnv.count == 3)
    #expect(withEnv.first?.hasPrefix("DARKBLOOM_COMPILED_DECODE is retired") == true)

    // A clean config earns silence — no warning fatigue for the common box.
    let clean = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    """)
    #expect(RetiredKnobWarnings.messages(config: clean, environment: [:]).isEmpty)
}

// MARK: - Startup preload + rollover jitter keys

@Test func configParsingDefaultsStartupPreloadKeys() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)

    // Fleet-safe defaults: preload on (but a fresh install has no persisted
    // set, so behavior is unchanged until a model has been served), 120s gate,
    // self-test on + fail-open, 0-300s update jitter.
    #expect(config.backend.startupPreload == true)
    #expect(config.backend.preloadModels == [])
    #expect(config.backend.startupPreloadTimeoutSecs == 120)
    #expect(config.backend.startupSelftest == true)
    #expect(config.backend.startupSelftestFailClosed == false)
    #expect(config.provider.updateJitterSeconds == 300)
}

@Test func configParsingHonoursStartupPreloadKeys() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    update_jitter_seconds = 0

    [backend]
    startup_preload = false
    preload_models = ["gemma-4-26b-it", "qwen3-8b"]
    startup_preload_timeout_secs = 45
    startup_selftest = false
    startup_selftest_fail_closed = true
    """)

    #expect(config.backend.startupPreload == false)
    #expect(config.backend.preloadModels == ["gemma-4-26b-it", "qwen3-8b"])
    #expect(config.backend.startupPreloadTimeoutSecs == 45)
    #expect(config.backend.startupSelftest == false)
    #expect(config.backend.startupSelftestFailClosed == true)
    #expect(config.provider.updateJitterSeconds == 0)
}

@Test func configSerializationRoundTripsStartupPreloadKeys() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider", updateJitterSeconds: 60),
        backend: BackendSettings(
            preloadModels: ["gemma-4-26b-it"],
            startupPreloadTimeoutSecs: 90,
            startupSelftest: false),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    #expect(toml.contains("preload_models"))
    #expect(toml.contains("update_jitter_seconds"))
    #expect(decoded.backend.preloadModels == ["gemma-4-26b-it"])
    #expect(decoded.backend.startupPreloadTimeoutSecs == 90)
    #expect(decoded.backend.startupSelftest == false)
    #expect(decoded.provider.updateJitterSeconds == 60)
}

// MARK: - engine_v2_max_concurrent: v0.8.1 default + config_version migration
//
// v0.8.1 reverts the box-wide concurrency default 8 -> 4, alongside the
// `.auto` flip back to contiguous KV. The two ARE coupled: v0.8.0's raise was
// justified by paged's batch curve (1.27x from B=4 to B=8, against contiguous'
// 1.069x), so reverting the backend takes the raise with it.

@Test func maxConcurrentAbsentKeyDefaultsToFour() throws {
    // No `[backend]` section at all...
    let bare = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    """)
    #expect(bare.backend.engineV2MaxConcurrent == 4)

    // ...and a `[backend]` section that simply omits the key.
    let partial = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)
    #expect(partial.backend.engineV2MaxConcurrent == 4)

    // What actually reaches the engine slot: the decoded cap through the
    // [1, 8] product clamp.
    #expect(ProviderLoop.clampEngineV2Concurrency(partial.backend.engineV2MaxConcurrent) == 4)
}

// The upper bound of the clamp deliberately stays 8 even though the default
// dropped to 4: a box that asks for paged by name is still allowed the batch
// depth where paged pays, and the per-model override map can name it.
@Test func maxConcurrentClampStillAdmitsEightAtTheTop() throws {
    #expect(ProviderLoop.clampEngineV2Concurrency(8) == 8)
    #expect(ProviderLoop.clampEngineV2Concurrency(9) == 8)
    #expect(ProviderLoop.clampEngineV2Concurrency(4) == 4)
    #expect(ProviderLoop.clampEngineV2Concurrency(0) == 1)
}

// The bug this whole section exists for: the memberwise default moved 4 -> 8
// while `init(from:)` kept its own literal `?? 4`, so every provider that
// loaded a config file — i.e. all of them — stayed at B=4 while `.auto` went
// paged. Pin the two together so they cannot drift again.
@Test func maxConcurrentMemberwiseAndDecodeDefaultsCannotDrift() throws {
    let decoded = try JSONDecoder().decode(
        BackendSettings.self, from: Data(#"{}"#.utf8))
    #expect(decoded.engineV2MaxConcurrent == BackendSettings().engineV2MaxConcurrent)
    #expect(decoded.engineV2MaxConcurrent == BackendSettings.defaultEngineV2MaxConcurrent)
}

@Test func maxConcurrentExplicitFourStaysFour() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    engine_v2_max_concurrent = 4
    """)

    #expect(config.backend.engineV2MaxConcurrent == 4)
    // 4 is the new default, so nothing was migrated — the operator gets no
    // warning for agreeing with us.
    #expect(config.appliedMigrations.isEmpty)
}

// THE POINT OF THE WHOLE MECHANISM. Every v0.8.0 `provider.toml` carries an
// EXPLICIT `engine_v2_max_concurrent = 8` — `TOMLEncoder` emits every
// non-optional key, the same reason every field config still carries
// `kv_quant` (see `configParsingRetiresKVQuantWithoutLosingNeighbours`). A
// literal does not track the binary, so without this step moving the default
// constant would reach fresh installs only and be a fleet-wide no-op.
@Test func maxConcurrentStampedOneEightIsMigratedToFourAndAnnounced() throws {
    let config = ConfigManager.parse("""
    config_version = 1

    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    engine_v2_max_concurrent = 8
    """)

    #expect(config.backend.engineV2MaxConcurrent == 4)
    #expect(config.appliedMigrations == [ConcurrencyDefaultMigration.v081ConcurrencyRevert.id])

    // The operator is told, on the shared startup surface every serve mode
    // uses — including, plainly, that this cannot tell their 8 from ours.
    let messages = RetiredKnobWarnings.messages(config: config, environment: [:])
    #expect(messages.count == 1)
    let warning = try #require(messages.first)
    #expect(warning.contains("engine_v2_max_concurrent"))
    #expect(warning.contains("config_version"))
    #expect(warning.contains("CANNOT TELL"))
    #expect(warning.contains("set it again"))
}

// Blast radius: ONLY the exact value v0.8.0 generated moves. Every other cap
// in range was necessarily typed by a human, so it is left exactly as written
// even though the file is the right schema generation for the step.
@Test func maxConcurrentStampedOneHandSetValuesSurviveUntouched() throws {
    for chosen in [1, 2, 3, 5, 6, 7] as [UInt64] {
        let config = ConfigManager.parse("""
        config_version = 1

        [provider]
        name = "test-provider"

        [backend]
        engine_v2_max_concurrent = \(chosen)
        """)
        #expect(config.backend.engineV2MaxConcurrent == chosen)
        #expect(config.appliedMigrations.isEmpty)
        #expect(RetiredKnobWarnings.messages(config: config, environment: [:]).isEmpty)
    }
}

// The migration burns exactly one boot. Once the file carries the v0.8.1
// stamp, 8 is just a number an operator chose, and it is honoured forever.
@Test func maxConcurrentStampedTwoEightIsHonouredNotMigrated() throws {
    let config = ConfigManager.parse("""
    config_version = 2

    [provider]
    name = "test-provider"

    [backend]
    engine_v2_max_concurrent = 8
    """)

    #expect(config.backend.engineV2MaxConcurrent == 8)
    #expect(config.appliedMigrations.isEmpty)
    #expect(RetiredKnobWarnings.messages(config: config, environment: [:]).isEmpty)
}

// An UNSTAMPED file predates v0.8.0. Its cap is either the 4 that release
// generated — which is v0.8.1's default anyway — or a value a human typed, so
// v0.8.1 changes neither. This is a deliberate retirement of the old 4 -> 8
// step: keeping it would now migrate 4 to 4 and announce a change that did not
// happen, and a pre-v0.8.0 operator's deliberate 4 is finally honoured.
@Test func maxConcurrentUnstampedValuesAreNeverRewritten() throws {
    for chosen in [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64] {
        let config = ConfigManager.parse("""
        [provider]
        name = "test-provider"

        [backend]
        engine_v2_max_concurrent = \(chosen)
        """)
        #expect(config.backend.engineV2MaxConcurrent == chosen)
        #expect(config.appliedMigrations.isEmpty)
    }
}

// Guard both generated-value migrations against drifting from the defaults
// and schema generation they are meant to establish.
@Test func migrationStepsLandOnTheirCurrentPolicies() throws {
    let newestConcurrency = try #require(ConcurrencyDefaultMigration.steps.last)
    #expect(newestConcurrency.toCap == BackendSettings.defaultEngineV2MaxConcurrent)
    #expect(newestConcurrency.toVersion <= ProviderConfig.currentConfigVersion)
    #expect(
        MTPModeDefaultMigration.targetConfigVersion
            == ProviderConfig.currentConfigVersion)
}

// The stamp has to survive the serializer, or a deliberate cap could never be
// written back and would be re-migrated on every boot.
@Test func configVersionStampRoundTripsAndPinsADeliberateEight() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(engineV2MaxConcurrent: 8),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    #expect(toml.contains("config_version"))
    // A top-level key is only valid TOML ahead of the first table header.
    let firstTable = try #require(toml.range(of: "["))
    let stamp = try #require(toml.range(of: "config_version"))
    #expect(stamp.lowerBound < firstTable.lowerBound)

    let decoded = ConfigManager.parse(toml)
    #expect(decoded.configVersion == ProviderConfig.currentConfigVersion)
    #expect(decoded.backend.engineV2MaxConcurrent == 8)
    #expect(decoded.appliedMigrations.isEmpty)
}

// MARK: - MTP configuration and verification policy

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


    @Test("absent mode defaults on for embedded Qwen3.5-family heads only")
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
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5", embeddedArtifactDeclared: true))
        #expect(config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5_moe", embeddedArtifactDeclared: true))
        // No embedded declaration → auto never asks, even for Qwen.
        #expect(!config.backend.mtpMode.enablesMTP(
            forModelType: "qwen3_5", embeddedArtifactDeclared: false))
        #expect(!config.backend.mtpMode.enablesMTP(
            forModelType: nil, embeddedArtifactDeclared: true))
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

    @Test("automatic mode requires an embedded head AND a Qwen3.5-family model type")
    func targetPolicy() {
        // Embedded (mtplx_mtp-declaring) checkpoints of the Qwen 3.5 family —
        // dense (9B, 27B) and MoE (3.5/3.6 35B) — self-activate under `auto`.
        // The family gate is hardcoded to Qwen for now and widens only when
        // another family actually ships embedded artifacts.
        let familyModelTypes = ["qwen3_5_moe", "qwen3_5"]
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
    }

    @Test("provider and standalone configs use the same target decision")
    func providerAndStandaloneSharePolicy() {
        let backend = BackendSettings(mtpMode: .auto)
        let standalone = StandaloneServerConfig(mtpMode: backend.mtpMode)

        for modelType in ["qwen3_5_moe", "qwen3_5", "gemma4", nil] as [String?] {
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
