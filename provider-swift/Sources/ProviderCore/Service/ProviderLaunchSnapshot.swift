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
    /// launchd's record of the loaded provider job names this exact process.
    /// An in-place exec keeps the process identity, so it still matches.
    /// Environment such as `XPC_SERVICE_NAME` is not enough: child processes
    /// inherit it.
    public static func isCurrentProcessJob() -> Bool {
        isJob(launchSnapshot()?.process, current: ProcessIdentity.current())
    }

    static func isJob(_ jobProcess: ProcessIdentity?, current: ProcessIdentity?) -> Bool {
        guard let jobProcess, let current else { return false }
        return jobProcess == current
    }

    public static func launchSnapshot() -> ProviderLaunchSnapshot? {
        let output = LaunchctlControl.printOutput(label: label)
        guard output.succeeded else { return nil }
        return parseLaunchSnapshot(label: label, output: output.stdout)
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
