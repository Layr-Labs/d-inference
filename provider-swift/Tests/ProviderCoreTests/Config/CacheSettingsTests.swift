import Foundation
import Testing
@testable import ProviderCore

@Suite("Persistent encrypted-cache settings")
struct CacheSettingsTests {
    @Test func legacyConfigurationKeepsDefaults() throws {
        let config = try ConfigManager.parseValidating("[provider]\nname = \"cache-test\"\n")
        #expect(config.cache == CacheSettings())
        #expect(CacheStorage.dailyWriteBytes(settings: config.cache, environment: [:]) == 750_000_000_000)
    }

    @Test func roundTripPreservesDirectoryPinAndOtherSettings() throws {
        var config = ProviderConfig(provider: ProviderSettings(name: "cache-test"))
        config.backend.idleTimeoutMins = 37
        config.cache = CacheSettings(directory: "/Volumes/Cache SSD/provider", volumeUUID: UUID().uuidString,
                                     dailyWriteGB: 123.5)
        let result = try ConfigManager.parseValidating(ConfigManager.serialize(config))
        #expect(result == config)
        #expect(CacheStorage.dailyWriteBytes(settings: result.cache, environment: [:]) == 123_500_000_000)
    }

    @Test(arguments: ["-1", "nan", "inf", "1e30", "0.00000000001"])
    func invalidLimitRefusesConfiguration(value: String) {
        #expect(throws: (any Error).self) {
            try ConfigManager.parseValidating("[cache]\ndaily_write_gb = \(value)\n")
        }
    }

    @Test(arguments: ["directory = \"/Volumes/Disk/cache\"", "volume_uuid = \"broken\"",
                      "directory = \"relative\"\nvolume_uuid = \"00000000-0000-0000-0000-000000000001\"",
                      "directory = \"/Volumes/Disk/../cache\"\nvolume_uuid = \"00000000-0000-0000-0000-000000000001\""])
    func invalidOrUnpinnedPathRefusesConfiguration(value: String) {
        #expect(throws: (any Error).self) { try ConfigManager.parseValidating("[cache]\n\(value)\n") }
    }

    @Test func savedAllowanceWinsOverStaleDaemonEnvironment() {
        let environment = ["DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "0"]
        #expect(CacheStorage.dailyWriteBytes(settings: CacheSettings(dailyWriteGB: 10),
                                            environment: environment) == 10_000_000_000)
        #expect(CacheStorage.dailyWriteBytes(settings: CacheSettings(), environment: environment) == 0)
        #expect(CacheStorage.dailyWriteBytes(settings: CacheSettings(dailyWriteGB: 0),
                                            environment: [:]) == 0)
    }
}
