import Foundation

public struct ProviderLaunchSnapshot: Codable, Sendable, Equatable {
    public let label: String
    public let runs: UInt64?
    public let process: ProcessIdentity?
    /// The loaded job's effective `ExitTimeOut` (launchd's SIGTERM→SIGKILL
    /// budget), from `launchctl print`'s `exit timeout = N` line. nil when
    /// the output did not carry one (or for baselines recorded before it
    /// was parsed).
    public let exitTimeoutSeconds: Int?

    public init(
        label: String, runs: UInt64?, process: ProcessIdentity?,
        exitTimeoutSeconds: Int? = nil
    ) {
        self.label = label
        self.runs = runs
        self.process = process
        self.exitTimeoutSeconds = exitTimeoutSeconds
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
    public static func launchSnapshot() -> ProviderLaunchSnapshot? {
        for label in supportedLabels {
            let output = LaunchctlControl.printOutput(label: label)
            guard output.succeeded else { continue }
            return parseLaunchSnapshot(label: label, output: output.stdout)
        }
        return nil
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
        let exitTimeout = captureInteger(#"\bexit timeout\s*=\s*([0-9]+)"#, in: output)
            .flatMap(Int.init)
        return ProviderLaunchSnapshot(
            label: label,
            runs: runs,
            process: pid.flatMap(identityReader),
            exitTimeoutSeconds: exitTimeout
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
