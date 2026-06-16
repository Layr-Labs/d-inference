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
