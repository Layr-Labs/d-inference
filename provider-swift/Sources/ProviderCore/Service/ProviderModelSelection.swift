import Foundation
import TOMLKit
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
    /// A staged selection holds bytes, not a lock: coordinator waits must not
    /// block other config writers. Nil originalModelIDs means the key was absent.
    public struct Replacement: Sendable {
        fileprivate let configPath: URL
        fileprivate let original: Data?
        fileprivate let written: Data
        fileprivate let originalModelIDs: [String]?
        fileprivate let modelIDs: [String]
    }

    public static func save(_ modelIDs: [String], configPath: URL, fallbackConfig: ProviderConfig) throws {
        _ = try stageReplacement(modelIDs, configPath: configPath, fallbackConfig: fallbackConfig)
    }

    /// The fallback must be the caller's resolved configuration for this path,
    /// never a separately loaded canonical config.
    public static func stageReplacement(_ modelIDs: [String], configPath: URL,
                                        fallbackConfig: ProviderConfig) throws -> Replacement {
        try withExclusiveConfigLock(at: configPath) {
            try stageLocked(modelIDs, configPath: configPath, fallbackConfig: fallbackConfig)
        }
    }

    public static func restore(_ replacement: Replacement) throws {
        try withExclusiveConfigLock(at: replacement.configPath) {
            try restoreLocked(replacement)
        }
    }

    /// Persist replacement intent and publish its synchronous drain setup under
    /// one lease. A failed setup restores the exact prior file, including absence
    /// of enabled_models; a published drain keeps its selection even if waiting
    /// for completion later fails. The body must not acquire this config lock.
    public static func withReplacement(_ modelIDs: [String], configPath: URL,
                                       fallbackConfig: ProviderConfig, body: () throws -> Void) throws {
        try withExclusiveConfigLock(at: configPath) {
            let replacement = try stageLocked(modelIDs, configPath: configPath, fallbackConfig: fallbackConfig)
            do {
                try body()
            } catch {
                let setupError = error
                do {
                    try restoreLocked(replacement)
                } catch {
                    throw ReplacementRollbackError(configPath: configPath,
                        setupError: setupError, restorationError: error)
                }
                throw setupError
            }
        }
    }

    private static func stageLocked(_ modelIDs: [String], configPath: URL,
                                    fallbackConfig: ProviderConfig) throws -> Replacement {
        let original = try contents(at: configPath)
        let table: TOMLTable
        let originalModelIDs: [String]?
        if let original {
            let parsed = try parse(original)
            table = parsed.table
            originalModelIDs = table["backend"]?.table?["enabled_models"] == nil
                ? nil : parsed.config.backend.enabledModels
        } else {
            table = try TOMLEncoder().encode(fallbackConfig)
            originalModelIDs = nil
        }
        if table["backend"] == nil { table["backend"] = TOMLTable() }
        table["backend"]?.table?["enabled_models"] = TOMLArray(modelIDs)
        let written = Data(table.convert().utf8)
        do {
            try written.write(to: configPath, options: .atomic)
        } catch {
            throw ConfigError.writeFailed(path: configPath.path, underlying: error)
        }
        return Replacement(configPath: configPath, original: original, written: written,
            originalModelIDs: originalModelIDs, modelIDs: modelIDs)
    }

    private static func restoreLocked(_ replacement: Replacement) throws {
        let path = replacement.configPath
        let current = try contents(at: path)
        if current == replacement.written {
            if let original = replacement.original {
                try original.write(to: path, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: path)
            }
            return
        }
        guard let current else { throw SelectionConflict(configPath: path) }
        let parsed = try parse(current)
        guard let backend = parsed.table["backend"]?.table,
              backend["enabled_models"] != nil,
              parsed.config.backend.enabledModels == replacement.modelIDs else {
            throw SelectionConflict(configPath: path)
        }
        // Another writer changed unrelated settings during the network wait.
        // Restore only our key through TOML's table API, including key absence.
        if let originalModelIDs = replacement.originalModelIDs {
            backend["enabled_models"] = TOMLArray(originalModelIDs)
        } else {
            backend.remove(at: "enabled_models")
        }
        try Data(parsed.table.convert().utf8).write(to: path, options: .atomic)
    }

    private static func contents(at path: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try Data(contentsOf: path)
    }

    private static func parse(_ data: Data) throws -> (table: TOMLTable, config: ProviderConfig) {
        guard let content = String(data: data, encoding: .utf8) else {
            throw ConfigError.parseFailed(detail: "config is not valid UTF-8")
        }
        return (try TOMLTable(string: content), try ConfigManager.parseValidating(content))
    }

    struct SelectionConflict: Error, CustomStringConvertible {
        let configPath: URL

        var description: String {
            "Model selection at \(configPath.path) changed after staging; refusing to overwrite the newer selection."
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
