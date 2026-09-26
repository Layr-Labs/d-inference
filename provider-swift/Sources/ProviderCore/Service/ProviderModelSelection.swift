import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Serializes config writers on a stable sidecar: ConfigManager.save replaces
/// the TOML inode atomically, so locking the config itself would not serialize.
@discardableResult
public func withExclusiveConfigLock<T>(at configPath: URL, _ body: () throws -> T) throws -> T {
    let directory = configPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent(configPath.lastPathComponent + ".lock")
    let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
    guard fd >= 0 else {
        throw ConfigError.writeFailed(path: lockURL.path,
                                      underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
        throw ConfigError.writeFailed(path: lockURL.path,
                                      underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
    }
    defer { _ = flock(fd, LOCK_UN) }
    return try body()
}

public enum ProviderModelSelection {
    /// Reload inside the shared lock so unrelated operator changes survive.
    public static func save(_ modelIDs: [String], configPath: URL) throws {
        try withExclusiveConfigLock(at: configPath) {
            var config = try FileManager.default.fileExists(atPath: configPath.path)
                ? ConfigManager.load(from: configPath) : ConfigManager.loadDefault()
            config.backend.enabledModels = modelIDs
            try ConfigManager.save(config, to: configPath)
        }
    }
}
