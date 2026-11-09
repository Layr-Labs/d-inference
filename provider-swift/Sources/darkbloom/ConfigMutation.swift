import ArgumentParser
import Foundation
import ProviderCore

/// Resolve the config before taking the stable sidecar lock, then reload inside
/// the lock so concurrent beta/idle changes cannot overwrite each other. Callers
/// own their key-presence/no-op check and save, preserving explicit pin semantics.
func withMutableConfig<Result>(
    configPath: String?,
    _ body: (URL, inout ProviderConfig) throws -> Result
) throws -> Result {
    let loaded = try loadRuntimeConfiguration(configPath: configPath)
    let savePath = loaded.configPath
    return try withExclusiveConfigLock(at: savePath) {
        var config = try FileManager.default.fileExists(atPath: savePath.path)
            ? ConfigManager.load(from: savePath) : loaded.config
        return try body(savePath, &config)
    }
}

/// Changes the values of `[local]` (`LocalSettings`) and no other value in the config, so keys this build does not
/// know keep their values; comments are dropped and keys re-sorted, as with every config writer (`updateLocal`).
/// Shaped like `setIdleUnloadMinutes`: the same config path, the config lock with a re-read inside it, a plain
/// refusal before anything is written, and an explicit value written even when it equals the default. Returns the
/// config path and whether the file changed.
///
/// Internal (not `private`) so `DarkbloomCLITests` can drive it with temp config fixtures via `configPath`.
@discardableResult
func setLocalSettings(
    configPath: String?,
    _ change: (inout LocalSettings) -> Void
) throws -> (path: URL, changed: Bool) {
    let loaded = try loadRuntimeConfiguration(configPath: configPath)
    do {
        let changed = try ConfigManager.updateLocal(at: loaded.configPath, fallbackConfig: loaded.config, change)
        return (loaded.configPath, changed)
    } catch let refusal as LocalSettingsError {
        throw ValidationError(refusal.description)
    }
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
