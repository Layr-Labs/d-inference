import Foundation
import Testing
@testable import ProviderCore

@Suite("Saved model cache configuration")
struct ModelCacheConfigurationTests {
    @Test("relative cache paths follow the config file, including symlink parents")
    func relativePathUsesConfigDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let actual = root.appendingPathComponent("volume/settings")
        let cache = root.appendingPathComponent("volume/hub")
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("config-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: actual)
        let configPath = link.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "cache-test"))
        config.backend.modelCacheDirectory = "../hub"
        try ConfigManager.save(config, to: configPath)
        let loaded = try ConfigManager.load(from: configPath)
        let resolved = try ConfigManager.modelCacheDirectory(in: loaded, relativeTo: configPath)
        let expectedAttributes = try fm.attributesOfItem(atPath: cache.path)
        let actualAttributes = try fm.attributesOfItem(atPath: try #require(resolved))
        let expectedInode = try #require(expectedAttributes[.systemFileNumber] as? NSNumber)
        let actualInode = try #require(actualAttributes[.systemFileNumber] as? NSNumber)
        #expect(actualInode == expectedInode)
    }

    @Test("invalid explicit saved paths never fall back to another cache", arguments: ["", " \n", "bad\0path"])
    func invalidSavedPathFails(path: String) throws {
        var config = ProviderConfig(provider: ProviderSettings(name: "cache-test"))
        config.backend.modelCacheDirectory = path
        #expect(throws: ConfigError.self) {
            try ConfigManager.modelCacheDirectory(
                in: config, relativeTo: URL(fileURLWithPath: "/tmp/provider.toml"))
        }
    }
}
