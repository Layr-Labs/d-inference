import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite("Autoupdate config mutation")
struct AutoUpdateCommandTests {
    @Test(arguments: [true, false])
    func togglePreservesASelectionSavedAfterAnEarlierConfigRead(enabled: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("provider.toml")
        var initial = ProviderConfig(provider: ProviderSettings(name: "provider"))
        initial.provider.autoUpdate = !enabled
        initial.backend.enabledModels = ["old-model"]
        try ConfigManager.save(initial, to: path)

        // The CLI used to save this whole earlier snapshot after the switch.
        let earlier = try ConfigManager.load(from: path)
        try ProviderModelSelection.save(["new-model"], configPath: path, fallbackConfig: initial)
        try setAutoUpdate(enabled, configPath: path.path)

        let saved = try ConfigManager.load(from: path)
        #expect(earlier.backend.enabledModels == ["old-model"])
        #expect(saved.provider.autoUpdate == enabled)
        #expect(saved.backend.enabledModels == ["new-model"])
    }
}
