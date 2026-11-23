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
/// touched: `v1-<24 hex>/rank<r>/<name>.dbpx`, regular files of this user.
final class ClusterPrefixRecordExpiry: @unchecked Sendable {
    static let shared = ClusterPrefixRecordExpiry()

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// The pair's root from the saved cache settings, swept until `stop`.
    /// An isolated test root, or a cache selection that does not validate,
    /// starts nothing, as for `kv3`.
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment, intervalSeconds: Int = 60) {
        guard SSDPrefixCacheFactory.isolatedTestRoot(environment: environment) == nil,
              (try? CacheStorage.validateSelection()) != nil else { return }
        let root = ClusterPrefixCacheSettings.product(cacheSettings: CacheStorage.settings, environment: environment,
                                                      freeBytes: { _ in nil }).root
        shared.start(root: root, ttlSeconds: Int(SSDPrefixCachePolicy.ttlSeconds(environment: environment)),
                     intervalSeconds: intervalSeconds)
    }

    func start(root: URL, ttlSeconds: Int, intervalSeconds: Int,
               now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    Self.sweep(root: root, ttlSeconds: ttlSeconds, now: now())
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
        var removed = 0
        for plan in names(in: root) where isPlanDirectoryName(plan) {
            removed += sweepPlan(root.appendingPathComponent(plan, isDirectory: true), ttlSeconds: ttlSeconds, now: now)
        }
        return removed
    }

    private static func sweepPlan(_ plan: URL, ttlSeconds: Int, now: TimeInterval) -> Int {
        // A running rank holds the lock shared for its life; this pass skips its plan.
        let inUse = Darwin.open(plan.appendingPathComponent("in-use").path, O_RDONLY | O_NOFOLLOW)
        defer { if inUse >= 0 { Darwin.close(inUse) } }
        if inUse >= 0, flock(inUse, LOCK_EX | LOCK_NB) != 0 { return 0 }
        var removed = 0
        for rank in names(in: plan) where rank.hasPrefix("rank") {
            let directory = plan.appendingPathComponent(rank, isDirectory: true)
            for file in names(in: directory) where file.hasSuffix(".dbpx") && !file.hasPrefix(".") {
                let path = directory.appendingPathComponent(file).path
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
                let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
                if now - modified > Double(ttlSeconds), unlink(path) == 0 { removed += 1 }
            }
        }
        return removed
    }

    /// `QwenStagePrefixDiskTier.isPlanDirectoryName`: `v1-` and 24 lowercase hex digits.
    static func isPlanDirectoryName(_ name: String) -> Bool {
        name.count == 27 && name.hasPrefix("v1-") && name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
