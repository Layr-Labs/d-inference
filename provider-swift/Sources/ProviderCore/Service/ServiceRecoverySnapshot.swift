import Foundation

/// Recovery settings before a lifecycle command publishes its admission/drain
/// request. Rollback never rewrites the installed watchdog plist or arguments.
public struct ServiceRecoverySnapshot {
    private let enabled: [String: Bool]
    private let watchdogLoaded: Bool

    public static func capture() throws -> Self {
        let output = try LaunchctlControl.runThrowing(["print-disabled", LaunchctlControl.guiDomain()], captureStdout: true)
        guard output.succeeded else { throw LaunchAgentError.disableFailed("cannot read previous launchd overrides") }
        let labels = LaunchAgent.supportedLabels + [WatchdogAgent.label]
        return Self(enabled: enabledStates(labels: labels, output: output.stdout), watchdogLoaded: WatchdogAgent.isLoaded())
    }

    static func enabledStates(labels: [String], output: String) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: labels.map { label in
            let pattern = "\"" + NSRegularExpression.escapedPattern(for: label) + "\"\\s*=>\\s*(?:true|disabled)\\b"
            return (label, output.range(of: pattern, options: .regularExpression) == nil)
        })
    }

    public func restore() throws {
        var errors: [String] = []
        // Re-bootstrap the original watchdog only if it was previously loaded.
        if watchdogLoaded && !WatchdogAgent.isLoaded() {
            let enable = LaunchctlControl.setEnabled(true, label: WatchdogAgent.label)
            if !enable.succeeded { errors.append(enable.stderr) }
            let bootstrap = LaunchctlControl.run(["bootstrap", LaunchctlControl.guiDomain(), WatchdogAgent.plistPath().path], captureStderr: true)
            if !bootstrap.succeeded { errors.append(bootstrap.stderr) }
        }
        for (label, wasEnabled) in enabled {
            let restored = LaunchctlControl.setEnabled(wasEnabled, label: label)
            if !restored.succeeded { errors.append(restored.stderr) }
        }
        if !errors.isEmpty { throw LaunchAgentError.disableFailed("recovery rollback failed: " + errors.joined(separator: "; ")) }
    }
}
