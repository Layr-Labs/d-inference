/// ConfigManagerTests — TOML parsing, serialization, and config round-trips.

import Testing
import Foundation
@testable import Darkbloom

@Suite("ConfigManager - Default Values")
struct ConfigDefaultTests {

    @Test("default config has expected coordinator URL")
    func defaultCoordinatorURL() {
        let config = ProviderConfig.default
        #expect(config.coordinatorURL.contains("api.darkbloom.dev"))
    }

    @Test("default config has expected backend port")
    func defaultPort() {
        let config = ProviderConfig.default
        #expect(config.backendPort == 8100)
    }

    @Test("default config has 4 GB memory reserve")
    func defaultMemoryReserve() {
        let config = ProviderConfig.default
        #expect(config.memoryReserveGB == 4)
    }

    @Test("default config has no model set")
    func defaultNoModel() {
        let config = ProviderConfig.default
        #expect(config.backendModel == nil)
    }

    @Test("default config has continuous batching enabled")
    func defaultContinuousBatching() {
        let config = ProviderConfig.default
        #expect(config.continuousBatching)
    }

    @Test("default config has empty enabled models list")
    func defaultEmptyModels() {
        let config = ProviderConfig.default
        #expect(config.enabledModels.isEmpty)
    }

    @Test("default heartbeat interval is 30 seconds")
    func defaultHeartbeatInterval() {
        let config = ProviderConfig.default
        #expect(config.heartbeatIntervalSecs == 30)
    }
}

@Suite("ConfigManager - TOML Parsing")
struct ConfigParsingTests {

    @Test("parses complete TOML config")
    func parseComplete() {
        let toml = """
        [provider]
        name = "my-provider"
        memory_reserve_gb = 8

        [backend]
        port = 9000
        model = "mlx-community/Qwen3.5-4B-4bit"
        continuous_batching = true
        enabled_models = ["model-a", "model-b"]

        [coordinator]
        url = "wss://custom.example.com/ws/provider"
        heartbeat_interval_secs = 60
        """

        let config = ConfigManager.parse(toml)

        #expect(config.providerName == "my-provider")
        #expect(config.memoryReserveGB == 8)
        #expect(config.backendPort == 9000)
        #expect(config.backendModel == "mlx-community/Qwen3.5-4B-4bit")
        #expect(config.continuousBatching)
        #expect(config.enabledModels == ["model-a", "model-b"])
        #expect(config.coordinatorURL == "wss://custom.example.com/ws/provider")
        #expect(config.heartbeatIntervalSecs == 60)
    }

    @Test("parses config with missing sections — uses defaults")
    func parseMissingSections() {
        let toml = """
        [provider]
        name = "partial"
        """

        let config = ConfigManager.parse(toml)

        #expect(config.providerName == "partial")
        // Missing sections should get defaults
        #expect(config.backendPort == 8100)
        #expect(config.coordinatorURL.contains("api.darkbloom.dev"))
    }

    @Test("parses empty string — returns all defaults")
    func parseEmpty() {
        let config = ConfigManager.parse("")
        #expect(config == .default)
    }

    @Test("ignores comment lines")
    func parseComments() {
        let toml = """
        # This is a comment
        [provider]
        # Another comment
        name = "test"
        """

        let config = ConfigManager.parse(toml)
        #expect(config.providerName == "test")
    }

    @Test("handles quoted strings with special characters")
    func parseQuotedStrings() {
        let toml = """
        [coordinator]
        url = "wss://host.example.com/ws/provider"
        """

        let config = ConfigManager.parse(toml)
        #expect(config.coordinatorURL == "wss://host.example.com/ws/provider")
    }

    @Test("parses empty model as nil")
    func parseEmptyModel() {
        let toml = """
        [backend]
        model = ""
        """

        let config = ConfigManager.parse(toml)
        #expect(config.backendModel == nil)
    }

    @Test("parses continuous_batching = false")
    func parseBatchingFalse() {
        let toml = """
        [backend]
        continuous_batching = false
        """

        let config = ConfigManager.parse(toml)
        #expect(!config.continuousBatching)
    }

    @Test("parses empty enabled_models array")
    func parseEmptyArray() {
        let toml = """
        [backend]
        enabled_models = []
        """

        let config = ConfigManager.parse(toml)
        #expect(config.enabledModels.isEmpty)
    }
}

