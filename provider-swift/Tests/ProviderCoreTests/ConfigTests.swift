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

@Test func configParsingDefaultsKVQuantToFalse() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)

    #expect(config.backend.kvQuant == false)
}

@Test func configParsingHonoursKVQuantTrue() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    kv_quant = true
    """)

    #expect(config.backend.kvQuant == true)
}

@Test func configSerializationRoundTripsKVQuant() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(kvQuant: true),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    #expect(toml.contains("kv_quant"))
    #expect(decoded.backend.kvQuant == true)
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

// v0.7.5 one-engine: the legacy engine's [backend] keys are RETIRED. An
// old provider.toml must keep parsing cleanly — a stale config can never
// brick a provider — and the retired keys must be SURFACED (startup WARNs
// off this list) rather than silently swallowed. Their values are ignored.
@Test func configParsingSurfacesRetiredKeysWithoutFailing() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    engine_v2 = false
    continuous_batching = false
    adaptive_prefill = true
    legacy_compiled_decode = true
    idle_timeout_mins = 30
    """)

    #expect(
        Set(config.backend.retiredKeysPresent) == [
            "engine_v2", "continuous_batching", "adaptive_prefill",
            "legacy_compiled_decode",
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
    #expect(decoded.backend.retiredKeysPresent.isEmpty)
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
