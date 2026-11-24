// Copyright © 2026 Eigen Labs.

import Darwin
import DarkbloomClusterProtocol
import Foundation

/// Best-effort cleanup of an accessible pair cache. Ranks enforce expiry at
/// reuse; this pass can delete only from an idle plan whose lease it acquired.
final class ClusterPrefixRecordExpiry: @unchecked Sendable {
    struct Target: Sendable {
        let root: URL
        let ttlSeconds: Int
        var selection = CacheSettings()
    }

    static let shared = ClusterPrefixRecordExpiry()
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    static func start(environment: [String: String] = ProcessInfo.processInfo.environment, intervalSeconds: Int = 60) {
        guard SSDPrefixCacheFactory.isolatedTestRoot(environment: environment) == nil else { return }
        shared.start(intervalSeconds: intervalSeconds) { target(environment: environment) }
    }

    static func stop() { shared.stop() }

    /// Read only the saved cache selection. A missing file means defaults;
    /// a present but unreadable configuration is not permission to switch roots.
    static func target(environment: [String: String], providerConfiguration: URL? = try? ConfigManager.defaultConfigPath()) -> Target? {
        guard let providerConfiguration,
              let saved = try? ClusterPrefixCacheSettings.savedCacheSettings(providerConfiguration: providerConfiguration)
        else { return nil }
        let settings = ClusterPrefixCacheSettings.product(cacheSettings: saved, environment: environment, freeBytes: { _ in nil })
        return Target(root: settings.root, ttlSeconds: Int(SSDPrefixCachePolicy.ttlSeconds(environment: environment)), selection: saved)
    }

    func start(intervalSeconds: Int, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
               target: @escaping @Sendable () -> Target?) {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    if let target = target(), !Task.isCancelled { _ = Self.sweep(target, now: now()) }
                    try? await taskSleep(.seconds(max(1, intervalSeconds)))
                }
            }
        }
    }

    func stop() { lock.withLock { task?.cancel(); task = nil } }

    /// Validate the selected base on the opened descriptor, then descend from
    /// that descriptor. No subsequent name resolution starts at the mount path.
    static func openRoot(_ target: Target) -> Int32? {
        guard let pin = target.selection.directory else {
            return try? SSDNoFollowIO.openDirectoryChain(target.root, enforceCacheVolume: false)
        }
        let baseURL = URL(fileURLWithPath: pin, isDirectory: true)
        guard ClusterPrefixCacheSettings.root(cacheBase: baseURL).standardizedFileURL == target.root.standardizedFileURL,
              let base = try? SSDNoFollowIO.openDirectoryChain(baseURL, enforceCacheVolume: false) else { return nil }
        defer { Darwin.close(base) }
        var s = stat()
        guard (try? CacheStorage.validateOpenedDirectory(base, at: baseURL, configuration: target.selection)) != nil,
              fstat(base, &s) == 0,
              let ns = ClusterPrefixRecordDirectory.openChild(base, target.root.deletingLastPathComponent().lastPathComponent,
                                                              device: s.st_dev) else { return nil }
        defer { Darwin.close(ns) }
        return ClusterPrefixRecordDirectory.openChild(ns, target.root.lastPathComponent, device: s.st_dev)
    }

    static func sweep(_ target: Target, now: TimeInterval) -> Int {
        guard let fd = openRoot(target) else { return 0 }
        defer { Darwin.close(fd) }
        return sweep(openRoot: fd, localTTL: target.ttlSeconds, now: now)
    }

    /// Directory-relative inspection and unlink stay on the selected device.
    /// The rank's published TTL is already resolved at load, including a
    /// leader's settings. Maintenance never reads pairing state or credentials.
    static func sweep(openRoot root: Int32, localTTL: Int, now: TimeInterval) -> Int {
        var info = stat(), removed = 0
        guard fstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return 0 }
        let device = info.st_dev
        ClusterPrefixRecordDirectory.forEachName(in: root) { name in
            guard !Task.isCancelled else { return }
            _ = ClusterPrefixRecordDirectory.withIdlePlan(root: root, name: name, device: device,
                                                          repairingMissingLease: true) { plan in
                ClusterPrefixRecordDirectory.forEachName(in: plan) { rank in
                    guard !Task.isCancelled, ClusterPrefixRecordDirectory.rank(rank) != nil,
                          let fd = ClusterPrefixRecordDirectory.openChild(plan, rank, device: device) else { return }
                    defer { Darwin.close(fd) }
                    guard let ttl = ClusterPrefixRecordDirectory.cleanupTTL(rankFD: fd, local: localTTL) else { return }
                    ClusterPrefixRecordDirectory.forEachName(in: fd) { file in
                        var s = stat()
                        guard !Task.isCancelled, ClusterPrefixRecordDirectory.isRecord(file),
                              fstatat(fd, file, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_mode & S_IFMT == S_IFREG,
                              s.st_uid == getuid(), s.st_dev == device else { return }
                        let modified = Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9
                        if now - modified > Double(ttl), unlinkat(fd, file, 0) == 0 { removed += 1 }
                    }
                }
            }
        }
        return removed
    }
}
