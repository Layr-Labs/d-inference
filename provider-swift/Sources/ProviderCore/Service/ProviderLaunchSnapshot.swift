import Foundation

public struct ProviderLaunchSnapshot: Codable, Sendable, Equatable {
    public let label: String
    public let runs: UInt64?
    public let process: ProcessIdentity?

    public init(label: String, runs: UInt64?, process: ProcessIdentity?) {
        self.label = label
        self.runs = runs
        self.process = process
    }

    public func provesLaunch(after baseline: ProviderLaunchSnapshot?) -> Bool {
        guard let baseline else {
            return runs != nil || process != nil
        }
        if let runs, let previous = baseline.runs, runs > previous {
            return true
        }
        if let process, process != baseline.process {
            return true
        }
        return false
    }
}

extension LaunchAgent {
    /// SIGINFO is ignored by older macOS provider builds, so a new CLI cannot
    /// accidentally terminate an old daemon that lacks operator drain support.
    static let operatorDrainSignal = "SIGINFO"

    /// One snapshot per loaded canonical or legacy provider job. A loaded job
    /// may have no live process, in which case `process` is nil.
    public static func launchSnapshots() -> [ProviderLaunchSnapshot] {
        supportedLabels.compactMap { label in
            let output = LaunchctlControl.printOutput(label: label)
            guard output.succeeded else { return nil }
            return parseLaunchSnapshot(label: label, output: output.stdout)
        }
    }

    public static func launchSnapshot() -> ProviderLaunchSnapshot? {
        launchSnapshots().first
    }

    /// Send the backward-safe operator signal through launchd, targeting the
    /// loaded job rather than an untrusted PID read from disk. The caller still
    /// waits on the captured `ProcessIdentity`, so a later launch cannot be
    /// mistaken for completion of the process that was asked to drain.
    public static func requestGracefulExit(label: String) throws {
        guard supportedLabels.contains(label) else {
            throw LaunchAgentError.signalFailed("unsupported service label \(label)")
        }
        let result = LaunchctlControl.run(
            ["kill", operatorDrainSignal, LaunchctlControl.target(label: label)],
            captureStderr: true
        )
        guard result.succeeded else {
            throw LaunchAgentError.signalFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func parseLaunchSnapshot(
        label: String,
        output: String,
        identityReader: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> ProviderLaunchSnapshot {
        let runs = captureInteger(#"\bruns\s*=\s*([0-9]+)"#, in: output)
            .flatMap(UInt64.init)
        let pid = captureInteger(#"\bpid\s*=\s*([1-9][0-9]*)"#, in: output)
            .flatMap(Int32.init)
        return ProviderLaunchSnapshot(
            label: label,
            runs: runs,
            process: pid.flatMap(identityReader)
        )
    }

    private static func captureInteger(
        _ pattern: String,
        in output: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        return String(output[range])
    }
}
