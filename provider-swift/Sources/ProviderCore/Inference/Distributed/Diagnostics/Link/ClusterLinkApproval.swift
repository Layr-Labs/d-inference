import Foundation

enum ClusterLinkApprovalResult: Equatable, Sendable {
    /// Approved, and the command exited with status 0.
    case applied
    /// The person cancelled the prompt.
    case declined
    /// No prompt could be shown or answered, for example without a desktop session.
    case unavailable
    /// Approved, but the command itself reported an error.
    case commandFailed
}

/// Asks macOS to run one `ClusterLinkPrivilegedRequest` as an administrator. macOS
/// shows its own authorization prompt; Darkbloom never sees a password and
/// never uses `sudo`.
enum ClusterLinkApproval {
    static let executable = "/usr/bin/osascript"
    /// Long enough to read the prompt and authenticate.
    private static let promptTimeoutNanoseconds: UInt64 = 300_000_000_000
    private static let maximumOutputBytes = 16 * 1024
    /// AppleScript's "User canceled" and Authorization Services' cancellation.
    private static let cancellationErrors = [-128, -60006]

    static func arguments(for request: ClusterLinkPrivilegedRequest) -> [String] {
        ["-e", request.appleScript]
    }

    static func arguments(for request: ClusterLinkIsolationRequest) -> [String] {
        ["-e", request.appleScript]
    }

    /// Shows the prompt and waits for the answer.
    static func request(_ request: ClusterLinkPrivilegedRequest) -> ClusterLinkApprovalResult {
        run(arguments(for: request))
    }

    /// The same for one approval of link setup v2.
    static func request(isolation request: ClusterLinkIsolationRequest) -> ClusterLinkApprovalResult {
        run(arguments(for: request))
    }

    private static func run(_ arguments: [String]) -> ClusterLinkApprovalResult {
        result(of: ClusterLinkToolProcess.execute(executable: executable, arguments: arguments,
            deadline: DispatchTime.now().uptimeNanoseconds + promptTimeoutNanoseconds,
            maximumOutputBytes: maximumOutputBytes, mergingStandardError: true))
    }

    /// `osascript` exits 0 when the script ran, and otherwise 1 with
    /// "execution error: <message> (<number>)". A positive number is the
    /// shell command's own exit status; a negative one is a scripting or
    /// authorization error, of which only the cancellations mean "declined".
    static func result(of execution: ClusterLinkToolProcess.Execution) -> ClusterLinkApprovalResult {
        guard case .exited(let status, let output) = execution else { return .unavailable }
        if status == 0 { return .applied }
        guard status == 1, let number = scriptErrorNumber(in: output) else { return .unavailable }
        if cancellationErrors.contains(number) { return .declined }
        return number > 0 ? .commandFailed : .unavailable
    }

    private static func scriptErrorNumber(in output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("execution error:"), text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        return Int(text[text.index(after: open)...].dropLast())
    }
}
