import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

    /// Whether launchd currently owns any supported provider job.
    ///
    /// A plist can remain after `darkbloom stop`; loaded state is the lifecycle
    /// boundary that distinguishes an intentionally stopped provider from a
    /// launchd-managed job whose last daemon snapshot reported scheduled-off.
    public static func providerLaunchAgentLoaded() -> Bool {
        #if canImport(Darwin)
        let uid = getuid()
        return providerLaunchAgentSupported.contains { label in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "gui/\(uid)/\(label)"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
        #else
        return false
        #endif
    }
}
