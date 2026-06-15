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
    #expect(config.provider.memoryLimitGB == nil)
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

@Test func configParsingUsesCustomProviderMemoryLimit() throws {
    let config = ConfigManager.parse("""
    [provider]
    name = "test-provider"
    memory_limit_gb = 32
    """)

    #expect(config.provider.memoryLimitGB == 32)
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

@Test func configSerializationRoundTripsProviderMemoryLimit() throws {
    let original = ProviderConfig(
        provider: ProviderSettings(name: "test-provider", memoryLimitGB: 24),
        backend: BackendSettings(),
        coordinator: CoordinatorSettings()
    )

    let toml = ConfigManager.serialize(original)
    let decoded = ConfigManager.parse(toml)

    #expect(toml.contains("memory_limit_gb"))
    #expect(decoded.provider.memoryLimitGB == 24)
}

@Test func providerMemoryLimitCapsEffectiveHardware() throws {
    let hardware = HardwareInfo(
        machineModel: "Mac16,1",
        chipName: "Apple M4 Max",
        chipFamily: .m4,
        chipTier: .max,
        memoryGb: 64,
        memoryAvailableGb: 60,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40,
        memoryBandwidthGbs: 546
    )

    let capped = ProviderMemoryLimit.effectiveHardware(
        hardware,
        limitGB: 32,
        reserveGB: 4
    )

    #expect(capped.memoryGb == 32)
    #expect(capped.memoryAvailableGb == 28)
    #expect(capped.gpuCores == hardware.gpuCores)
}

@Test func providerMemoryLimitDoesNotInflateSmallHardware() throws {
    let hardware = HardwareInfo(
        machineModel: "Mac16,1",
        chipName: "Apple M4 Max",
        chipFamily: .m4,
        chipTier: .max,
        memoryGb: 24,
        memoryAvailableGb: 20,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40,
        memoryBandwidthGbs: 546
    )

    let capped = ProviderMemoryLimit.effectiveHardware(
        hardware,
        limitGB: 32,
        reserveGB: 4
    )

    #expect(capped.memoryGb == 24)
    #expect(capped.memoryAvailableGb == 20)
}
