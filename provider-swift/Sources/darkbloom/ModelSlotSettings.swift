import Foundation
import ArgumentParser
import ProviderCore

/// Share path resolution and locked reload with the beta/idle writers.
func setModelSlotLimit(
    _ limit: UInt64, configPath: String?
) throws {
    guard limit > 0, limit <= UInt64(Int.max) else {
        throw ValidationError("max_model_slots must be a positive whole number no greater than \(Int.max).")
    }
    try withMutableConfig(configPath: configPath) { path, config in
        config.backend.maxModelSlots = limit
        try ConfigManager.save(config, to: path)
    }
}
