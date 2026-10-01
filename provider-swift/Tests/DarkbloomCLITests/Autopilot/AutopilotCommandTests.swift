import ArgumentParser
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

extension AutopilotCommandTests {
    @Test func startupConsentRequiresExplicitYes() {
        #expect(!Start.autopilotAnswer(nil))
        #expect(!Start.autopilotAnswer(""))
        #expect(!Start.autopilotAnswer("n"))
        #expect(!Start.autopilotAnswer("maybe"))
        #expect(Start.autopilotAnswer(" Y "))
        #expect(Start.autopilotAnswer("yes"))
    }

    @Test(arguments: ["", "n", "Y"])
    func startupPromptExplainsShadowBeforeTakingInterest(answer: String) {
        var output = ""
        let interested = Start.promptAutopilotChoice(readInput: {
            #expect(output.contains("proposed model changes are recorded, not activated"))
            #expect(output.contains("does not activate live control"))
            #expect(output.contains("all downloaded models supported by our network"))
            #expect(output.contains("No extra model selection or downloads"))
            #expect(output.contains("preferences stay unchanged"))
            #expect(output.contains("improve network utilization"))
            #expect(output.hasSuffix("[y/N]: "))
            return answer
        }, emit: { output += $0 })
        #expect(interested == (answer == "Y"))
    }

    @Test func statusDistinguishesEnrollmentFromLiveActivation() {
        #expect(Autopilot.Status.phaseDescription("shadow") == "shadow (not activated; no automatic model changes)")
        #expect(Autopilot.Status.phaseDescription("waiting").contains("not activated"))
        #expect(Autopilot.Status.phaseDescription("active") == "active")
        #expect(Autopilot.Status.phaseDescription("recovering") == "recovering")
        #expect(Autopilot.Status.phaseDescription(nil) == "daemon not reporting")
    }

    @Test(arguments: ["too-many", "empty-id", "long-id", "multibyte-id"])
    func invalidEnrollmentSelectionNeverChangesConfiguration(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        try ConfigManager.save(ProviderConfig(provider: ProviderSettings(name: "selection-bounds")), to: path)
        let before = try Data(contentsOf: path)
        let models: [String]
        switch kind {
        case "too-many": models = (0...256).map { "model-\($0)" }
        case "empty-id": models = ["valid", ""]
        case "long-id": models = [String(repeating: "a", count: 257)]
        default: models = [String(repeating: "\u{00E9}", count: 129)]
        }
        #expect(throws: (any Error).self) {
            try saveAutopilotEnrollment(enabled: true, models: models, configPath: path.path)
        }
        #expect(try Data(contentsOf: path) == before)
        let config = try ConfigManager.load(from: path)
        await #expect(throws: (any Error).self) {
            try await Start.completeDaemonReplacement(autopilot: true, models: models, configPath: path.path,
                stop: { Issue.record("invalid selection stopped the existing provider") },
                install: { Issue.record("invalid selection installed a replacement") })
        }
        #expect(!config.backend.modelAutopilot.hasConsent)
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func enrollmentSelectionBoundariesRoundTripWithoutSilentOptOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        try ConfigManager.save(ProviderConfig(provider: ProviderSettings(name: "selection-bounds")), to: path)
        let boundaryID = String(repeating: "\u{00E9}", count: 128)
        let models = (0..<255).map { "model-\($0)" } + [boundaryID]
        try saveAutopilotEnrollment(enabled: true, models: models + [boundaryID], configPath: path.path)
        let config = try ConfigManager.load(from: path)
        #expect(config.backend.modelAutopilot.hasConsent)
        #expect(config.backend.modelAutopilot.selectedModels.count == 256)
        #expect(config.backend.modelAutopilot.selectedModels.contains(boundaryID))
    }
    @Test func emptySelectionDoesNotEnrollOrRewriteConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("provider.toml")
        let config = ProviderConfig(provider:ProviderSettings(name:"enrollment"))
        try ConfigManager.save(config,to:path)
        let before = try Data(contentsOf:path)
        #expect(throws: (any Error).self) { try saveAutopilotEnrollment(enabled:true,models:[],configPath:path.path) }
        #expect(try Data(contentsOf:path) == before)
        try saveAutopilotEnrollment(enabled:true,models:["chosen"],configPath:path.path)
        let enrolled = try ConfigManager.load(from:path)
        #expect(enrolled.backend.modelAutopilot.hasConsent)
        #expect(enrolled.backend.modelAutopilot.allows("chosen"))
        #expect(!enrolled.backend.modelAutopilot.allows("other-downloaded-model"))
        try changeAutopilotPolicy(configPath:path.path) { $0.paused = true }
        let paused = try ConfigManager.load(from:path)
        #expect(paused.backend.modelAutopilot.paused)
        #expect(paused.backend.modelAutopilot.revision != enrolled.backend.modelAutopilot.revision)
    }
}

extension AutopilotCommandTests {
    @Test func enrollmentAcceptsAllButRejectsManualModelOverrides() throws {
        var config = ProviderConfig(provider:ProviderSettings(name:"choice"))
        config.backend.modelAutopilot = .init(enabled:true,consentRecorded:true,selectedModels:["chosen"],revision:"selection")
        var start = try Start.parse(["--all"])
        #expect(try start.resolveAutopilotChoice(config))
        start.model = ["chosen"]
        #expect(throws:(any Error).self) { try start.resolveAutopilotChoice(config) }
        start.autopilot = false
        #expect(try start.resolveAutopilotChoice(config) == false)
        start.all = false; start.autopilot = nil; start.local = true
        #expect(try start.resolveAutopilotChoice(config) == false)
        start.autopilot = true
        #expect(throws:(any Error).self) { try start.resolveAutopilotChoice(config) }
    }

    @Test func inventoryEnrollmentPreservesEveryServingPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "inventory"))
        config.backend.enabledModels = ["preferred"]
        config.backend.model = "preferred"
        config.backend.preloadModels = ["preferred"]
        config.backend.startupPreload = false
        config.backend.idleTimeoutMins = 17
        try ConfigManager.save(config, to: path)
        let before = try ConfigManager.load(from: path)
        try saveAutopilotEnrollment(enabled: true, models: ["other", "preferred"], configPath: path.path)
        var after = try ConfigManager.load(from: path)
        #expect(after.backend.modelAutopilot.selectedModels == ["other", "preferred"])
        after.backend.modelAutopilot = before.backend.modelAutopilot
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(after) == encoder.encode(before))
    }

    @Test func statusFreshnessFollowsConfiguredHeartbeatCadence() {
        let state = DaemonState(pid: 1, version: "test", writtenAt: 1_000, startedAt: 900)
        #expect(Autopilot.Status.snapshotIsFresh(state, heartbeatIntervalSecs: 60, now: 1_030.5))
        #expect(!Autopilot.Status.snapshotIsFresh(state, heartbeatIntervalSecs: 60, now: 1_121))
        #expect(Autopilot.Status.snapshotIsFresh(state, heartbeatIntervalSecs: 200, now: 1_100.5))
        #expect(!Autopilot.Status.snapshotIsFresh(state, heartbeatIntervalSecs: 200, now: 1_401))
        #expect(!Autopilot.Status.snapshotIsFresh(state, heartbeatIntervalSecs: 5, now: 1_011))
    }
}
