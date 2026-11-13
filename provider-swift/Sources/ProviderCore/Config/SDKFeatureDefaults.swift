import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Provider defaults for feature switches the SDK reads from the process
/// environment (`libs/mlx-swift-lm` keeps every one of them opt-in).
///
/// A switch listed in `onByDefault` is turned on for a serving process unless
/// the operator's environment (the shell, or the LaunchAgent plist, which
/// forwards each key) already sets it, so `<KEY>=0` stays the kill switch and
/// restores 0.10.12's behaviour. Unlisted switches keep the SDK default (off).
/// `ServeRuntimePreparer` applies the projection before the first engine or
/// parser reads a switch (several are read once per process).
public enum SDKFeatureDefaults {
    /// Switches proven on hardware for this release; see `docs/reference/configuration.md`.
    public static let onByDefault: [String] = []

    /// The keys to set for `environment`: every listed key it does not set.
    public static func projection(
        onByDefault: [String] = onByDefault, environment: [String: String]
    ) -> [String: String] {
        onByDefault.reduce(into: [:]) { out, key in
            if environment[key] == nil { out[key] = "1" }
        }
    }

    /// Apply the projection to this process without overwriting any set key.
    /// Returns the keys it turned on, for the startup log.
    @discardableResult
    public static func apply(
        onByDefault: [String] = onByDefault,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let keys = projection(onByDefault: onByDefault, environment: environment)
        for (key, value) in keys { setenv(key, value, 0) }
        return keys.keys.sorted()
    }
}
