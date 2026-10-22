// Copyright © 2026 Eigen Labs.

import Foundation

/// The pair's cache settings from the product's own: the SAME saved
/// `CacheSettings` (`darkbloom cache set`), gate (`DARKBLOOM_PREFIX_CACHE`),
/// box-wide disk budget rule (`PrefixCachePolicy.ssdDiskBudgetBytes`), daily
/// write cap (`CacheStorage.dailyWriteBytes`) and TTL (`SSDPrefixCachePolicy`)
/// the single-Mac SSD tier reads. Nothing here is cluster-specific but the
/// root's last component.
extension ClusterPrefixCacheSettings {
    /// Resolve from saved settings and the process environment. `freeBytes`
    /// is measured at the root (nil when it cannot be: the product's
    /// conservative fallback budget then applies, as on one Mac).
    public static func product(cacheSettings: CacheSettings, environment: [String: String] = ProcessInfo.processInfo.environment,
                               freeBytes: ((URL) -> Int?)? = nil) -> ClusterPrefixCacheSettings {
        // `<base>/darkbloom/kv3` is the single-Mac tier; the pair's root is `<base>/darkbloom/cluster-prefix-v1`.
        let base = CacheStorage.root(for: cacheSettings).deletingLastPathComponent().deletingLastPathComponent()
        let root = Self.root(cacheBase: base)
        let free = (freeBytes ?? PrefixCachePolicy.volumeFreeBytes(at:))(root)
        return .init(root: root,
                     prefixCacheEnabled: PrefixCachePolicy.isGloballyEnabled(environment: environment),
                     byteBudget: PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment, freeBytes: free),
                     dailyWriteBytes: CacheStorage.dailyWriteBytes(settings: cacheSettings, environment: environment),
                     ttlSeconds: Int(SSDPrefixCachePolicy.ttlSeconds(environment: environment)))
    }

    /// The saved cache settings of the provider configuration at `url`
    /// (bounded, private-mode read; the defaults when there is no file).
    public static func savedCacheSettings(providerConfiguration url: URL) throws -> CacheSettings {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return CacheSettings() }
        let bytes = try ClusterConfigurationFiles.read(url, maximum: 1_048_576, privateMode: true)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ClusterConfigurationError.invalid("Provider configuration is not UTF-8")
        }
        return try ConfigManager.parseValidating(text).cache
    }

    /// Resolve the product's settings for this Mac and install them for the
    /// installed owner (`DistributedInstalledPrefixSSD`). A configuration
    /// that cannot be read leaves the built-in root (the pair still caches;
    /// the setup commands report the configuration problem themselves).
    public static func installProduct(providerConfiguration: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let settings = (try? savedCacheSettings(providerConfiguration: providerConfiguration)) ?? CacheSettings()
        DistributedInstalledPrefixSSD.installProductSettings(
            withLeaderChoices(product(cacheSettings: settings, environment: environment)))
    }

    /// On a member: its own settings with the cache settings its leader
    /// synced over the link applied (`ClusterMemberCacheControl`); on a
    /// leader, a single Mac, or with nothing synced, its own unchanged.
    public static func withLeaderChoices(_ own: ClusterPrefixCacheSettings,
                                         paths: ClusterUserPaths? = try? ClusterUserPaths()) -> ClusterPrefixCacheSettings {
        guard let paths else { return own }
        let setup = ClusterSetupPaths(paths: paths)
        let followed = ClusterService.followedLeaderPin(record: try? ClusterSetupStore(paths: setup).readRecord())
        return ClusterMemberCacheControl.effective(own: own, store: .init(directory: setup.directory), followedLeaderPin: followed)
    }

    /// The resolved settings for status and reclaim (no installation).
    public static func resolved(providerConfiguration: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClusterPrefixCacheSettings {
        product(cacheSettings: try savedCacheSettings(providerConfiguration: providerConfiguration), environment: environment)
    }
}

extension ClusterCacheSettingsSync {
    /// What a leader syncs to its members: its CHOICES only, never a value
    /// derived from its own disk. The prefix cache gate, the daily write cap
    /// (saved or switch), the TTL, and a disk budget only when one is set
    /// explicitly (`DARKBLOOM_PREFIX_CACHE_DISK_GB`): otherwise each member
    /// keeps the product's rule on its own disk (half its free space).
    public static func leaderChoices(cacheSettings: CacheSettings,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> ClusterCacheSettingsSync {
        let budget = environment[PrefixCachePolicy.diskBudgetEnvironmentFlag].flatMap(Double.init)
            .flatMap { $0 > 0 && $0.isFinite && $0 <= 16_384 ? $0 : nil }
        return .init(prefixCacheEnabled: PrefixCachePolicy.isGloballyEnabled(environment: environment),
                     dailyWriteGB: Double(CacheStorage.dailyWriteBytes(settings: cacheSettings, environment: environment)) / 1_000_000_000,
                     diskBudgetGB: budget,
                     ttlSeconds: Int(SSDPrefixCachePolicy.ttlSeconds(environment: environment)))
    }
}
