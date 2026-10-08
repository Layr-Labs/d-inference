import ArgumentParser
import Foundation
import Testing
import ProviderCore
@testable import darkbloom

@Suite("Cache configuration commands")
struct CacheCommandTests {
    @Test func cacheHelpListsConfigurationCommands() {
        let help = Cache.helpMessage()
        #expect(help.contains("set"))
        #expect(help.contains("status"))
    }

    private func fixture() throws -> (root: URL, config: URL, disk: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cache-cli-\(UUID().uuidString)")
        let disk = root.appendingPathComponent("selected disk")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("provider settings.toml")
        var value = ProviderConfig(provider: ProviderSettings(name: "cache-fixture"))
        value.backend.idleTimeoutMins = 42
        try ConfigManager.save(value, to: config)
        return (root, config, disk)
    }

    @Test func combinedSetPersistsLimitAndPinWithoutMovingFiles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sentinel = f.disk.appendingPathComponent("sentinel")
        try Data("keep existing data".utf8).write(to: sentinel)
        let command = try #require(try Darkbloom.parseAsRoot([
            "cache", "set", "--config", f.config.path, "--daily-write-gb", "25.5",
            "--directory", f.disk.path]) as? Cache.Set)
        try command.validate()
        try command.run()
        let config = try ConfigManager.load(from: f.config)
        let selected = try CacheVolume.inspect(directory: f.disk.path)
        #expect(config.cache.dailyWriteGB == 25.5)
        #expect(config.cache.directory == selected.directory)
        #expect(config.cache.volumeUUID == selected.uuid)
        #expect(config.backend.idleTimeoutMins == 42)
        #expect(try Data(contentsOf: sentinel) == Data("keep existing data".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.disk.path) == ["sentinel"])
        #expect(inspectCacheSettings(config.cache).problem == nil)
    }

    @Test func separateEditsPreserveOtherCacheChoicesAndResetOnlyDirectory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try updateCacheSettings(dailyWriteGB: 10, directory: f.disk.path,
                                    resetDirectory: false, configPath: f.config.path)
        _ = try updateCacheSettings(dailyWriteGB: 0, directory: nil,
                                    resetDirectory: false, configPath: f.config.path)
        #expect(try ConfigManager.load(from: f.config).cache.directory
            == CacheVolume.inspect(directory: f.disk.path).directory)
        let result = try updateCacheSettings(dailyWriteGB: nil, directory: nil,
                                             resetDirectory: true, configPath: f.config.path)
        #expect(result.settings.directory == nil)
        #expect(result.settings.volumeUUID == nil)
        #expect(result.settings.dailyWriteGB == 0)
    }

    @Test func unavailableDiskFailsBeforeSavingAndStatusDoesNotCreateIt() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.config)
        let missing = f.root.appendingPathComponent("unmounted/cache")
        #expect(throws: (any Error).self) {
            try updateCacheSettings(dailyWriteGB: 12, directory: missing.path,
                                    resetDirectory: false, configPath: f.config.path)
        }
        #expect(try Data(contentsOf: f.config) == before)
        let status = inspectCacheSettings(CacheSettings(directory: missing.path, volumeUUID: UUID().uuidString))
        #expect(status.problem?.contains("Cannot open cache directory") == true)
        #expect(status.problem?.contains("openat directory") == true)
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    @Test func changedVolumePinIsVisibleInStatus() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let status = inspectCacheSettings(CacheSettings(directory: f.disk.path, volumeUUID: UUID().uuidString))
        #expect(status.problem?.contains("UUID") == true)
    }

    @Test(arguments: [[], ["--daily-write-gb", "-1"], ["--daily-write-gb", "nan"],
                      ["--daily-write-gb", "1e30"], ["--directory", "/tmp", "--reset-directory"]])
    func invalidCommandRefuses(arguments: [String]) {
        #expect(throws: (any Error).self) {
            let command = try #require(try Darkbloom.parseAsRoot(["cache", "set"] + arguments) as? Cache.Set)
            try command.validate()
        }
    }
}
