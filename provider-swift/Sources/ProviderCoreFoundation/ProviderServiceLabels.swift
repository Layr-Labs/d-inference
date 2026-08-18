import Foundation

/// Launchd service labels for the provider's background agents.
///
/// Single-sourced here (the no-MLX layer) because BOTH the provider CLI's
/// `LaunchAgent`/`WatchdogAgent` logic and the Darkbloom macOS app resolve the
/// same install state — the app checks whether a model selection already
/// exists to decide between `darkbloom restart` (reuse the installed
/// selection) and `darkbloom start --all` (first start), and a label that
/// drifted between the two binaries would silently fork that decision.
public enum DarkbloomServiceLabels {
    /// The provider serving agent (`LaunchAgent`).
    public static let providerLaunchAgent = "io.darkbloom.provider"
    /// Labels the provider was registered under in earlier releases; the
    /// watchdog probes all supported labels, and the app treats a legacy
    /// plist as installed too.
    public static let providerLaunchAgentLegacy = ["dev.darkbloom.provider"]

    public static var providerLaunchAgentSupported: [String] {
        [providerLaunchAgent] + providerLaunchAgentLegacy
    }

    /// Path to a launchd plist for the given label under `~/Library/LaunchAgents`.
    public static func launchAgentPlistPath(label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// Whether any supported provider launch agent plist exists on disk —
    /// i.e. a model selection was installed by a previous `darkbloom start`.
    public static func providerLaunchAgentInstalled() -> Bool {
        providerLaunchAgentSupported.contains {
            FileManager.default.fileExists(atPath: launchAgentPlistPath(label: $0).path)
        }
    }
}
