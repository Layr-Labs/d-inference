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

// MARK: - engine_v2_max_concurrent: v0.8.0 default + pre-v0.8.0 migration
//
// v0.8.0 raises the box-wide concurrency default 4 -> 8. It was originally
// coupled to flipping `.auto` to paged KV; that flip was reverted (paged
// adoption is not transparent — adopted output differs from its own cold
// output on the same prompt), but the raise stands on its own: contiguous
// gains ~1.07x from B=4 to B=8.

@Test func maxConcurrentAbsentKeyDefaultsToEight() throws {
    // No `[backend]` section at all...
    let bare = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    """)
    #expect(bare.backend.engineV2MaxConcurrent == 8)

    // ...and a `[backend]` section that simply omits the key.
    let partial = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)
    #expect(partial.backend.engineV2MaxConcurrent == 8)

    // What actually reaches the engine slot: the decoded cap through the
    // [1, 8] product clamp. This is the number the paged/contiguous
    // crossover is measured against.
    #expect(ProviderLoop.clampEngineV2Concurrency(partial.backend.engineV2MaxConcurrent) == 8)
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

@Test func maxConcurrentExplicitEightStaysEight() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    engine_v2_max_concurrent = 8
    """)

    #expect(config.backend.engineV2MaxConcurrent == 8)
    // 8 is the new default, so nothing was migrated — the operator gets no
    // warning for agreeing with us.
    #expect(config.appliedMigrations.isEmpty)
}

// A pre-v0.8.0 `provider.toml` carries an EXPLICIT `engine_v2_max_concurrent
// = 4` — `TOMLEncoder` emits every non-optional key, the same reason every
// field config still carries `kv_quant` (see
// `configParsingRetiresKVQuantWithoutLosingNeighbours`). Absence of
// `config_version` is the only thing that dates such a file, so it is spent
// here: the generated 4 is raised once and announced.
@Test func maxConcurrentUnstampedGeneratedFourIsRaisedToEightAndAnnounced() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    engine_v2_max_concurrent = 4
    """)

    #expect(config.backend.engineV2MaxConcurrent == 8)
    #expect(config.appliedMigrations == [ProviderConfig.legacyMaxConcurrentMigrationID])

    // The operator is told, on the shared startup surface every serve mode
    // uses, including how to keep 4.
    let messages = RetiredKnobWarnings.messages(config: config, environment: [:])
    #expect(messages.count == 1)
    let warning = try #require(messages.first)
    #expect(warning.contains("engine_v2_max_concurrent"))
    #expect(warning.contains("config_version"))
    #expect(warning.contains("set it again"))
}

// The migration burns exactly one boot. Once the file is stamped, 4 is just a
// number an operator chose, and it is honoured verbatim forever.
@Test func maxConcurrentStampedFourIsHonouredNotMigrated() throws {
    let config = ConfigManager.parse("""
    config_version = 1

    [provider]
    name = "test-provider"

    [backend]
    engine_v2_max_concurrent = 4
    """)

    #expect(config.backend.engineV2MaxConcurrent == 4)
    #expect(config.appliedMigrations.isEmpty)
    #expect(RetiredKnobWarnings.messages(config: config, environment: [:]).isEmpty)
}

// Blast radius: ONLY the value old releases actually generated is ambiguous.
// Every other cap in range was necessarily typed by a human, so an unstamped
// file carrying one is left exactly as written.
@Test func maxConcurrentUnstampedNonGeneratedValuesAreNeverRewritten() throws {
    for chosen in [1, 2, 3, 5, 6, 7, 8] as [UInt64] {
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

// The stamp has to survive the serializer, or a deliberate 4 could never be
// written back and would be re-migrated on every boot.
@Test func configVersionStampRoundTripsAndPinsADeliberateFour() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(engineV2MaxConcurrent: 4),
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
    #expect(decoded.backend.engineV2MaxConcurrent == 4)
    #expect(decoded.appliedMigrations.isEmpty)
}
