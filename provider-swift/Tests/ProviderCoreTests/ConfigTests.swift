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
