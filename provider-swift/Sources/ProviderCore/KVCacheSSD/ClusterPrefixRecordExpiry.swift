// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation

/// Deletes a pair's prompt-prefix records past the TTL under every plan
/// folder that no running rank holds (its `in-use` lock), each
/// `intervalSeconds` while the provider runs, as `SSDWholeRootMaintainer`
/// does for `kv3`, so a pair that is not loaded leaves no expired record.
/// A running rank deletes its own (`QwenStagePrefixDiskTier`,
/// `expirySweepSeconds`). A record's mtime is its last use under the sliding
/// TTL and its write under the fixed one. Only the tier's own names are
/// touched (`ClusterPrefixSSDInspection`): `v1-<24 hex>/rank<n>/<32 hex>.dbpx`,
/// regular files of this user in real directories.
final class ClusterPrefixRecordExpiry: @unchecked Sendable {
    typealias Target = (root: URL, ttlSeconds: Int)

    static let shared = ClusterPrefixRecordExpiry()

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// Sweeps the pair's root (`target`) until `stop`. An isolated test root
    /// starts nothing.
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment, intervalSeconds: Int = 60) {
        guard SSDPrefixCacheFactory.isolatedTestRoot(environment: environment) == nil else { return }
        shared.start(intervalSeconds: intervalSeconds) { target(environment: environment) }
    }

    static func stop() { shared.stop() }

    /// The root and TTL the pair's ranks on this Mac get, resolved as their
    /// owner does (`ClusterPrefixCacheSettings.installProduct`): the saved
    /// provider configuration, a member's with its leader's synced choices,
    /// read again at each pass. The TTL is never longer than this Mac's own.
    /// nil while a pinned cache volume is missing or not the saved one.
    static func target(
        environment: [String: String],
        providerConfiguration: URL? = try? ConfigManager.defaultConfigPath(),
        leaderChoices: (ClusterPrefixCacheSettings) -> ClusterPrefixCacheSettings = {
            ClusterPrefixCacheSettings.withLeaderChoices($0)
        }
    ) -> Target? {
        let saved = providerConfiguration.flatMap {
            try? ClusterPrefixCacheSettings.savedCacheSettings(providerConfiguration: $0)
        } ?? CacheSettings()
        if let directory = saved.directory {
            guard let observed = try? CacheVolume.inspect(directory: directory),
                  observed.uuid == saved.volumeUUID?.lowercased() else { return nil }
        }
        let settings = leaderChoices(.product(cacheSettings: saved, environment: environment, freeBytes: { _ in nil }))
        let own = Int(SSDPrefixCachePolicy.ttlSeconds(environment: environment))
        return (settings.root, min(own, settings.ttlSeconds ?? own))
    }

    func start(intervalSeconds: Int, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
               target: @escaping @Sendable () -> Target?) {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    if let target = target() { Self.sweep(root: target.root, ttlSeconds: target.ttlSeconds, now: now()) }
                    try? await taskSleep(.seconds(max(1, intervalSeconds)))
                }
            }
        }
    }

    func stop() {
        lock.withLock { task?.cancel(); task = nil }
    }

    /// One pass; returns how many records it deleted.
    @discardableResult
    static func sweep(root: URL, ttlSeconds: Int, now: TimeInterval) -> Int {
        guard isOwnDirectory(root) else { return 0 }
        var removed = 0
        for plan in names(in: root) where ClusterPrefixSSDInspection.isPlanDirectoryName(plan) && false {
            let directory = root.appendingPathComponent(plan, isDirectory: true)
            guard isOwnDirectory(directory) else { continue }
            removed += sweepPlan(directory, ttlSeconds: ttlSeconds, now: now)
        }
        return removed
    }

    private static func sweepPlan(_ plan: URL, ttlSeconds: Int, now: TimeInterval) -> Int {
        // A running rank holds the lock shared for its life; this pass skips its
        // plan, and one whose lock it cannot open for another reason.
        let inUse = Darwin.open(plan.appendingPathComponent("in-use").path, O_RDONLY | O_NOFOLLOW)
        if inUse < 0, errno != ENOENT { return 0 }
        defer { if inUse >= 0 { Darwin.close(inUse) } }
        if inUse >= 0, flock(inUse, LOCK_EX | LOCK_NB) != 0 { return 0 }
        var removed = 0
        for rank in names(in: plan) where rank.hasPrefix("rank") && Int(rank.dropFirst(4)) != nil {
            let directory = plan.appendingPathComponent(rank, isDirectory: true)
            guard isOwnDirectory(directory) else { continue }
            for file in names(in: directory) where ClusterPrefixSSDInspection.isRecordName(file) {
                let path = directory.appendingPathComponent(file).path
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
                let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
                if now - modified > Double(ttlSeconds), unlink(path) == 0 { removed += 1 }
            }
        }
        return removed
    }

    private static func isOwnDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
