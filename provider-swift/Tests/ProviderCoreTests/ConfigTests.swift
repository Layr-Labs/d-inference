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

@Test func configParsingDefaultsAdaptivePrefillToFalse() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    port = 8100
    """)

    #expect(config.backend.adaptivePrefill == false)
}

@Test func configParsingHonoursAdaptivePrefillTrue() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"

    [backend]
    adaptive_prefill = true
    """)

    #expect(config.backend.adaptivePrefill == true)
}

@Test func configSerializationRoundTripsAdaptivePrefill() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider"),
        backend: BackendSettings(adaptivePrefill: true),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    #expect(toml.contains("adaptive_prefill"))
    #expect(decoded.backend.adaptivePrefill == true)
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
