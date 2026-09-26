import Foundation
import ProviderCoreFoundation

extension ConfigManager {
    /// Hand-written relative paths are relative to the TOML file, not the daemon's cwd.
    /// The location command saves absolute paths. Invalid explicit settings never
    /// silently fall back to a different cache.
    public static func modelCacheDirectory(in config: ProviderConfig, relativeTo configPath: URL) throws -> String? {
        guard let raw = config.backend.modelCacheDirectory else { return nil }
        guard let directory = ModelScanner.normalizedCacheDirectory(
            raw, relativeTo: configPath.deletingLastPathComponent()) else {
            throw ConfigError.parseFailed(detail: "backend.model_cache_directory must be a non-empty filesystem path")
        }
        return directory.path
    }
}
