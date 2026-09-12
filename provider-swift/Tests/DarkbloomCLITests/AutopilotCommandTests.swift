import Foundation
import Testing
@testable import darkbloom
import ProviderCore

@Suite("ModelAutopilot CLI")
struct AutopilotCommandTests {
    @Test func enrollmentPersistsWithoutChangingLegacyModelOrIdlePolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "autopilot-test"))
        config.backend.enabledModels = ["a", "b"]
        config.backend.idleTimeoutMins = 17
        try ConfigManager.save(config, to: path)
        try setModelAutopilot(enabled: true, dwell: 600, pins: ["b", "b"], configPath: path.path)
        let enabled = try ConfigManager.load(from: path)
        #expect(enabled.backend.modelAutopilot.enabled)
        #expect(enabled.backend.modelAutopilot.minDwellSeconds == 600)
        #expect(enabled.backend.modelAutopilot.pinnedModels == ["b"])
        #expect(enabled.backend.enabledModels == ["a", "b"])
        #expect(enabled.backend.idleTimeoutMins == 17)
        try setModelAutopilot(enabled: false, configPath: path.path)
        let disabled = try ConfigManager.load(from: path)
        #expect(!disabled.backend.modelAutopilot.enabled)
        #expect(disabled.backend.modelAutopilot.pinnedModels == ["b"])
    }
}
