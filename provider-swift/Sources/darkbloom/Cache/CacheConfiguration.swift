import ArgumentParser
import Foundation
import ProviderCore

struct CacheSettingsStatus: Encodable {
    let directory: String
    let dailyWriteBytes: Int?
    let unlimited: Bool?
    let dailyWriteSource: String
    let volume: CacheVolume?
    let problem: String?
    let scope = "saved_settings"
    var storageCheck: String {
        problem ?? (volume == nil ? "built-in storage (checked when cache opens)" : "passed")
    }
}

func describeCacheWriteLimit(_ settings: CacheSettings) -> String {
    guard settings.dailyWriteGB != nil else {
        return "not set; provider startup environment or default applies"
    }
    let bytes = CacheStorage.dailyWriteBytes(settings: settings, environment: [:])
    return bytes == 0 ? "unlimited" : "\(Double(bytes) / 1_000_000_000) GB per rolling day"
}

/// Inspection neither creates directories nor loads keys, models or the ledger.
func inspectCacheSettings(_ settings: CacheSettings) -> CacheSettingsStatus {
    var volume: CacheVolume?
    var problem: String?
    if let directory = settings.directory {
        do {
            let observed = try CacheVolume.inspect(directory: directory)
            if observed.uuid != settings.volumeUUID?.lowercased() {
                problem = "Selected volume UUID differs from the saved pin; cache I/O will be refused."
            }
            volume = observed
        } catch { problem = error.localizedDescription }
    }
    let bytes = settings.dailyWriteGB.map { _ in
        CacheStorage.dailyWriteBytes(settings: settings, environment: [:])
    }
    return CacheSettingsStatus(directory: CacheStorage.root(for: settings).path,
        dailyWriteBytes: bytes, unlimited: bytes.map { $0 == 0 },
        dailyWriteSource: bytes == nil ? "startup_environment_or_default" : "saved_settings",
        volume: volume, problem: problem)
}

/// Re-read under the shared config lock, preserving unrelated concurrent edits.
func updateCacheSettings(
    dailyWriteGB: Double?, directory: String?, resetDirectory: Bool, configPath: String?
) throws -> (path: URL, settings: CacheSettings) {
    try CacheSettings(dailyWriteGB: dailyWriteGB).validate()
    // Validate before taking a config lock: invalid disks do not mutate config.
    let selected = try directory.map { try CacheVolume.inspect(directory: $0) }
    return try withMutableConfig(configPath: configPath) { path, config in
        var settings = config.cache
        if let dailyWriteGB { settings.dailyWriteGB = dailyWriteGB }
        if resetDirectory { settings.directory = nil; settings.volumeUUID = nil }
        if let selected {
            let rechecked = try CacheVolume.inspect(directory: selected.directory)
            guard rechecked.uuid == selected.uuid else {
                throw ValidationError("Selected cache volume changed while saving. Try again.")
            }
            settings.directory = selected.directory
            settings.volumeUUID = selected.uuid
        }
        try settings.validate()
        config.cache = settings
        try ConfigManager.save(config, to: path)
        return (path, settings)
    }
}
