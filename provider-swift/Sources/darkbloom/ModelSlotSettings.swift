import Foundation
import ArgumentParser
import ProviderCore

/// Share path resolution, migrations and locked reload with the beta/idle
/// writers. Fixtures disable migration to keep temp configs out of user home.
func setModelSlotLimit(
    _ limit: UInt64, configPath: String?, migrateOnDisk: Bool = true
) throws {
    guard limit > 0, limit <= UInt64(Int.max) else {
        throw ValidationError("max_model_slots must be a positive whole number no greater than \(Int.max).")
    }
    try withMutableConfig(configPath: configPath, migrateOnDisk: migrateOnDisk) { path, config in
        config.backend.maxModelSlots = limit
        try ConfigManager.save(config, to: path)
    }
}
