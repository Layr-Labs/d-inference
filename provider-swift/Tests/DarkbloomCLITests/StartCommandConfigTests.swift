import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Start command config persistence")
struct StartCommandConfigTests {

    @Test("memory-limit override is written to provider config")
    func memoryLimitOverridePersistsToConfig() throws {
        let configPath = tempConfigPath()
        defer { try? FileManager.default.removeItem(at: configPath) }

        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider", memoryReserveGB: 6),
            backend: BackendSettings(idleTimeoutMins: 45),
            coordinator: CoordinatorSettings(url: "wss://example.test/ws/provider", heartbeatIntervalSecs: 9)
        )
        try ConfigManager.save(original, to: configPath)

        let persisted = try Start.persistMemoryLimitOverride(
            memoryLimitGB: 24,
            baseConfig: original,
            to: configPath
        )
        let reloaded = try ConfigManager.load(from: configPath)

        #expect(persisted.provider.memoryLimitGB == 24)
        #expect(reloaded.provider.memoryLimitGB == 24)
        #expect(reloaded.provider.memoryReserveGB == 6)
        #expect(reloaded.backend.idleTimeoutMins == 45)
        #expect(reloaded.coordinator.url == "wss://example.test/ws/provider")
    }

    @Test("absent memory-limit override does not write config")
    func absentMemoryLimitOverrideDoesNotWriteConfig() throws {
        let configPath = tempConfigPath()
        defer { try? FileManager.default.removeItem(at: configPath) }

        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )

        let returned = try Start.persistMemoryLimitOverride(
            memoryLimitGB: nil,
            baseConfig: original,
            to: configPath
        )

        #expect(returned == original)
        #expect(!FileManager.default.fileExists(atPath: configPath.path))
    }

    private func tempConfigPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("start-config-\(UUID().uuidString).toml")
    }
}
