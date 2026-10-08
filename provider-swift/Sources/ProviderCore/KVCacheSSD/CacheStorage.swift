import Darwin
import Foundation

/// An invocation's immutable operator settings. Installed before model loading;
/// factories, maintenance and descriptor I/O all consult the same snapshot.
public enum CacheStorage {
    static let rootDirectoryName = "darkbloom/kv3"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var settings = CacheSettings()
    }
    private static let state = State()

    public static func configure(_ settings: CacheSettings) throws {
        try settings.validate()
        state.lock.withLock { state.settings = settings }
    }

    static var settings: CacheSettings { state.lock.withLock { state.settings } }

    public static var defaultRoot: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    public static func root(for settings: CacheSettings) -> URL {
        guard let directory = settings.directory else { return defaultRoot }
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    public static func dailyWriteBytes(
        settings: CacheSettings, environment: [String: String]
    ) -> Int {
        // An explicit saved choice wins over a stale launchd environment.
        if let gb = settings.dailyWriteGB { return Int(gb * 1_000_000_000) }
        return SSDPrefixCachePolicy.environmentMaxWriteBytesPerDay(environment: environment)
    }

    static func validateSelection() throws {
        let value = settings
        guard let directory = value.directory else { return }
        let observed = try CacheVolume.inspect(directory: directory)
        guard observed.uuid == value.volumeUUID?.lowercased() else {
            throw CacheStorageError("Selected cache volume is missing or has changed; caching is disabled until the pinned volume returns.")
        }
    }

    /// Called after each descriptor open, and BEFORE mkdirat on a configured
    /// volume. Unplug/replacement cannot create fallback directories on the host.
    static func validateOpenedDirectory(
        _ fd: Int32, at directory: URL, configuration: CacheSettings? = nil
    ) throws {
        let value = configuration ?? settings
        guard let rawBase = value.directory else { return }
        let base = normalizedPath(rawBase)
        let path = normalizedPath(directory.path)
        guard path == base || path.hasPrefix(base + "/") else { return }
        guard try CacheVolume.validateDescriptor(fd) == value.volumeUUID?.lowercased() else {
            throw CacheStorageError("Cache volume identity changed; refusing disk I/O.")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw CacheStorageError("Cache directory ownership or permissions changed; refusing disk I/O.")
        }
    }

    static func validateCreation(at directory: URL, configuration: CacheSettings? = nil) throws {
        // Never recreate the selected directory itself. It is operator-owned
        // and must already exist on the mounted, pinned volume.
        let path = normalizedPath(directory.path)
        if let base = (configuration ?? settings).directory.map(normalizedPath),
           path == base || base.hasPrefix(path + "/") {
            throw CacheStorageError("Selected cache directory is missing. Mount the pinned volume before caching.")
        }
    }

    static func canonicalPath(_ path: String) -> String {
        // Normalize only known system aliases textually. Resolving symlinks
        // before the descriptor walk would bypass its O_NOFOLLOW checks.
        if path == "/tmp" || path.hasPrefix("/tmp/")
            || path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private static func normalizedPath(_ path: String) -> String {
        // Foundation's standardization can resolve existing symlinks and
        // rewrite /private/var back to /var. Compare lexical paths only, using
        // the same known system aliases as the no-follow descriptor walk.
        "/" + canonicalPath(path).split(separator: "/").joined(separator: "/")
    }

    static func makeWriteBudget(
        maxWriteBytesPerDay: Int, payloadRoot: URL, isolated: Bool
    ) throws -> SSDWriteBudget? {
        guard maxWriteBytesPerDay > 0 else { return nil }
        let root = try writeBudgetRoot(payloadRoot: payloadRoot, isolated: isolated)
        return try SSDWriteBudget(root: root)
    }

    static func writeBudgetRoot(
        payloadRoot: URL, isolated: Bool, defaultRoot: URL = CacheStorage.defaultRoot
    ) throws -> URL {
        // Keep endurance history off removable/untrusted media. Switching the
        // payload disk must not replenish the rolling-day allowance. Default
        // installations retain the existing ledger, including prior usage.
        let root = isolated ? payloadRoot : defaultRoot
        try SSDNoFollowIO.prepareDirectory(root)
        return root
    }
}
