import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// Resolve migrations before taking the stable sidecar lock, then reload inside
/// the lock so concurrent beta/idle changes cannot overwrite each other. Callers
/// own their key-presence/no-op check and save, preserving explicit pin semantics.
func withMutableConfig<Result>(
    configPath: String?,
    _ body: (URL, inout ProviderConfig) throws -> Result
) throws -> Result {
    let snapshot = try loadRuntimeSnapshot(configPath: configPath)
    // Default-path lookup must happen after a possible legacy migration.
    let savePath = try configPath != nil ? snapshot.configPath : ConfigManager.defaultConfigPath()
    return try withExclusiveConfigLock(at: savePath) {
        var config = try FileManager.default.fileExists(atPath: savePath.path)
            ? ConfigManager.load(from: savePath) : snapshot.config
        return try body(savePath, &config)
    }
}

/// Guards one config-file mutation window with an exclusive `flock(2)` on a
/// stable `<config-name>.lock` sidecar next to the config file. The lock must
/// NOT be taken out on provider.toml itself: `ConfigManager.save` writes
/// atomically via temp-file + rename, so the config file's inode changes on
/// every save and concurrent writers would be locking DIFFERENT inodes (no
/// mutual exclusion). The sidecar path is never renamed, so every contending
/// process locks the same inode. Closing the fd (the defer) also releases the
/// kernel lock if the explicit LOCK_UN is ever skipped by a throw.
@discardableResult
func withExclusiveConfigLock<T>(at configPath: URL, _ body: () throws -> T) throws -> T {
    let directory = configPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent(configPath.lastPathComponent + ".lock")

    let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else {
        throw ConfigError.writeFailed(
            path: lockURL.path,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        )
    }
    defer { close(fd) }

    guard flock(fd, LOCK_EX) == 0 else {
        throw ConfigError.writeFailed(
            path: lockURL.path,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        )
    }
    defer { _ = flock(fd, LOCK_UN) }

    return try body()
}

/// Whether TOML `content` materially sets `key` inside `[section]`.
///
/// Line-oriented: tracks the current table header and matches `key = ...`
/// assignments. Only needs to be correct for the flat
/// `[section]\nkey = value` shape `ConfigManager.save` serializes (and that
/// operators hand-edit). A miss here is fail-safe for the caller: unsure
/// means WRITE the key, which is idempotent.
func tomlKeyPresent(_ content: String, section: String, key: String) -> Bool {
    var inSection = false
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inSection = line == "[\(section)]"
            continue
        }
        guard inSection, !line.hasPrefix("#"),
              let eqIndex = line.firstIndex(of: "=") else { continue }
        let name = line[..<eqIndex].trimmingCharacters(in: .whitespaces)
        if name == key { return true }
    }
    return false
}
