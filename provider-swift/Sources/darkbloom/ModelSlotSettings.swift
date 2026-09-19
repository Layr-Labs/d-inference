import Foundation
import ArgumentParser
import ProviderCore

/// The caller supplies the resolved config path and startup fallback. Re-read
/// under the same lock used by other CLI config writers to preserve changes
/// made while the picker was open. Do not scan models or touch real user paths
/// from this persistence seam.
func setModelSlotLimit(
    _ limit: UInt64, at path: URL, fallback: ProviderConfig
) throws {
    guard limit > 0, limit <= UInt64(Int.max) else {
        throw ValidationError("max_model_slots must be a positive whole number no greater than \(Int.max).")
    }
    try withExclusiveConfigLock(at: path) {
        var config = FileManager.default.fileExists(atPath: path.path)
            ? try ConfigManager.load(from: path) : fallback
        config.backend.maxModelSlots = limit
        try ConfigManager.save(config, to: path)
    }
}
