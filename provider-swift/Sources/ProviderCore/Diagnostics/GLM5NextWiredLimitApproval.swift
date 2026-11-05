import Foundation

/// One administrator approval that applies or removes a pair rank's GPU
/// wired-memory limits (`GLM5NextWiredLimit.pairRankRecommendation`) on this
/// Mac: the exact commands macOS is asked to run and the sentence its prompt
/// shows. Every value comes from this Mac's own memory size through the
/// recommendation (whose GPU limit leaves macOS 16 GiB); no operator or peer
/// text is ever placed in a command, as with `ClusterLinkPrivilegedRequest`.
public struct GLM5NextWiredLimitRequest: Equatable, Sendable {
    public enum Purpose: Equatable, Sendable {
        /// Apply the limits now and install the job that applies them at boot.
        case raise(GLM5NextWiredLimit.Recommendation)
        /// Remove that job and return the GPU limit to the macOS default; the
        /// user wire limits return to theirs at the next restart.
        case remove
    }

    public let purpose: Purpose

    /// Nil for a recommendation whose values are not the derivation's own.
    public init?(_ purpose: Purpose) {
        if case .raise(let value) = purpose, !GLM5NextWiredLimit.isPairRankRecommendation(value) { return nil }
        self.purpose = purpose
    }

    static var label: String { GLM5NextWiredLimit.launchDaemonLabel }
    static var plist: String { GLM5NextWiredLimit.launchDaemonPath }

    /// The exact commands, in order, for root. The job definition is built key
    /// by key from these fixed values; no file anyone prepared is copied into
    /// place. It is the one `GLM5NextWiredLimitBootJob` recognises.
    public var commands: [String] {
        let plist = Self.plist, log = GLM5NextWiredLimit.launchDaemonLogPath
        switch purpose {
        case .raise(let value):
            func insert(_ entry: String) -> String { "/usr/bin/plutil -insert \(entry) \(plist)" }
            let program = value.bootJobProgramArguments
            // A repair replaces a job that is loaded; a first install has none to
            // stop. First, because in the `&&` line its `|| true` would also
            // excuse any failed command before it.
            return ["/bin/launchctl bootout system/\(Self.label) 2>/dev/null || true",
                    program.joined(separator: " "),
                    "/bin/rm -f \(plist)",
                    "/usr/bin/plutil -create xml1 \(plist)",
                    insert("Label -string \(Self.label)"),
                    insert("ProgramArguments -array")]
                + program.enumerated().map { insert("ProgramArguments.\($0.offset) -string \($0.element)") }
                + [insert("RunAtLoad -bool true"),
                   insert("StandardOutPath -string \(log)"),
                   insert("StandardErrorPath -string \(log)"),
                   "/usr/sbin/chown root:wheel \(plist)",
                   "/bin/chmod 644 \(plist)",
                   "/bin/launchctl bootstrap system \(plist)"]
        case .remove:
            return ["/bin/launchctl bootout system/\(Self.label)", "/bin/rm -f \(plist)",
                    "/usr/sbin/sysctl iogpu.wired_limit_mb=0"]
        }
    }

    /// A raise stops at the first command to fail; a removal runs every
    /// command, each undoing one thing on its own.
    public var shellCommand: String {
        if case .remove = purpose { return commands.joined(separator: "; ") }
        return commands.joined(separator: " && ")
    }

    /// What the macOS authorization prompt tells the person approving.
    public var prompt: String {
        switch purpose {
        case .raise(let value):
            return "Darkbloom wants to let this Mac's GPU keep up to \(value.gpuWiredLimitMB >> 10) GB of its "
                + "\(value.memoryGiB) GB resident, leaving macOS \(value.memoryGiB - (value.gpuWiredLimitMB >> 10)) GB, and keep that after restarts, so GLM-5.3-Flash "
                + "can run on two Macs."
        case .remove:
            return "Darkbloom wants to return this Mac's GPU memory limit to the macOS default and remove the job that kept it raised."
        }
    }

    /// Nothing here needs AppleScript escaping: the commands are fixed paths,
    /// digits and the `||` of one fallback, and the prompt has no double quote
    /// or backslash.
    public var appleScript: String {
        "do shell script \"\(shellCommand)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// For an administrator to run by hand where no prompt can be shown.
    public var manualCommands: [String] { commands.map { "sudo " + $0 } }
}

/// Asks macOS to run one `GLM5NextWiredLimitRequest` as an administrator, as
/// the link setup's approvals do (`ClusterLinkApproval`): macOS shows its own
/// authorization prompt; Darkbloom never sees a password and never uses `sudo`.
public enum GLM5NextWiredLimitApproval {
    public enum Outcome: Equatable, Sendable {
        case applied, declined, unavailable, commandFailed
    }

    public static func request(_ request: GLM5NextWiredLimitRequest) -> Outcome {
        switch ClusterLinkApproval.request(wiredLimit: request) {
        case .applied: return .applied
        case .declined: return .declined
        case .unavailable: return .unavailable
        case .commandFailed: return .commandFailed
        }
    }
}

extension ClusterLinkApproval {
    /// The same prompt for a pair rank's GPU wired-memory limits. Kept beside the request, outside the link sources, so
    /// the model-free link runners compile without the GLM memory closure.
    static func request(wiredLimit request: GLM5NextWiredLimitRequest) -> ClusterLinkApprovalResult {
        run(["-e", request.appleScript])
    }
}
