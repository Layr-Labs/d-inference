import Darwin
import Foundation

/// The boot job `darkbloom cluster gpu-limit` finds at its path
/// (`GLM5NextWiredLimit.launchDaemonPath`).
public enum GLM5NextWiredLimitBootJob: Equatable, Sendable {
    case missing
    /// Exactly the job the command writes for the recommendation
    /// (`GLM5NextWiredLimitRequest.commands`): its five keys, with these values
    /// and types. The doctor's text for 256 GB hosts writes the same job.
    case matches
    /// Anything else there: other values, keys or types, or a file that does
    /// not read as one bounded property list.
    case differs

    /// `definition`: the file's bytes, nil when there is no file.
    public static func reading(_ definition: Data?, for value: GLM5NextWiredLimit.Recommendation) -> Self {
        guard let definition else { return .missing }
        guard let job = try? PropertyListSerialization.propertyList(from: definition, format: nil) as? [String: Any],
              job.count == 5, (job["RunAtLoad"] as? NSNumber) === kCFBooleanTrue else { return .differs }
        let log = GLM5NextWiredLimit.launchDaemonLogPath
        return job["Label"] as? String == GLM5NextWiredLimit.launchDaemonLabel
            && job["ProgramArguments"] as? [String] == value.bootJobProgramArguments
            && job["StandardOutPath"] as? String == log && job["StandardErrorPath"] as? String == log ? .matches : .differs
    }
}

/// What `darkbloom cluster gpu-limit` reads and asks macOS to run. `live`
/// reads the sysctls, Metal and the job file and shows macOS's administrator
/// prompt; checks supply fakes, so no test changes a setting.
public struct GLM5NextGPULimitRunner {
    public var limits: () -> GLM5NextWiredLimit.Limits
    /// The boot job's file, nil when there is none. Anything at the path that
    /// is not a regular file of at most 64 KiB reads as empty, so it differs.
    public var bootJobDefinition: () -> Data?
    public var approve: (GLM5NextWiredLimitRequest) -> GLM5NextWiredLimitApproval.Outcome

    public init(limits: @escaping () -> GLM5NextWiredLimit.Limits, bootJobDefinition: @escaping () -> Data?,
                approve: @escaping (GLM5NextWiredLimitRequest) -> GLM5NextWiredLimitApproval.Outcome) {
        self.limits = limits; self.bootJobDefinition = bootJobDefinition; self.approve = approve
    }

    public static var live: GLM5NextGPULimitRunner {
        .init(limits: { .live() }, bootJobDefinition: { readJobFile(atPath: GLM5NextWiredLimit.launchDaemonPath) },
              approve: GLM5NextWiredLimitApproval.request)
    }

    static func readJobFile(atPath path: String) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? nil : Data() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 65_536 else { return Data() }
        return FileManager.default.contents(atPath: path) ?? Data()
    }
}

/// `darkbloom cluster gpu-limit` without its terminal: what it decides from
/// the live limits and the boot job, what it says, and what it asks macOS to
/// run. It reports nothing to change only when the limits are met and the boot
/// job is the one it writes; a missing or different job is installed behind
/// the same confirmation and prompt as a raise.
public enum GLM5NextGPULimitFlow {
    public enum Plan: Equatable, Sendable {
        case nothingToChange
        case raise(Reason)
        case remove
    }

    public enum Reason: Equatable, Sendable {
        case limitsBelow
        /// The limits are met, but no boot job keeps them after a restart.
        case bootJobMissing
        /// The limits are met, but the boot job is not the one the command writes.
        case bootJobDiffers
    }

    public static func plan(undo: Bool, recommendation: GLM5NextWiredLimit.Recommendation,
                            limits: GLM5NextWiredLimit.Limits, bootJob: GLM5NextWiredLimitBootJob) -> Plan {
        if undo { return .remove }
        guard recommendation.isMet(by: limits) else { return .raise(.limitsBelow) }
        switch bootJob {
        case .matches: return .nothingToChange
        case .missing: return .raise(.bootJobMissing)
        case .differs: return .raise(.bootJobDiffers)
        }
    }

    /// Runs the command for this Mac's `recommendation`. `confirm` asks one
    /// question and is nil without a terminal; `say` prints one line. The exit
    /// status: 0 done, declined at the question or nothing to change; 1 the
    /// approval or a step failed; 2 no terminal to confirm in.
    public static func run(undo: Bool, recommendation: GLM5NextWiredLimit.Recommendation, runner: GLM5NextGPULimitRunner,
                           confirm: ((String) -> Bool)?, say: (String) -> Void) -> Int32 {
        let gib = { (bytes: UInt64) in String(format: "%.2f GiB", Double(bytes) / Double(1 << 30)) }
        let limits = runner.limits(), raised = gib(recommendation.gpuWiredLimitBytes)
        say("This Mac's GPU keeps \(gib(limits.gpuLimitBytes)) resident now"
            + (limits.gpuWiredLimitMB.map { $0 > 0 ? " (iogpu.wired_limit_mb=\($0))." : " (the macOS default)." } ?? "."))
        let decided = Self.plan(undo: undo, recommendation: recommendation, limits: limits,
            bootJob: .reading(runner.bootJobDefinition(), for: recommendation))
        let met = "It meets the recommendation for this \(recommendation.memoryGiB) GB Mac (\(raised)) now"
        switch decided {
        case .nothingToChange:
            say(met + ", and the boot job keeps it after restarts. Nothing to change.")
            return 0
        case .remove: say("This returns the GPU limit to the macOS default and removes the job that keeps it raised.")
        case .raise(.limitsBelow): say("This lets the GPU keep up to \(raised) resident (macOS keeps 16 GiB), now and after every restart.")
        case .raise(.bootJobMissing): say(met + ", but no boot job keeps it after a restart. This installs that job.")
        case .raise(.bootJobDiffers): say(met + ", but the boot job that keeps it after a restart is not the one this command writes. This replaces it.")
        }
        guard let request = GLM5NextWiredLimitRequest(undo ? .remove : .raise(recommendation)) else {
            say("The recommendation is not one this command applies.")
            return 1
        }
        guard let confirm else {
            say("No terminal to confirm in. An administrator can run these instead:")
            request.manualCommands.forEach { say("  " + $0) }
            return 2
        }
        let action = undo ? "Undo it" : decided == .raise(.limitsBelow) ? "Raise it" : "Install it"
        guard confirm("\(action) now? macOS will ask an administrator to approve. [y/N] ") else {
            say("Nothing was changed.")
            return 0
        }
        switch runner.approve(request) {
        case .applied:
            if !undo, GLM5NextWiredLimitBootJob.reading(runner.bootJobDefinition(), for: recommendation) != .matches {
                say("macOS ran the change, but the boot job is not the one this command writes; run `darkbloom cluster gpu-limit` "
                    + "again to see what is in place.")
                return 1
            }
            say("Done. This Mac's GPU now keeps \(gib(runner.limits().gpuLimitBytes)) resident. Run `darkbloom cluster` again so "
                + "both Macs plan and load with it.")
            return 0
        case .declined:
            say("Nothing was changed: the approval was cancelled.")
        case .unavailable:
            say("macOS could not show the approval here. An administrator can run these instead:")
            request.manualCommands.forEach { say("  " + $0) }
        case .commandFailed:
            say("macOS ran the change and a step failed; run `darkbloom cluster gpu-limit` again to see what is in place.")
        }
        return 1
    }
}
