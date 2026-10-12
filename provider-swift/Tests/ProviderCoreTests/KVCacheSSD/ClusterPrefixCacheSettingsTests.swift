import Foundation
import Testing
@testable import ProviderCore

/// The pair's cache settings resolve from the product's own surface: the
/// saved cache directory, the prefix-cache gate, the box-wide disk budget
/// rule, the daily write cap and the TTL, exactly as the single-Mac SSD tier
/// reads them. No keychain, no disk beyond a temporary directory.
@Suite("Cluster prefix cache settings follow the product's")
struct ClusterPrefixCacheSettingsTests {
    @Test func rootIsBesideTheProductTierUnderTheSameBase() {
        let home = URL(fileURLWithPath: "/tmp/home-\(UUID().uuidString)", isDirectory: true)
        let pinned = CacheSettings(directory: "/Volumes/Fast/darkbloom-cache", volumeUUID: UUID().uuidString, dailyWriteGB: nil)
        let resolved = ClusterPrefixCacheSettings.product(cacheSettings: pinned, environment: [:], freeBytes: { _ in 100 * 1_073_741_824 })
        #expect(resolved.root.path == "/Volumes/Fast/darkbloom-cache/darkbloom/cluster-prefix-v1")
        #expect(CacheStorage.root(for: pinned).path == "/Volumes/Fast/darkbloom-cache/darkbloom/kv3")
        let builtIn = ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: [:], freeBytes: { _ in nil })
        #expect(builtIn.root.path == CacheStorage.defaultRoot.deletingLastPathComponent().appendingPathComponent("cluster-prefix-v1").path)
        #expect(ClusterPrefixCacheSettings.defaultRoot(home: home).path == home.path + "/Library/Caches/darkbloom/cluster-prefix-v1")
    }

    @Test func gateBudgetCapAndTTLAreTheProductsRules() {
        let settings = CacheSettings(dailyWriteGB: 120)
        let plain = ClusterPrefixCacheSettings.product(cacheSettings: settings, environment: [:], freeBytes: { _ in 64 * 1_073_741_824 })
        #expect(plain.prefixCacheEnabled)
        // Half the free space, as `PrefixCachePolicy.ssdDiskBudgetBytes`.
        #expect(plain.byteBudget == 32 * 1_073_741_824)
        // The saved daily cap wins over the environment; the TTL is the ceiling.
        #expect(plain.dailyWriteBytes == 120_000_000_000)
        #expect(plain.ttlSeconds == 1_800)
        let tuned = ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: [
            "DARKBLOOM_PREFIX_CACHE_DISK_GB": "12", "DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "0",
            "DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "600"], freeBytes: { _ in 64 * 1_073_741_824 })
        #expect(tuned.byteBudget == 12 * 1_073_741_824 && tuned.dailyWriteBytes == 0 && tuned.ttlSeconds == 600)
        #expect(tuned.rankSwitches == ["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB": "12", "DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_WRITE_GB_PER_DAY": "0",
                                       "DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS": "600"])
        // Unknown free space: the product's conservative fallback.
        let unknown = ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: [:], freeBytes: { _ in nil })
        #expect(unknown.byteBudget == PrefixCachePolicy.fallbackSSDDiskBudgetBytes)
        // The product's gate off (a non-affirmative value) turns the pair's cache off.
        let off = ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: ["DARKBLOOM_PREFIX_CACHE": "off"],
            freeBytes: { _ in nil })
        #expect(!off.prefixCacheEnabled)
        let on = ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: ["DARKBLOOM_PREFIX_CACHE": "1"],
            freeBytes: { _ in nil })
        #expect(on.prefixCacheEnabled)
    }

    @Test func savedSettingsAreReadFromTheProviderConfigurationOrDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-cache-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("absent.json")
        #expect(try ClusterPrefixCacheSettings.savedCacheSettings(providerConfiguration: missing) == CacheSettings())
        let file = directory.appendingPathComponent("config.json")
        try Data(#"{"cache":{"daily_write_gb":42}}"#.utf8).write(to: file)
        chmod(file.path, 0o600)
        #expect(try ClusterPrefixCacheSettings.savedCacheSettings(providerConfiguration: file).dailyWriteGB == 42)
    }

    @Test func leaderSyncCarriesTheLeadersChoicesNotItsRoot() throws {
        let leader = ClusterPrefixCacheSettings(root: URL(fileURLWithPath: "/leader"), prefixCacheEnabled: false,
            byteBudget: 3 * 1_073_741_824, dailyWriteBytes: 7_000_000_000, ttlSeconds: 300)
        let member = ClusterPrefixCacheSettings(root: URL(fileURLWithPath: "/member"))
        let applied = try ClusterCacheSettingsSync.decode(try ClusterCacheSettingsSync(leader: leader).encoded()).applied(to: member)
        #expect(applied == ClusterPrefixCacheSettings(root: URL(fileURLWithPath: "/member"), prefixCacheEnabled: false,
            byteBudget: 3 * 1_073_741_824, dailyWriteBytes: 7_000_000_000, ttlSeconds: 300))
        let text = String(decoding: try ClusterCacheSettingsSync(leader: leader).encoded(), as: UTF8.self)
        #expect(text == #"{"daily_write_gb":7,"disk_budget_gb":3,"prefix_cache_enabled":false,"ttl_seconds":300,"version":1}"#)
    }
}
