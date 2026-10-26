import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
import ProviderCore

@Suite("Autopilot downloads CLI")
struct AutopilotDownloadCommandTests {
    @Test func enablingAndDisablingNeverTouchesConsent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "downloads-cli"))
        config.backend.modelAutopilot = .init(enabled: true, consentRecorded: true, selectedModels: ["a"],
            revision: "consent-revision")
        try ConfigManager.save(config, to: path)

        var enable = try Autopilot.Downloads.Enable.parse(["--max-storage-gb", "200", "--max-models", "3",
            "--config", path.path])
        try await enable.run()
        var saved = try ConfigManager.load(from: path)
        #expect(saved.backend.autopilotDownloads == .init(enabled: true, maxStorageGb: 200, maxModels: 3))
        #expect(saved.backend.modelAutopilot == config.backend.modelAutopilot)

        // Each enable replaces both limits; an omitted flag means no limit.
        enable = try Autopilot.Downloads.Enable.parse(["--max-models", "5", "--config", path.path])
        try await enable.run()
        saved = try ConfigManager.load(from: path)
        #expect(saved.backend.autopilotDownloads == .init(enabled: true, maxModels: 5))

        var disable = try Autopilot.Downloads.Disable.parse(["--config", path.path])
        try await disable.run()
        saved = try ConfigManager.load(from: path)
        #expect(saved.backend.autopilotDownloads == .init(enabled: false, maxModels: 5))
        #expect(saved.backend.modelAutopilot.revision == "consent-revision")
        #expect(throws: ValidationError.self) {
            _ = try Autopilot.Downloads.Enable.enabledSettings(storage: 0, models: nil)
        }
    }

    @Test func theInteractivePromptTreatsBlankAsNoLimit() throws {
        var answers = ["", " 4 "]
        var prompts: [String] = []
        let limits = try Autopilot.Downloads.Enable.promptLimits(
            readInput: { answers.removeFirst() }, emit: { prompts.append($0) })
        #expect(limits.storage == nil)
        #expect(limits.models == 4)
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("blank for no limit") })
        #expect(try Autopilot.Downloads.Enable.parseLimit(nil) == nil)
        for invalid in ["0", "-1", "lots", "1.5"] {
            #expect(throws: ValidationError.self) { _ = try Autopilot.Downloads.Enable.parseLimit(invalid) }
        }
    }
}
