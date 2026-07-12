import Foundation
import Testing
@testable import ProviderCore
@testable import darkbloom

@Suite("Beta command")
struct BetaCommandTests {
    @Test("cohort enable and disable persist release channel")
    func cohortPersistence() async throws {
        let path = try temporaryConfig(autoUpdate: false)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        var enable = try Beta.Enable.parse(["--config", path.path])
        try await enable.run()
        var config = try ConfigManager.load(from: path)
        #expect(config.provider.releaseChannel == .beta)
        #expect(config.provider.autoUpdate)

        var disable = try Beta.Disable.parse(["--config", path.path])
        try await disable.run()
        config = try ConfigManager.load(from: path)
        #expect(config.provider.releaseChannel == .stable)
        #expect(config.provider.autoUpdate)
    }

    @Test("feature argument keeps existing beta feature behavior")
    func featureCompatibility() async throws {
        let path = try temporaryConfig(autoUpdate: true)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        var enable = try Beta.Enable.parse(["kv-quant", "--config", path.path])
        try await enable.run()
        let config = try ConfigManager.load(from: path)
        #expect(config.backend.kvQuant)
        #expect(config.provider.releaseChannel == .stable)
    }

    private func temporaryConfig(autoUpdate: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beta-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("provider.toml")
        try ConfigManager.save(
            ProviderConfig(provider: ProviderSettings(
                name: "test-provider",
                autoUpdate: autoUpdate
            )),
            to: path
        )
        return path
    }
}
