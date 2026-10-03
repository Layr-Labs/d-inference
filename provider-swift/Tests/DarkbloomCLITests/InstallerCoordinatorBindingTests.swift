import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The installer served by a non-production coordinator writes that
/// coordinator into provider.toml. These tests run the real installer step
/// and read the result through the same loaders `start`, `login`, `update`
/// and the watchdog use.
@Suite("Installer coordinator binding")
struct InstallerCoordinatorBindingTests {
    private static let devCoordinator = "https://api.dev.darkbloom.xyz"
    private static let devProviderURL = "wss://api.dev.darkbloom.xyz/ws/provider"

    private func tempConfigURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("provider.toml")
    }

    private func runInstallerBinding(coordinator: String, config: URL) throws {
        let installer = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DarkbloomCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // provider-swift
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("scripts/install.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer.path, "--bind-coordinator-test", config.path]
        var environment = ProcessInfo.processInfo.environment
        environment["COORD_URL"] = coordinator
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("a fresh dev install binds start, login, update and the watchdog to dev")
    func freshInstallBindsEveryCommandPath() throws {
        let config = try tempConfigURL()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        try runInstallerBinding(coordinator: Self.devCoordinator, config: config)

        let snapshot = try loadRuntimeSnapshot(configPath: config.path)
        #expect(snapshot.configFileExists)
        #expect(snapshot.config.coordinator.url == Self.devProviderURL)
        #expect(snapshot.config.coordinator.heartbeatIntervalSecs == CoordinatorSettings().heartbeatIntervalSecs)
        #expect(try loadUpdateConfig(configPath: config.path).coordinator.url == Self.devProviderURL)
        #expect(Watchdog.settings(configPath: config.path, environment: [:]).coordinatorURL == Self.devProviderURL)
    }

    @Test("binding an existing config changes only the coordinator url")
    func existingConfigKeepsOtherSettings() throws {
        let config = try tempConfigURL()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let original = ProviderConfig(
            provider: ProviderSettings(name: "seed-mac", memoryReserveGB: 6, autoUpdate: false),
            backend: BackendSettings(port: 8200, enabledModels: ["model-a", "model-b"], idleTimeoutMins: 15),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 9, privateOnly: true))
        try ConfigManager.save(original, to: config)

        try runInstallerBinding(coordinator: Self.devCoordinator, config: config)

        var expected = original
        expected.coordinator.url = Self.devProviderURL
        #expect(try ConfigManager.load(from: config) == expected)
    }

    @Test("the production installer creates no config")
    func productionInstallerDoesNotCreateConfig() throws {
        let config = try tempConfigURL()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

        try runInstallerBinding(coordinator: "https://api.darkbloom.dev", config: config)

        #expect(!FileManager.default.fileExists(atPath: config.path))
    }

    @Test("the production installer moves a dev-bound Mac back to the production default")
    func productionInstallerRestoresDefault() throws {
        let config = try tempConfigURL()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let original = ProviderConfig(
            provider: ProviderSettings(name: "seed-mac", memoryReserveGB: 6, autoUpdate: false),
            backend: BackendSettings(port: 8200, enabledModels: ["model-a"], idleTimeoutMins: 15),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 9, privateOnly: true))
        try ConfigManager.save(original, to: config)

        try runInstallerBinding(coordinator: Self.devCoordinator, config: config)
        #expect(try ConfigManager.load(from: config).coordinator.url == Self.devProviderURL)
        try runInstallerBinding(coordinator: "https://api.darkbloom.dev", config: config)

        let restored = try ConfigManager.load(from: config)
        #expect(restored == original)
        #expect(restored.coordinator.url == CoordinatorSettings().url)
        #expect(try loadUpdateConfig(configPath: config.path).coordinator.url == CoordinatorSettings().url)
    }
}