@Suite("ConfigManager - TOML Serialization")
struct ConfigSerializationTests {

    @Test("serialize produces valid TOML with all sections")
    func serializeComplete() {
        let config = ProviderConfig(
            providerName: "test-node",
            memoryReserveGB: 8,
            backendPort: 9000,
            backendModel: "mlx-community/Qwen3.5-4B-4bit",
            continuousBatching: true,
            enabledModels: ["a", "b"],
            coordinatorURL: "wss://example.com/ws",
            heartbeatIntervalSecs: 45
        )

        let toml = ConfigManager.serialize(config)

        #expect(toml.contains("[provider]"))
        #expect(toml.contains("[backend]"))
        #expect(toml.contains("[coordinator]"))
        #expect(toml.contains("\"test-node\""))
        #expect(toml.contains("memory_reserve_gb = 8"))
        #expect(toml.contains("port = 9000"))
        #expect(toml.contains("\"mlx-community/Qwen3.5-4B-4bit\""))
        #expect(toml.contains("heartbeat_interval_secs = 45"))
    }

    @Test("serialize omits model line when nil")
    func serializeNilModel() {
        var config = ProviderConfig.default
        config.backendModel = nil

        let toml = ConfigManager.serialize(config)
        #expect(!toml.contains("model ="))
    }
}

@Suite("ConfigManager - Round Trip")
struct ConfigRoundTripTests {

    @Test("parse(serialize(config)) preserves all fields")
    func roundTrip() {
        let original = ProviderConfig(
            providerName: "round-trip-test",
            memoryReserveGB: 6,
            backendPort: 7777,
            backendModel: "mlx-community/test-model",
            continuousBatching: false,
            enabledModels: ["model-x", "model-y"],
            coordinatorURL: "wss://roundtrip.example.com/ws/provider",
            heartbeatIntervalSecs: 15
        )

        let toml = ConfigManager.serialize(original)
        let parsed = ConfigManager.parse(toml)

        #expect(parsed.providerName == original.providerName)
        #expect(parsed.memoryReserveGB == original.memoryReserveGB)
        #expect(parsed.backendPort == original.backendPort)
        #expect(parsed.backendModel == original.backendModel)
        #expect(parsed.continuousBatching == original.continuousBatching)
        #expect(parsed.enabledModels == original.enabledModels)
        #expect(parsed.coordinatorURL == original.coordinatorURL)
        #expect(parsed.heartbeatIntervalSecs == original.heartbeatIntervalSecs)
    }

    @Test("round trip with default config")
    func roundTripDefaults() {
        let original = ProviderConfig.default
        let toml = ConfigManager.serialize(original)
        let parsed = ConfigManager.parse(toml)

        #expect(parsed.providerName == original.providerName)
        #expect(parsed.memoryReserveGB == original.memoryReserveGB)
        #expect(parsed.backendPort == original.backendPort)
        #expect(parsed.continuousBatching == original.continuousBatching)
        #expect(parsed.coordinatorURL == original.coordinatorURL)
        #expect(parsed.heartbeatIntervalSecs == original.heartbeatIntervalSecs)
    }

    @Test("save and load round trip to temp directory")
    func saveLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-test-\(UUID().uuidString)")
        let tmpFile = tmpDir.appendingPathComponent("provider.toml")

        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let config = ProviderConfig(
            providerName: "save-load-test",
            memoryReserveGB: 12,
            backendPort: 5555,
            backendModel: "test/model",
            continuousBatching: true,
            enabledModels: ["m1"],
            coordinatorURL: "wss://save.test/ws",
            heartbeatIntervalSecs: 20
        )

        // Save
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let toml = ConfigManager.serialize(config)
        try toml.write(to: tmpFile, atomically: true, encoding: .utf8)

        // Load
        let loaded = try String(contentsOf: tmpFile, encoding: .utf8)
        let parsed = ConfigManager.parse(loaded)

        #expect(parsed.providerName == "save-load-test")
        #expect(parsed.memoryReserveGB == 12)
        #expect(parsed.backendPort == 5555)
        #expect(parsed.backendModel == "test/model")
        #expect(parsed.coordinatorURL == "wss://save.test/ws")
    }
}
