import Foundation
import Testing
@testable import darkbloom
import ProviderCore

@Suite("Autopilot drained replacement")
struct AutopilotReplacementTests {
    @Test func unreadableEnrollmentNeverStopsDrainedService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        let invalidConfig = Data([0xff, 0xfe, 0xfd])
        try invalidConfig.write(to: path)
        var serviceRunning = true
        var replacementStarted = false
        await #expect(throws: (any Error).self) {
            try await Start.completeDaemonReplacement(autopilot: true, models: ["selected"], configPath: path.path,
                stop: { serviceRunning = false }, install: { replacementStarted = true })
        }
        #expect(serviceRunning)
        #expect(!replacementStarted)
        #expect(try Data(contentsOf: path) == invalidConfig)
    }

    @Test func selectedConsentIsDurableBeforeStopAndInstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        try ConfigManager.save(ProviderConfig(provider: .init(name: "replacement")), to: path)
        var stopped = false
        var started = false
        try await Start.completeDaemonReplacement(autopilot: true, models: ["selected"], configPath: path.path,
            stop: {
                let saved = try ConfigManager.load(from: path)
                #expect(saved.backend.modelAutopilot.hasConsent)
                #expect(saved.backend.modelAutopilot.selectedModels == ["selected"])
                stopped = true
            }, install: {
                #expect(stopped)
                started = true
            })
        #expect(started)
    }
}
