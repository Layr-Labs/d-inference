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

    /// Persist replacement intent and publish its synchronous drain setup under
    /// one lease. A failed setup restores the exact prior file, including absence
    /// of enabled_models; a published drain keeps its selection even if waiting
    /// for completion later fails. The body must not acquire this config lock.
    public static func withReplacement(_ modelIDs: [String], configPath: URL,
                                       body: () throws -> Void) throws {
        try withExclusiveConfigLock(at: configPath) {
            let original: Data?
            do {
                original = try FileManager.default.fileExists(atPath: configPath.path)
                    ? Data(contentsOf: configPath) : nil
            } catch {
                throw ConfigError.readFailed(path: configPath.path, underlying: error)
            }
            var config: ProviderConfig
            if let original {
                guard let content = String(data: original, encoding: .utf8) else {
                    throw ConfigError.parseFailed(detail: "config is not valid UTF-8")
                }
                config = try ConfigManager.parseValidating(content)
            } else {
                config = ConfigManager.loadDefault()
            }
            config.backend.enabledModels = modelIDs
            // A save failure never enters setup or changes recovery state.
            try ConfigManager.save(config, to: configPath)
            do {
                try body()
            } catch {
                let setupError = error
                do {
                    if let original {
                        try original.write(to: configPath, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: configPath)
                    }
                } catch {
                    throw ReplacementRollbackError(configPath: configPath,
                        setupError: setupError, restorationError: error)
                }
                throw setupError
            }
        }
    }

    struct ReplacementRollbackError: Error, CustomStringConvertible {
        let configPath: URL
        let setupError: any Error
        let restorationError: any Error

        var description: String {
            "Replacement setup failed: \(setupError). Restoring previous config at \(configPath.path) also failed: \(restorationError)"
        }
    }
}
